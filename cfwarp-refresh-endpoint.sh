#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
COMMON_FILE="${SCRIPT_DIR}/lib/cfwarp-common.sh"
[ -r "$COMMON_FILE" ] || { echo "==> [ERROR] 找不到共享库: $COMMON_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$COMMON_FILE"
cfwarp_load_env "$SCRIPT_DIR" || exit 1
[ -r "$CFWARP_ENV_FILE" ] || { echo "==> [ERROR] 未找到可读的环境文件: $CFWARP_ENV_FILE" >&2; exit 1; }

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
    echo "==> [CFwarp] Endpoint 自动评估仅支持 netns-proxy。"
    exit 0
fi
case "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" in
    skip|stop-and-probe) ;;
    *) echo "==> [ERROR] CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE 仅支持 skip 或 stop-and-probe。" >&2; exit 1 ;;
esac
cfwarp_validate_uint "$CFWARP_ENDPOINT_PROBE_SAMPLES" CFWARP_ENDPOINT_PROBE_SAMPLES 1 100 || exit 1
cfwarp_validate_uint "$CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS" CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS 5 1800 || exit 1
cfwarp_validate_uint "$CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT" CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT 0 100 || exit 1
# Refresh needs a whole-process-group timeout, including namespace setup.
for dependency in flock timeout setsid; do
    command -v "$dependency" >/dev/null 2>&1 || { echo "==> [ERROR] Endpoint 刷新缺少依赖: $dependency" >&2; exit 1; }
done

config_endpoint() {
    awk '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit}' "$1"
}
metric() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$2"; }
valid_score() { printf '%s\n' "$1" | awk '/^[0-9]+([.][0-9]+)?$/ { valid = 1 } END { exit NR == 1 && valid ? 0 : 1 }'; }
score_is_better() { awk -v new="$1" -v old="${2:-}" 'BEGIN { exit old == "" || new + 0 < old + 0 ? 0 : 1 }'; }
systemd_available() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

if [ -f "$WG_CONF" ]; then
    SOURCE_CONF=$WG_CONF
elif [ -f "$WGCF_PROFILE" ]; then
    SOURCE_CONF=$WGCF_PROFILE
else
    echo "==> [CFwarp] 尚未初始化可复用的 WireGuard 配置，跳过自动选择。"
    exit 0
fi
CURRENT_ENDPOINT=$(config_endpoint "$SOURCE_CONF")
CURRENT_ENDPOINT=${CURRENT_ENDPOINT:-$ENDPOINT_IP}

umask 077
install -d -m 0700 "$CFWARP_ENDPOINT_REFRESH_STATE_ROOT"
exec 9>"${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/refresh.lock"
if ! flock -n 9; then
    echo "==> [CFwarp] 已有 Endpoint 刷新任务在运行，跳过本次执行。"
    exit 0
fi
# Keep the lock file: unlinking it can create two independent lock inodes.
TMP_ROOT=$(mktemp -d)
PROBE_TOKEN=$$
PROBE_NETNS="cfpr${PROBE_TOKEN}"
PROBE_HOST_IF="cfh${PROBE_TOKEN}"
PROBE_NS_IF="cfn${PROBE_TOKEN}"
PROBE_WG_IF="wgp${PROBE_TOKEN}"
PROBE_NAT_CHAIN="CFN${PROBE_TOKEN}"
PROBE_FWD_CHAIN="CFF${PROBE_TOKEN}"
PROBE_SUBNET_BASE=$((($$ % 60) * 4))
PROBE_STATE_DIR="${CFWARP_ENDPOINT_REFRESH_STATE_ROOT}/probe-${PROBE_TOKEN}"
ACTIVE_PROBE_PID=
PROBE_NETWORK_DIRTY=0
PROBE_WG_CONF="${TMP_ROOT}/${PROBE_WG_IF}.conf"
SERVICE_NEEDS_RESTORE=0
CONFIG_CHANGED=0
HAD_WG_CONF=0
[ -f "$WG_CONF" ] && HAD_WG_CONF=1
install -m 0600 "$SOURCE_CONF" "${TMP_ROOT}/original-wg.conf"
install -m 0600 "$CFWARP_ENV_FILE" "${TMP_ROOT}/original.env"

