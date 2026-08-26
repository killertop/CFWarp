#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
COMMON_FILE="${SCRIPT_DIR}/lib/cfwarp-common.sh"
if [ ! -r "$COMMON_FILE" ]; then
    echo "==> [ERROR] 找不到共享库: $COMMON_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$COMMON_FILE"

CFWARP_ENV_FILE=$(cfwarp_default_env_file "$SCRIPT_DIR")
if [ ! -r "$CFWARP_ENV_FILE" ]; then
    echo "==> [ERROR] 未找到可读的环境文件: $CFWARP_ENV_FILE" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1090
. "$CFWARP_ENV_FILE"
set +a

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
CFWARP_SERVICE_NAME=${CFWARP_SERVICE_NAME:-cfwarp.service}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${SCRIPT_DIR}/var}
WG_INTERFACE=${WG_INTERFACE:-wg0}
WG_CONF_DIR=${WG_CONF_DIR:-$CFWARP_DATA_DIR}
WG_CONF=${WG_CONF:-${WG_CONF_DIR}/${WG_INTERFACE}.conf}
WGCF_PROFILE=${WGCF_PROFILE:-${CFWARP_DATA_DIR}/wgcf-profile.conf}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-${CFWARP_DATA_DIR}/wgcf-account.toml}
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}
CFWARP_ENDPOINT_REFRESH_STATE_ROOT=${CFWARP_ENDPOINT_REFRESH_STATE_ROOT:-/run/cfwarp-refresh}
CFWARP_ENDPOINT_PROBE_SAMPLES=${CFWARP_ENDPOINT_PROBE_SAMPLES:-2}
CFWARP_ENDPOINT_PROBE_URL=${CFWARP_ENDPOINT_PROBE_URL:-${WARP_HEALTHCHECK_TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}}
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=${CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE:-skip}
CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS=${CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS:-35}
CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT=${CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT:-15}
ENDPOINT_IP=${ENDPOINT_IP:-}
ENDPOINT_CANDIDATES=${ENDPOINT_CANDIDATES:-}

if [ "$CFWARP_MODE" != "netns-proxy" ]; then
    echo "==> [CFwarp] 当前模式为 ${CFWARP_MODE}，Endpoint 自动评估仅支持 netns-proxy。"
    exit 0
fi
case "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" in
    skip|stop-and-probe) ;;
    *) echo "==> [ERROR] CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE 仅支持 skip 或 stop-and-probe。" >&2; exit 1 ;;
esac
cfwarp_validate_uint "$CFWARP_ENDPOINT_PROBE_SAMPLES" CFWARP_ENDPOINT_PROBE_SAMPLES 1 100 || exit 1
cfwarp_validate_uint "$CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS" CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS 5 1800 || exit 1
cfwarp_validate_uint "$CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT" CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT 0 100 || exit 1

config_endpoint() {
    if [ -f "$WG_CONF" ]; then
        awk '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_CONF"
    elif [ -f "$WGCF_PROFILE" ]; then
        awk '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WGCF_PROFILE"
    fi
}

