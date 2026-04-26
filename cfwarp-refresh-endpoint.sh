#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

CFWARP_ENV_FILE=${CFWARP_ENV_FILE:-${MICROWARP_ENV_FILE:-"${SCRIPT_DIR}/deploy/local/cfwarp.env"}}
CFWARP_SERVICE_NAME=${CFWARP_SERVICE_NAME:-"cfwarp.service"}
CFWARP_ENDPOINT_REFRESH_STATE_ROOT=${CFWARP_ENDPOINT_REFRESH_STATE_ROOT:-"/run/cfwarp-refresh"}
CFWARP_ENDPOINT_PROBE_SAMPLES=${CFWARP_ENDPOINT_PROBE_SAMPLES:-2}
CFWARP_ENDPOINT_PROBE_URL=${CFWARP_ENDPOINT_PROBE_URL:-${WARP_HEALTHCHECK_TRACE_URL:-"https://1.1.1.1/cdn-cgi/trace"}}
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=${CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE:-"skip"}

if [ ! -f "$CFWARP_ENV_FILE" ]; then
    echo "==> [CFwarp] 未找到环境文件: $CFWARP_ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
. "$CFWARP_ENV_FILE"
set +a

CFWARP_MODE=${CFWARP_MODE:-${MICROWARP_MODE:-"netns-proxy"}}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${MICROWARP_DATA_DIR:-"${SCRIPT_DIR}/var"}}
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
WG_CONF_DIR=${WG_CONF_DIR:-"${CFWARP_DATA_DIR}"}
WG_CONF=${WG_CONF:-"${WG_CONF_DIR}/${WG_INTERFACE}.conf"}
WGCF_PROFILE=${WGCF_PROFILE:-"${CFWARP_DATA_DIR}/wgcf-profile.conf"}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-"${CFWARP_DATA_DIR}/wgcf-account.toml"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}
CURRENT_ENDPOINT=${ENDPOINT_IP:-}
SERVICE_WAS_ACTIVE=0
SERVICE_RESTORED=0

if [ "$CFWARP_MODE" != "netns-proxy" ]; then
    echo "==> [CFwarp] 当前模式为 ${CFWARP_MODE}，仅 netns-proxy 模式支持自动 Endpoint 选择。"
    exit 0
fi

case "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" in
    skip|stop-and-probe)
        ;;
    *)
        echo "==> [CFwarp] 不支持的 CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE: ${CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE}" >&2
        exit 1
        ;;
esac

build_candidate_endpoints() {
    (
        [ -n "${ENDPOINT_IP:-}" ] && printf '%s\n' "$ENDPOINT_IP"
        printf '%s\n' "${ENDPOINT_CANDIDATES:-}" | tr ',' '\n'
    ) | awk 'NF && !seen[$0]++'
}

build_probe_remaining_endpoints() {
    PRIMARY_ENDPOINT=$1
    (
        [ -n "$PRIMARY_ENDPOINT" ] && printf '%s\n' "$PRIMARY_ENDPOINT"
        build_candidate_endpoints
    ) | awk 'NF && !seen[$0]++' | awk 'NR > 1 {printf "%s%s", sep, $0; sep=","}'
}

set_env_key() {
    KEY=$1
    VALUE=$2
    FILE=$3
    if grep -q "^${KEY}=" "$FILE" 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$FILE"
    fi
}

score_is_better() {
    NEW_SCORE=$1
    OLD_SCORE=${2:-}
    awk -v new="$NEW_SCORE" -v old="$OLD_SCORE" 'BEGIN { if (old == "" || new + 0 < old + 0) exit 0; exit 1 }'
}

PROBE_TOKEN=$(printf '%s' "$$" | awk '{print substr($0, length($0) - 3)}')
PROBE_NETNS="cfpr${PROBE_TOKEN}"
PROBE_HOST_IF="cfprh${PROBE_TOKEN}"
PROBE_NS_IF="cfprn${PROBE_TOKEN}"
PROBE_STATE_DIR="${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/${PROBE_TOKEN}"
LOCK_DIR="${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/lock"
TMP_ROOT=$(mktemp -d)