stop_probe_processes() {
    [ -n "$ACTIVE_PROBE_PID" ] || return 0
    # setsid gives the timeout and every child an isolated process group.
    kill -TERM "-$ACTIVE_PROBE_PID" 2>/dev/null || true
    CFWARP_KILL_WAIT=0
    while kill -0 "-$ACTIVE_PROBE_PID" 2>/dev/null && [ "$CFWARP_KILL_WAIT" -lt 5 ]; do
        sleep 1
        CFWARP_KILL_WAIT=$((CFWARP_KILL_WAIT + 1))
    done
    kill -KILL "-$ACTIVE_PROBE_PID" 2>/dev/null || true
    wait "$ACTIVE_PROBE_PID" 2>/dev/null || true
    ACTIVE_PROBE_PID=
}

cleanup_probe_network() {
    [ "$PROBE_NETWORK_DIRTY" = "1" ] || return 0
    if CFWARP_ENV_LOADED=1 CFWARP_MODE=netns-proxy \
        NETNS_NAME="$PROBE_NETNS" NETNS_HOST_IF="$PROBE_HOST_IF" NETNS_NS_IF="$PROBE_NS_IF" \
        CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
        NETNS_HOST_ADDR="169.254.241.$((PROBE_SUBNET_BASE + 1))/30" \
        NETNS_PEER_ADDR="169.254.241.$((PROBE_SUBNET_BASE + 2))/30" \
        NETNS_CIDR="169.254.241.${PROBE_SUBNET_BASE}/30" \
        NAT_CHAIN="$PROBE_NAT_CHAIN" FWD_CHAIN="$PROBE_FWD_CHAIN" \
        WG_INTERFACE="$PROBE_WG_IF" WG_CONF="$PROBE_WG_CONF" WG_QUICK_BIN="$WG_QUICK_BIN" \
        sh "$SCRIPT_DIR/cfwarp-netns.sh" down; then
        PROBE_NETWORK_DIRTY=0
    else
        echo "==> [ERROR] 探测 namespace 清理失败: $PROBE_NETNS" >&2
        return 1
    fi
}

restore_original_config() {
    [ "$CONFIG_CHANGED" = "1" ] || return 0
    cat "${TMP_ROOT}/original.env" | cfwarp_atomic_write_from_stdin "$CFWARP_ENV_FILE" || return 1
    if [ "$HAD_WG_CONF" = "1" ]; then
        cat "${TMP_ROOT}/original-wg.conf" | cfwarp_atomic_write_from_stdin "$WG_CONF" || return 1
    else
        rm -f "$WG_CONF" || return 1
    fi
    CONFIG_CHANGED=0
}

start_and_verify_service() {
    systemctl start "$CFWARP_SERVICE_NAME" &&
        "$SCRIPT_DIR/cfwarp-healthcheck.sh" --wait &&
        systemctl is-active --quiet "$CFWARP_SERVICE_NAME"
}