build_candidate_endpoints() {
    CFWARP_CURRENT_ENDPOINT=$1
    (
        [ -n "$CFWARP_CURRENT_ENDPOINT" ] && printf '%s\n' "$CFWARP_CURRENT_ENDPOINT"
        [ -n "$ENDPOINT_IP" ] && printf '%s\n' "$ENDPOINT_IP"
        printf '%s\n' "$ENDPOINT_CANDIDATES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    ) | awk 'NF && !seen[$0]++'
}

metric() {
    sed -n "s/^$1=//p" "$2" | head -n 1
}

score_is_better() {
    awk -v new="$1" -v old="${2:-}" 'BEGIN { if (old == "" || new + 0 < old + 0) exit 0; exit 1 }'
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

TIMEOUT_AVAILABLE=0
TIMEOUT_FOREGROUND=0
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_AVAILABLE=1
    if timeout --help 2>&1 | grep -q -- '--foreground'; then
        TIMEOUT_FOREGROUND=1
    fi
fi

run_timeout() {
    if [ "$TIMEOUT_FOREGROUND" = "1" ]; then
        timeout --foreground "$@"
    else
        timeout "$@"
    fi
}

CURRENT_ENDPOINT=$(config_endpoint || true)
if [ -z "$CURRENT_ENDPOINT" ]; then
    CURRENT_ENDPOINT=$ENDPOINT_IP
fi
if [ ! -f "$WGCF_PROFILE" ] && [ ! -f "$WG_CONF" ]; then
    echo "==> [CFwarp] 尚未初始化可复用的 WireGuard 配置，跳过自动选择。"
    exit 0
fi

TMP_ROOT=$(mktemp -d)
PROBE_TOKEN=$$
PROBE_NETNS="cfpr${PROBE_TOKEN}"
PROBE_HOST_IF="cfprh${PROBE_TOKEN}"
PROBE_NS_IF="cfprn${PROBE_TOKEN}"
PROBE_STATE_DIR="${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/${PROBE_TOKEN}"
PROBE_HOST_ADDR=${CFWARP_ENDPOINT_PROBE_HOST_ADDR:-169.254.241.1/30}
PROBE_PEER_ADDR=${CFWARP_ENDPOINT_PROBE_PEER_ADDR:-169.254.241.2/30}
PROBE_CIDR=${CFWARP_ENDPOINT_PROBE_CIDR:-169.254.241.0/30}
PROBE_NAT_CHAIN="CFPRN${PROBE_TOKEN}"
PROBE_FWD_CHAIN="CFPRF${PROBE_TOKEN}"
PROBE_WG_INTERFACE="wgp${PROBE_TOKEN}"
LOCK_DIR="${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
LOCK_HELD=0
SERVICE_WAS_ACTIVE=0
SERVICE_RESTORED=0

cleanup() {
    CFWARP_EXIT_STATUS=$?
    CFWARP_MODE=netns-proxy \
    NETNS_NAME="$PROBE_NETNS" \
    NETNS_HOST_IF="$PROBE_HOST_IF" \
    NETNS_NS_IF="$PROBE_NS_IF" \
    CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
    NETNS_HOST_ADDR="$PROBE_HOST_ADDR" \
    NETNS_PEER_ADDR="$PROBE_PEER_ADDR" \
    NETNS_CIDR="$PROBE_CIDR" \
    NAT_CHAIN="$PROBE_NAT_CHAIN" \
    FWD_CHAIN="$PROBE_FWD_CHAIN" \
    WG_QUICK_BIN="$WG_QUICK_BIN" \
    sh "$SCRIPT_DIR/cfwarp-netns.sh" down >/dev/null 2>&1 || true
    if [ "$SERVICE_WAS_ACTIVE" = "1" ] && [ "$SERVICE_RESTORED" != "1" ] && systemd_available; then
        systemctl start "$CFWARP_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if [ "$LOCK_HELD" = "1" ]; then
        rm -f "$LOCK_PID_FILE" >/dev/null 2>&1 || true
        rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
    exit "$CFWARP_EXIT_STATUS"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

install -d -m 0700 "$CFWARP_ENDPOINT_REFRESH_STATE_ROOT"
if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    LOCK_HELD=1
else
    LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "==> [CFwarp] 已有 Endpoint 刷新任务在运行，跳过本次执行。"
        exit 0
    fi
    rm -f "$LOCK_PID_FILE" >/dev/null 2>&1 || true
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "==> [CFwarp] 无法取得 Endpoint 刷新锁，跳过本次执行。"
        exit 0
    fi
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    LOCK_HELD=1
fi

if systemd_available && systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
    SERVICE_WAS_ACTIVE=1
    if [ "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" = "skip" ]; then
        echo "==> [CFwarp] ${CFWARP_SERVICE_NAME} 正在运行，默认跳过刷新以避免停服。"
        exit 0
    fi
    echo "==> [CFwarp] 已启用 stop-and-probe，暂时停止 ${CFWARP_SERVICE_NAME}。"
    systemctl stop "$CFWARP_SERVICE_NAME"
fi

CANDIDATE_FILE="${TMP_ROOT}/candidates.txt"
build_candidate_endpoints "$CURRENT_ENDPOINT" > "$CANDIDATE_FILE"
if [ ! -s "$CANDIDATE_FILE" ]; then
    echo "==> [CFwarp] 没有可评估的 Endpoint，保持当前配置。"
    exit 0
fi

CFWARP_MODE=netns-proxy \
NETNS_NAME="$PROBE_NETNS" \
NETNS_HOST_IF="$PROBE_HOST_IF" \
NETNS_NS_IF="$PROBE_NS_IF" \
CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
NETNS_HOST_ADDR="$PROBE_HOST_ADDR" \
NETNS_PEER_ADDR="$PROBE_PEER_ADDR" \
NETNS_CIDR="$PROBE_CIDR" \
NAT_CHAIN="$PROBE_NAT_CHAIN" \
FWD_CHAIN="$PROBE_FWD_CHAIN" \
WG_QUICK_BIN="$WG_QUICK_BIN" \
sh "$SCRIPT_DIR/cfwarp-netns.sh" up

BEST_ENDPOINT=
BEST_SCORE=
BEST_READY=
BEST_HTTP_AVG=
BEST_EXIT_IP=
CURRENT_SCORE=
INDEX=1
while IFS= read -r CANDIDATE_ENDPOINT; do
    [ -n "$CANDIDATE_ENDPOINT" ] || continue
    if ! cfwarp_validate_endpoint "$CANDIDATE_ENDPOINT"; then
        echo "==> [CFwarp] 跳过非法 Endpoint。" >&2
        continue
    fi
    CANDIDATE_DIR="${TMP_ROOT}/candidate-${INDEX}"
    CANDIDATE_METRICS="${CANDIDATE_DIR}/metrics.env"
    PROBE_WG_CONF="${CANDIDATE_DIR}/${PROBE_WG_INTERFACE}.conf"
    install -d -m 0700 "$CANDIDATE_DIR"
    if [ ! -f "$WGCF_PROFILE" ] && [ -f "$WG_CONF" ]; then
        install -m 0600 "$WG_CONF" "$PROBE_WG_CONF"
    fi
    echo "==> [CFwarp] 正在评估 Endpoint: ${CANDIDATE_ENDPOINT}"
    PROBE_LOG="${CANDIDATE_DIR}/probe.log"
    if [ "$TIMEOUT_AVAILABLE" = "1" ]; then
        if run_timeout "$CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS" \
            ip netns exec "$PROBE_NETNS" env \
            CFWARP_MODE=host-global \
            WG_INTERFACE="$PROBE_WG_INTERFACE" \
            CFWARP_DATA_DIR="$CFWARP_DATA_DIR" \
            WG_CONF_DIR="$CANDIDATE_DIR" \
            WG_CONF="$PROBE_WG_CONF" \
            WGCF_PROFILE="$WGCF_PROFILE" \
            WGCF_ACCOUNT="$WGCF_ACCOUNT" \
            WG_QUICK_BIN="$WG_QUICK_BIN" \
            WGCF_VERSION="${WGCF_VERSION:-}" \
            WGCF_SHA256="${WGCF_SHA256:-}" \
            CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD="${CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD:-0}" \
            ENDPOINT_IP="$CANDIDATE_ENDPOINT" \
            ENDPOINT_CANDIDATES= \
            WARP_READY_ATTEMPTS="${WARP_READY_ATTEMPTS:-}" \
            WARP_READY_DELAY_SECONDS="${WARP_READY_DELAY_SECONDS:-}" \
            WARP_HEALTHCHECK_CONNECT_TIMEOUT="${WARP_HEALTHCHECK_CONNECT_TIMEOUT:-}" \
            WARP_HEALTHCHECK_TOTAL_TIMEOUT="${WARP_HEALTHCHECK_TOTAL_TIMEOUT:-}" \
            WARP_HEALTHCHECK_TRACE_URL="${WARP_HEALTHCHECK_TRACE_URL:-}" \
            WARP_HEALTHCHECK_TEST_URL="${WARP_HEALTHCHECK_TEST_URL:-}" \
            CFWARP_PROBE_MODE=1 \
            CFWARP_PROBE_URL="$CFWARP_ENDPOINT_PROBE_URL" \
            CFWARP_PROBE_SAMPLES="$CFWARP_ENDPOINT_PROBE_SAMPLES" \
            CFWARP_PROBE_METRICS_FILE="$CANDIDATE_METRICS" \
            sh "$SCRIPT_DIR/entrypoint.sh" > "$PROBE_LOG" 2>&1; then
            PROBE_STATUS=0
        else
            PROBE_STATUS=$?
        fi
    else
        echo "==> [CFwarp] 未找到 timeout，使用入口脚本自身的超时参数。" >&2
        if ip netns exec "$PROBE_NETNS" env \
            CFWARP_MODE=host-global WG_INTERFACE="$PROBE_WG_INTERFACE" CFWARP_DATA_DIR="$CFWARP_DATA_DIR" \
            WG_CONF_DIR="$CANDIDATE_DIR" WG_CONF="$PROBE_WG_CONF" WGCF_PROFILE="$WGCF_PROFILE" \
            WGCF_ACCOUNT="$WGCF_ACCOUNT" WG_QUICK_BIN="$WG_QUICK_BIN" ENDPOINT_IP="$CANDIDATE_ENDPOINT" \
            ENDPOINT_CANDIDATES= CFWARP_PROBE_MODE=1 CFWARP_PROBE_URL="$CFWARP_ENDPOINT_PROBE_URL" \
            CFWARP_PROBE_SAMPLES="$CFWARP_ENDPOINT_PROBE_SAMPLES" CFWARP_PROBE_METRICS_FILE="$CANDIDATE_METRICS" \
            sh "$SCRIPT_DIR/entrypoint.sh" > "$PROBE_LOG" 2>&1; then
            PROBE_STATUS=0
        else
            PROBE_STATUS=$?
        fi
    fi
    if [ "$PROBE_STATUS" -eq 0 ] && [ -f "$CANDIDATE_METRICS" ]; then
        SELECTED_ENDPOINT=$(metric SELECTED_ENDPOINT "$CANDIDATE_METRICS")
        READY_SECONDS=$(metric READY_SECONDS "$CANDIDATE_METRICS")
        HTTP_AVG_TOTAL=$(metric HTTP_AVG_TOTAL "$CANDIDATE_METRICS")
        SCORE=$(metric SCORE "$CANDIDATE_METRICS")
        EXIT_IP=$(metric EXIT_IP "$CANDIDATE_METRICS")
        if [ -n "$SELECTED_ENDPOINT" ] && [ -n "$SCORE" ] && score_is_better "$SCORE" "$BEST_SCORE"; then
            BEST_ENDPOINT=$SELECTED_ENDPOINT
            BEST_SCORE=$SCORE
            BEST_READY=$READY_SECONDS
            BEST_HTTP_AVG=$HTTP_AVG_TOTAL
            BEST_EXIT_IP=$EXIT_IP
        fi
        if [ "$CANDIDATE_ENDPOINT" = "$CURRENT_ENDPOINT" ]; then
            CURRENT_SCORE=$SCORE
        fi
        echo "==> [CFwarp] Endpoint ${CANDIDATE_ENDPOINT} 评估完成: ready=${READY_SECONDS}s avg=${HTTP_AVG_TOTAL}s score=${SCORE}"
    else
        if [ "$PROBE_STATUS" -eq 124 ]; then
            echo "==> [CFwarp] Endpoint ${CANDIDATE_ENDPOINT} 评估超时，已跳过。" >&2
        else
            echo "==> [CFwarp] Endpoint ${CANDIDATE_ENDPOINT} 评估失败，已跳过。" >&2
        fi
        [ -f "$PROBE_LOG" ] && sed -n '1,80p' "$PROBE_LOG" >&2 || true
    fi
    ip netns exec "$PROBE_NETNS" "$WG_QUICK_BIN" down "$PROBE_WG_INTERFACE" >/dev/null 2>&1 || true
    INDEX=$((INDEX + 1))
done < "$CANDIDATE_FILE"

if [ -z "$BEST_ENDPOINT" ]; then
    echo "==> [CFwarp] 所有候选 Endpoint 都未通过评估，保持当前配置。"
    exit 0
fi

SELECTED_ENDPOINT=$BEST_ENDPOINT
if [ -n "$CURRENT_ENDPOINT" ] && [ "$BEST_ENDPOINT" != "$CURRENT_ENDPOINT" ]; then
    if [ -n "$CURRENT_SCORE" ]; then
        IMPROVEMENT_PERCENT=$(awk -v current="$CURRENT_SCORE" -v best="$BEST_SCORE" 'BEGIN { if (current <= 0) print 100; else printf "%.2f", ((current - best) / current) * 100 }')
        if ! awk -v gain="$IMPROVEMENT_PERCENT" -v minimum="$CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT" 'BEGIN { exit gain >= minimum ? 0 : 1 }'; then
            echo "==> [CFwarp] 最佳候选仅提升 ${IMPROVEMENT_PERCENT}%（阈值 ${CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT}%），保持当前 Endpoint。"
            SELECTED_ENDPOINT=$CURRENT_ENDPOINT
        fi
    else
        echo "==> [CFwarp] 当前 Endpoint 未获得可比探测结果，保持当前配置。"
        SELECTED_ENDPOINT=$CURRENT_ENDPOINT
    fi
fi

echo "==> [CFwarp] 本次最佳候选: ${SELECTED_ENDPOINT} (score=${BEST_SCORE} exit_ip=${BEST_EXIT_IP:-unknown})"
OLD_ENV_ENDPOINT=$(sed -n 's/^ENDPOINT_IP=//p' "$CFWARP_ENV_FILE" | tail -n 1)
if [ "$SELECTED_ENDPOINT" != "$CURRENT_ENDPOINT" ]; then
    cfwarp_set_env_key ENDPOINT_IP "$SELECTED_ENDPOINT" "$CFWARP_ENV_FILE"
fi

if [ "$SERVICE_WAS_ACTIVE" = "1" ]; then
    if systemctl start "$CFWARP_SERVICE_NAME"; then
        SERVICE_RESTORED=1
        echo "==> [CFwarp] 已恢复 ${CFWARP_SERVICE_NAME}。"
    else
        echo "==> [ERROR] 新 Endpoint 启动失败，正在恢复旧配置。" >&2
        if [ -n "$OLD_ENV_ENDPOINT" ]; then
            cfwarp_set_env_key ENDPOINT_IP "$OLD_ENV_ENDPOINT" "$CFWARP_ENV_FILE" || true
        else
            cfwarp_remove_env_key ENDPOINT_IP "$CFWARP_ENV_FILE" || true
        fi
        systemctl start "$CFWARP_SERVICE_NAME" >/dev/null 2>&1 || true
        SERVICE_RESTORED=1
        exit 1
    fi
elif [ "$SELECTED_ENDPOINT" != "$CURRENT_ENDPOINT" ]; then
    echo "==> [CFwarp] 已保存新 Endpoint，下次启动 ${CFWARP_SERVICE_NAME} 时生效。"
else
    echo "==> [CFwarp] 当前 Endpoint 保持不变。"
fi