cleanup() {
    NETNS_NAME="$PROBE_NETNS" \
    NETNS_HOST_IF="$PROBE_HOST_IF" \
    NETNS_NS_IF="$PROBE_NS_IF" \
    CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
    WG_QUICK_BIN="$WG_QUICK_BIN" \
    sh "$SCRIPT_DIR/cfwarp-netns.sh" down > /dev/null 2>&1 || true
    restore_service_if_needed
    rm -rf "$TMP_ROOT"
    rmdir "$LOCK_DIR" > /dev/null 2>&1 || true
}
restore_service_if_needed() {
    if [ "$SERVICE_WAS_ACTIVE" = "1" ] && [ "$SERVICE_RESTORED" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        echo "==> [CFwarp] 正在恢复启动 ${CFWARP_SERVICE_NAME}。"
        systemctl start "$CFWARP_SERVICE_NAME" || true
        SERVICE_RESTORED=1
    fi
}
trap 'cleanup' EXIT HUP INT TERM

install -d "$CFWARP_ENDPOINT_REFRESH_STATE_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "==> [CFwarp] 已有 Endpoint 刷新任务在运行，跳过本次执行。"
    exit 0
fi

CANDIDATE_COUNT=$(build_candidate_endpoints | awk 'END {print NR}')
if [ "${CANDIDATE_COUNT:-0}" -lt 1 ]; then
    echo "==> [CFwarp] 未配置 ENDPOINT_IP / ENDPOINT_CANDIDATES，跳过自动选择。"
    exit 0
fi

if [ ! -f "$WGCF_PROFILE" ] && [ ! -f "$WG_CONF" ]; then
    echo "==> [CFwarp] 尚未初始化可复用的 WireGuard 配置，跳过自动选择。"
    exit 0
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
    if [ "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" = "skip" ]; then
        echo "==> [CFwarp] ${CFWARP_SERVICE_NAME} 当前正在运行；默认跳过自动刷新以避免停服。"
        exit 0
    fi
    SERVICE_WAS_ACTIVE=1
    echo "==> [CFwarp] 已启用 stop-and-probe，正在暂时停止 ${CFWARP_SERVICE_NAME}。"
    systemctl stop "$CFWARP_SERVICE_NAME"
fi

NETNS_NAME="$PROBE_NETNS" \
NETNS_HOST_IF="$PROBE_HOST_IF" \
NETNS_NS_IF="$PROBE_NS_IF" \
CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
WG_QUICK_BIN="$WG_QUICK_BIN" \
sh "$SCRIPT_DIR/cfwarp-netns.sh" up

BEST_ENDPOINT=""
BEST_SCORE=""
BEST_READY=""
BEST_HTTP_AVG=""
BEST_EXIT_IP=""
INDEX=1

for CANDIDATE_ENDPOINT in $(build_candidate_endpoints); do
    CANDIDATE_DIR="${TMP_ROOT}/candidate-${INDEX}"
    CANDIDATE_METRICS="${CANDIDATE_DIR}/metrics.env"
    PROBE_WG_INTERFACE="wgp${INDEX}"
    PROBE_WG_CONF="${CANDIDATE_DIR}/${PROBE_WG_INTERFACE}.conf"
    PROBE_REMAINING_ENDPOINTS=$(build_probe_remaining_endpoints "$CANDIDATE_ENDPOINT")
    install -d "$CANDIDATE_DIR"

    if [ ! -f "$WGCF_PROFILE" ] && [ -f "$WG_CONF" ]; then
        cp "$WG_CONF" "$PROBE_WG_CONF"
        chmod 600 "$PROBE_WG_CONF"
    fi

    echo "==> [CFwarp] 正在评估 Endpoint: ${CANDIDATE_ENDPOINT}"
    if ip netns exec "$PROBE_NETNS" env \
        WG_INTERFACE="$PROBE_WG_INTERFACE" \
        CFWARP_DATA_DIR="$CFWARP_DATA_DIR" \
        MICROWARP_DATA_DIR="$CFWARP_DATA_DIR" \
        WG_CONF_DIR="$CANDIDATE_DIR" \
        WG_CONF="$PROBE_WG_CONF" \
        WGCF_PROFILE="$WGCF_PROFILE" \
        WGCF_ACCOUNT="$WGCF_ACCOUNT" \
        WG_QUICK_BIN="$WG_QUICK_BIN" \
        ENDPOINT_IP="$CANDIDATE_ENDPOINT" \
        ENDPOINT_CANDIDATES="$PROBE_REMAINING_ENDPOINTS" \
        WARP_READY_ATTEMPTS="${WARP_READY_ATTEMPTS:-}" \
        WARP_READY_DELAY_SECONDS="${WARP_READY_DELAY_SECONDS:-}" \
        WARP_HEALTHCHECK_CONNECT_TIMEOUT="${WARP_HEALTHCHECK_CONNECT_TIMEOUT:-}" \
        WARP_HEALTHCHECK_TOTAL_TIMEOUT="${WARP_HEALTHCHECK_TOTAL_TIMEOUT:-}" \
        WARP_HEALTHCHECK_TRACE_URL="${WARP_HEALTHCHECK_TRACE_URL:-}" \
        WARP_HEALTHCHECK_TEST_URL="${WARP_HEALTHCHECK_TEST_URL:-}" \
        CFWARP_PROBE_MODE="1" \
        CFWARP_PROBE_URL="$CFWARP_ENDPOINT_PROBE_URL" \
        CFWARP_PROBE_SAMPLES="$CFWARP_ENDPOINT_PROBE_SAMPLES" \
        CFWARP_PROBE_METRICS_FILE="$CANDIDATE_METRICS" \
        sh "$SCRIPT_DIR/entrypoint.sh" > "${CANDIDATE_DIR}/probe.log" 2>&1; then
        # shellcheck disable=SC1090
        . "$CANDIDATE_METRICS"
        echo "==> [CFwarp] Endpoint ${CANDIDATE_ENDPOINT} 评估成功: ready=${READY_SECONDS}s avg=${HTTP_AVG_TOTAL}s score=${SCORE}"
        if score_is_better "$SCORE" "$BEST_SCORE"; then
            BEST_ENDPOINT=${SELECTED_ENDPOINT:-$CANDIDATE_ENDPOINT}
            BEST_SCORE=$SCORE
            BEST_READY=$READY_SECONDS
            BEST_HTTP_AVG=$HTTP_AVG_TOTAL
            BEST_EXIT_IP=${EXIT_IP:-}
        fi
    else
        echo "==> [CFwarp] Endpoint ${CANDIDATE_ENDPOINT} 评估失败，已跳过。"
        if [ -f "${CANDIDATE_DIR}/probe.log" ]; then
            sed -n '1,120p' "${CANDIDATE_DIR}/probe.log" || true
        fi
    fi

    INDEX=$((INDEX + 1))
done

if [ -z "$BEST_ENDPOINT" ]; then
    echo "==> [CFwarp] 所有候选 Endpoint 都未通过评估，保留当前配置。"
    restore_service_if_needed
    exit 0
fi

echo "==> [CFwarp] 今日最佳 Endpoint: ${BEST_ENDPOINT} (ready=${BEST_READY}s avg=${BEST_HTTP_AVG}s score=${BEST_SCORE} exit_ip=${BEST_EXIT_IP:-unknown})"
set_env_key ENDPOINT_IP "$BEST_ENDPOINT" "$CFWARP_ENV_FILE"

if [ "$SERVICE_WAS_ACTIVE" = "1" ]; then
    if [ "$CURRENT_ENDPOINT" != "$BEST_ENDPOINT" ]; then
        echo "==> [CFwarp] 已更新 ENDPOINT_IP，并重新启动 ${CFWARP_SERVICE_NAME} 使新 Endpoint 生效。"
    else
        echo "==> [CFwarp] 当前 ENDPOINT_IP 已是最佳候选，正在恢复启动 ${CFWARP_SERVICE_NAME}。"
    fi
    systemctl start "$CFWARP_SERVICE_NAME"
    SERVICE_RESTORED=1
else
    if [ "$CURRENT_ENDPOINT" != "$BEST_ENDPOINT" ]; then
        echo "==> [CFwarp] 已更新 ENDPOINT_IP，新 Endpoint 会在下次启动 ${CFWARP_SERVICE_NAME} 时生效。"
    else
        echo "==> [CFwarp] 当前配置中的 ENDPOINT_IP 已是最佳候选。"
    fi
fi