cleanup() {
    CFWARP_EXIT_STATUS=$?
    trap - EXIT HUP INT TERM
    stop_probe_processes
    cleanup_probe_network || CFWARP_EXIT_STATUS=1
    if [ "$SERVICE_NEEDS_RESTORE" = "1" ]; then
        if [ "$CONFIG_CHANGED" = "1" ]; then
            systemctl stop "$CFWARP_SERVICE_NAME" || CFWARP_EXIT_STATUS=1
            restore_original_config || CFWARP_EXIT_STATUS=1
        fi
        if start_and_verify_service; then
            echo "==> [CFwarp] 原服务已恢复并通过 SOCKS/WARP 健康检查。"
        else
            echo "==> [ERROR] 原服务恢复后未通过健康检查，请检查 systemd 日志。" >&2
            CFWARP_EXIT_STATUS=1
        fi
    fi
    rm -rf "$TMP_ROOT"
    exit "$CFWARP_EXIT_STATUS"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

if systemd_available && systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
    if [ "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" = "skip" ]; then
        echo "==> [CFwarp] ${CFWARP_SERVICE_NAME} 正在运行，默认跳过刷新以避免停服。"
        exit 0
    fi
    SERVICE_NEEDS_RESTORE=1
    echo "==> [CFwarp] 已启用 stop-and-probe，暂时停止 ${CFWARP_SERVICE_NAME}。"
    systemctl stop "$CFWARP_SERVICE_NAME"
fi

CANDIDATE_FILE="${TMP_ROOT}/candidates.txt"
{
    [ -n "$CURRENT_ENDPOINT" ] && printf '%s\n' "$CURRENT_ENDPOINT"
    [ -n "$ENDPOINT_IP" ] && printf '%s\n' "$ENDPOINT_IP"
    printf '%s\n' "$ENDPOINT_CANDIDATES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
} | awk 'NF && !seen[$0]++' > "$CANDIDATE_FILE"
if [ ! -s "$CANDIDATE_FILE" ]; then
    echo "==> [ERROR] 没有可评估的 Endpoint。" >&2
    exit 1
fi

# The same WARP identity is never active in concurrent candidate tunnels.
# A separate worker is used so setup, probes and descendants share a timeout.
cat > "${TMP_ROOT}/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
sh "$CFWARP_REFRESH_SCRIPT_DIR/cfwarp-netns.sh" up
exec ip netns exec "$NETNS_NAME" env CFWARP_MODE=host-global \
    sh "$CFWARP_REFRESH_SCRIPT_DIR/entrypoint.sh"
WORKER

BEST_ENDPOINT=
BEST_SCORE=
CURRENT_SCORE=
INDEX=0
while IFS= read -r CANDIDATE_ENDPOINT; do
    [ -n "$CANDIDATE_ENDPOINT" ] || continue
    if ! cfwarp_validate_endpoint "$CANDIDATE_ENDPOINT"; then
        echo "==> [CFwarp] 跳过非法 Endpoint。" >&2
        continue
    fi
    INDEX=$((INDEX + 1))
    [ "$INDEX" -le 60 ] || { echo "==> [CFwarp] 达到候选数限制，忽略多余 Endpoint。" >&2; break; }
    CANDIDATE_DIR="${TMP_ROOT}/candidate-${INDEX}"
    install -d -m 0700 "$CANDIDATE_DIR"
    CANDIDATE_CONF="${CANDIDATE_DIR}/${PROBE_WG_IF}.conf"
    PROBE_WG_CONF=$CANDIDATE_CONF
    CANDIDATE_METRICS="${CANDIDATE_DIR}/metrics.env"
    install -m 0600 "${TMP_ROOT}/original-wg.conf" "$CANDIDATE_CONF"
    echo "==> [CFwarp] 正在评估 Endpoint: $CANDIDATE_ENDPOINT"
    PROBE_NETWORK_DIRTY=1
    CFWARP_ENV_LOADED=1 CFWARP_REFRESH_SCRIPT_DIR="$SCRIPT_DIR" CFWARP_MODE=netns-proxy \
        NETNS_NAME="$PROBE_NETNS" NETNS_HOST_IF="$PROBE_HOST_IF" NETNS_NS_IF="$PROBE_NS_IF" \
        CFWARP_STATE_DIR="$PROBE_STATE_DIR" \
        NETNS_HOST_ADDR="169.254.241.$((PROBE_SUBNET_BASE + 1))/30" \
        NETNS_PEER_ADDR="169.254.241.$((PROBE_SUBNET_BASE + 2))/30" \
        NETNS_CIDR="169.254.241.${PROBE_SUBNET_BASE}/30" \
        NAT_CHAIN="$PROBE_NAT_CHAIN" FWD_CHAIN="$PROBE_FWD_CHAIN" \
        WG_INTERFACE="$PROBE_WG_IF" WG_QUICK_BIN="$WG_QUICK_BIN" \
        CFWARP_DATA_DIR="$CANDIDATE_DIR" WG_CONF_DIR="$CANDIDATE_DIR" WG_CONF="$CANDIDATE_CONF" \
        WGCF_PROFILE="${TMP_ROOT}/original-wg.conf" WGCF_ACCOUNT="$WGCF_ACCOUNT" \
        ENDPOINT_IP="$CANDIDATE_ENDPOINT" ENDPOINT_CANDIDATES='' \
        CFWARP_PROBE_MODE=1 CFWARP_PROBE_URL="$CFWARP_ENDPOINT_PROBE_URL" \
        CFWARP_PROBE_SAMPLES="$CFWARP_ENDPOINT_PROBE_SAMPLES" CFWARP_PROBE_METRICS_FILE="$CANDIDATE_METRICS" \
        setsid timeout --kill-after=5 "$CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS" \
        sh "${TMP_ROOT}/worker.sh" > "${CANDIDATE_DIR}/probe.log" 2>&1 9>&- &
    ACTIVE_PROBE_PID=$!
    PROBE_STATUS=0
    wait "$ACTIVE_PROBE_PID" || PROBE_STATUS=$?
    stop_probe_processes
    cleanup_probe_network || exit 1
    if [ "$PROBE_STATUS" -ne 0 ] || [ ! -f "$CANDIDATE_METRICS" ]; then
        echo "==> [CFwarp] Endpoint $CANDIDATE_ENDPOINT 评估失败或超时（状态 $PROBE_STATUS）。" >&2
        sed -n '1,80p' "${CANDIDATE_DIR}/probe.log" >&2
        continue
    fi
    SELECTED_ENDPOINT=$(metric SELECTED_ENDPOINT "$CANDIDATE_METRICS")
    RUNTIME_ENDPOINT=$(metric RUNTIME_ENDPOINT "$CANDIDATE_METRICS")
    SCORE=$(metric SCORE "$CANDIDATE_METRICS")
    if [ "$SELECTED_ENDPOINT" != "$CANDIDATE_ENDPOINT" ] || ! cfwarp_validate_endpoint "$RUNTIME_ENDPOINT" || ! valid_score "$SCORE"; then
        echo "==> [ERROR] 候选指标与实际探测目标不一致或格式非法，忽略结果。" >&2
        continue
    fi
    if score_is_better "$SCORE" "$BEST_SCORE"; then
        BEST_ENDPOINT=$SELECTED_ENDPOINT
        BEST_SCORE=$SCORE
    fi
    [ "$CANDIDATE_ENDPOINT" != "$CURRENT_ENDPOINT" ] || CURRENT_SCORE=$SCORE
    echo "==> [CFwarp] Endpoint $CANDIDATE_ENDPOINT 评估完成: score=$SCORE actual=$RUNTIME_ENDPOINT"
done < "$CANDIDATE_FILE"

if [ -z "$BEST_ENDPOINT" ]; then
    echo "==> [ERROR] 所有候选 Endpoint 均未通过评估，保留原配置。" >&2
    exit 1
fi
SELECTED_ENDPOINT=$BEST_ENDPOINT
if [ -n "$CURRENT_SCORE" ] && [ "$BEST_ENDPOINT" != "$CURRENT_ENDPOINT" ]; then
    IMPROVEMENT_PERCENT=$(awk -v current="$CURRENT_SCORE" -v best="$BEST_SCORE" 'BEGIN { if (current <= 0) print 0; else printf "%.2f", ((current - best) / current) * 100 }')
    if ! awk -v gain="$IMPROVEMENT_PERCENT" -v minimum="$CFWARP_ENDPOINT_SWITCH_MIN_IMPROVEMENT_PERCENT" 'BEGIN { exit gain >= minimum ? 0 : 1 }'; then
        echo "==> [CFwarp] 候选提升 ${IMPROVEMENT_PERCENT}% 未达到阈值，保留当前健康 Endpoint。"
        SELECTED_ENDPOINT=$CURRENT_ENDPOINT
    fi
elif [ "$BEST_ENDPOINT" != "$CURRENT_ENDPOINT" ]; then
    echo "==> [CFwarp] 当前 Endpoint 未通过评估，选择已验证可用的候选。"
fi

if [ "$SELECTED_ENDPOINT" != "$CURRENT_ENDPOINT" ] || [ "$SELECTED_ENDPOINT" != "$ENDPOINT_IP" ]; then
    CONFIG_CHANGED=1
    cfwarp_set_env_key ENDPOINT_IP "$SELECTED_ENDPOINT" "$CFWARP_ENV_FILE"
fi
if [ "$SERVICE_NEEDS_RESTORE" = "1" ]; then
    if start_and_verify_service; then
        SERVICE_NEEDS_RESTORE=0
        CONFIG_CHANGED=0
        echo "==> [CFwarp] Endpoint $SELECTED_ENDPOINT 已启用，服务恢复并通过健康检查。"
    else
        echo "==> [ERROR] Endpoint 启用后健康检查失败，将恢复原配置并验证。" >&2
        exit 1
    fi
else
    CONFIG_CHANGED=0
    echo "==> [CFwarp] 已保存验证通过的 Endpoint $SELECTED_ENDPOINT，下次启动服务时生效。"
fi
