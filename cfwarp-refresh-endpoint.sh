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

read_service_state() {
    SERVICE_STATE=$(systemctl show --property=ActiveState --value "$CFWARP_SERVICE_NAME") || return 1
    case "$SERVICE_STATE" in
        inactive|failed) SERVICE_BUSY=0 ;;
        active|activating|deactivating|reloading|refreshing|maintenance) SERVICE_BUSY=1 ;;
        *) echo '==> [ERROR] 无法确认主服务状态，拒绝继续刷新。' >&2; return 1 ;;
    esac
}

stop_and_confirm_service() {
    systemctl stop "$CFWARP_SERVICE_NAME" || return 1
    read_service_state || return 1
    [ "$SERVICE_BUSY" = 0 ] || { echo '==> [ERROR] 主服务尚未停止，拒绝探测或回滚。' >&2; return 1; }
}

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
# Recovery originals are written to persistent storage before any service or
# configuration mutation. A failed run never relies on volatile /tmp or /run.
RECOVERY_ROOT="${CFWARP_DATA_DIR}/recovery"
install -d -m 0700 "$RECOVERY_ROOT"
TMP_ROOT=$(mktemp -d "${RECOVERY_ROOT}/endpoint-refresh-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
RECOVERY_REQUIRED=0
RECOVERY_LOG="${TMP_ROOT}/recovery.log"
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
CFWARP_CAN_RESTART=1
LIFECYCLE_LOCKED=0
REFRESH_GUARD_OWNED=0
CONFIG_CHANGED=0
HAD_WG_CONF=0
[ -f "$WG_CONF" ] && HAD_WG_CONF=1

record_recovery_event() {
    if ! printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RECOVERY_LOG"; then
        RECOVERY_REQUIRED=1
        echo "==> [ERROR] 无法写入恢复日志: $RECOVERY_LOG" >&2
        return 1
    fi
}

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
    CFWARP_RESTORE_FAILED=0
    if cfwarp_atomic_write_from_stdin "$CFWARP_ENV_FILE" < "${TMP_ROOT}/original.env" >> "$RECOVERY_LOG" 2>&1; then
        record_recovery_event 'Original environment restored.' || return 1
    else
        record_recovery_event 'FAILED: original environment could not be restored.' || true
        CFWARP_RESTORE_FAILED=1
    fi
    if [ "$HAD_WG_CONF" = "1" ]; then
        if cfwarp_atomic_write_from_stdin "$WG_CONF" < "${TMP_ROOT}/original-wg.conf" >> "$RECOVERY_LOG" 2>&1; then
            record_recovery_event 'Original WireGuard configuration restored.' || return 1
        else
            record_recovery_event 'FAILED: original WireGuard configuration could not be restored.' || true
            CFWARP_RESTORE_FAILED=1
        fi
    elif rm -f "$WG_CONF" >> "$RECOVERY_LOG" 2>&1; then
        record_recovery_event 'Generated WireGuard configuration removed; none existed before refresh.' || return 1
    else
        record_recovery_event 'FAILED: generated WireGuard configuration could not be removed.' || true
        CFWARP_RESTORE_FAILED=1
    fi
    [ "$CFWARP_RESTORE_FAILED" -eq 0 ] || return 1
    CONFIG_CHANGED=0
}

acquire_refresh_guard() {
    [ "$LIFECYCLE_LOCKED" = 0 ] || return 0
    cfwarp_lifecycle_lock "$CFWARP_DATA_DIR" || return 1
    LIFECYCLE_LOCKED=1
    cfwarp_refresh_is_clear || return 1
    # systemctl startup may have raced the earlier stop/state observation.
    # New cfwarp-start processes cannot pass fd 6 while we hold this lock.
    if systemd_available; then
        read_service_state || return 1
        [ "$SERVICE_BUSY" = 0 ] || return 1
    fi
    printf '%s\n' "$TMP_ROOT/RECOVERY.txt" | cfwarp_atomic_write_from_stdin "$CFWARP_REFRESH_PENDING" || return 1
    REFRESH_GUARD_OWNED=1
}

release_refresh_guard() {
    [ "$LIFECYCLE_LOCKED" = 1 ] || return 0
    [ "$PROBE_NETWORK_DIRTY" = 0 ] && [ "$CFWARP_CAN_RESTART" = 1 ] || return 1
    if [ "$REFRESH_GUARD_OWNED" = 1 ]; then
        rm -f "$CFWARP_REFRESH_PENDING" || return 1
        REFRESH_GUARD_OWNED=0
    fi
    cfwarp_lifecycle_unlock || return 1
    LIFECYCLE_LOCKED=0
}

start_and_verify_service() {
    [ "$CFWARP_CAN_RESTART" = 1 ] && [ "$PROBE_NETWORK_DIRTY" = 0 ] || return 1
    # Never hold the gate while asking systemd to start a service that needs it.
    release_refresh_guard || return 1
    record_recovery_event 'Starting service and checking SOCKS/WARP health.' || return 1
    if systemctl start "$CFWARP_SERVICE_NAME" >> "$RECOVERY_LOG" 2>&1 &&
        "$SCRIPT_DIR/cfwarp-healthcheck.sh" --wait >> "$RECOVERY_LOG" 2>&1 &&
        systemctl is-active --quiet "$CFWARP_SERVICE_NAME" >> "$RECOVERY_LOG" 2>&1; then
        record_recovery_event 'Service is active and SOCKS/WARP health passed.'
    else
        RECOVERY_REQUIRED=1
        record_recovery_event 'FAILED: service start or SOCKS/WARP health verification.' || true
        return 1
    fi
}

cleanup() {
    CFWARP_EXIT_STATUS=$?
    trap - EXIT HUP INT TERM
    stop_probe_processes
    if ! cleanup_probe_network >> "$RECOVERY_LOG" 2>&1; then
        CFWARP_CAN_RESTART=0
        RECOVERY_REQUIRED=1
        CFWARP_EXIT_STATUS=1
        record_recovery_event 'FAILED: probe network cleanup; ownership state must be inspected.' || true
    fi
    if [ "$SERVICE_NEEDS_RESTORE" = "1" ]; then
        if [ "$CONFIG_CHANGED" = "1" ]; then
            if ! stop_and_confirm_service >> "$RECOVERY_LOG" 2>&1 ||
                ! acquire_refresh_guard >> "$RECOVERY_LOG" 2>&1; then
                RECOVERY_REQUIRED=1
                CFWARP_EXIT_STATUS=1
                CFWARP_CAN_RESTART=0
                record_recovery_event 'FAILED: service stop; configuration rollback was not attempted.' || true
            elif ! restore_original_config; then
                RECOVERY_REQUIRED=1
                CFWARP_EXIT_STATUS=1
                CFWARP_CAN_RESTART=0
                record_recovery_event 'FAILED: configuration rollback is incomplete; service was not restarted.' || true
            fi
        fi
        if [ "$CFWARP_CAN_RESTART" = "1" ]; then
            if start_and_verify_service; then
                echo "==> [CFwarp] 原服务已恢复并通过 SOCKS/WARP 健康检查。"
            else
                echo "==> [ERROR] 原服务恢复后未通过健康检查。" >&2
                CFWARP_EXIT_STATUS=1
            fi
        else
            echo "==> [ERROR] 自动回滚未完成，已停止自动启动，请按恢复说明处理。" >&2
        fi
    elif [ "$CONFIG_CHANGED" = "1" ]; then
        # A failure during an inactive service's configuration save is also
        # recoverable; do not discard originals after a partial write failure.
        RECOVERY_REQUIRED=1
        if [ "$LIFECYCLE_LOCKED" != 1 ] || ! restore_original_config; then
            CFWARP_CAN_RESTART=0
            CFWARP_EXIT_STATUS=1
            record_recovery_event 'FAILED: inactive-service configuration rollback.' || true
        fi
    fi
    if ! release_refresh_guard; then
        RECOVERY_REQUIRED=1
        CFWARP_EXIT_STATUS=1
        record_recovery_event 'FAILED: startup remains blocked by the refresh recovery marker.' || true
    fi
    if [ "$RECOVERY_REQUIRED" = "1" ]; then
        record_recovery_event "Recovery material retained; refresh exit status: $CFWARP_EXIT_STATUS." || true
        echo "==> [ERROR] 原配置与恢复说明已保留: ${TMP_ROOT}/RECOVERY.txt" >&2
        echo "==> [ERROR] 恢复日志（仅限本机授权用户读取）: $RECOVERY_LOG" >&2
    else
        rm -rf "$TMP_ROOT"
    fi
    exit "$CFWARP_EXIT_STATUS"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

cat > "$TMP_ROOT/RECOVERY.txt" <<EOF_EARLY_RECOVERY
Refresh stopped before probing / 刷新尚未开始探测
Service / 服务: $CFWARP_SERVICE_NAME
This refresh has not changed configuration. Backups may not yet exist.
本次刷新尚未改动配置，备份可能尚未创建。
Inspect recovery.log, service state, and any existing .refresh-pending marker
in $CFWARP_DATA_DIR before restarting or running another refresh.
重启或再次刷新前，请检查恢复日志、服务状态及数据目录中的既有阻断标记。
EOF_EARLY_RECOVERY

if systemd_available; then
    read_service_state
    if [ "$SERVICE_BUSY" = 1 ]; then
        if [ "$CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE" = skip ]; then
            echo "==> [CFwarp] ${CFWARP_SERVICE_NAME} 正在运行或转换状态，跳过刷新。"
            exit 0
        fi
        SERVICE_NEEDS_RESTORE=1
        echo "==> [CFwarp] 已启用 stop-and-probe，暂时停止 ${CFWARP_SERVICE_NAME}。"
        if ! stop_and_confirm_service; then
            CFWARP_CAN_RESTART=0
            RECOVERY_REQUIRED=1
            exit 1
        fi
    fi
fi
if ! acquire_refresh_guard; then
    CFWARP_CAN_RESTART=0
    RECOVERY_REQUIRED=1
    exit 1
fi
# Re-read the source after shutdown and locking; startup may have committed a
# healthy endpoint while its ExecStartPost check was still running.
if [ -f "$WG_CONF" ]; then SOURCE_CONF=$WG_CONF; HAD_WG_CONF=1; else SOURCE_CONF=$WGCF_PROFILE; HAD_WG_CONF=0; fi
CURRENT_ENDPOINT=$(config_endpoint "$SOURCE_CONF")
CURRENT_ENDPOINT=${CURRENT_ENDPOINT:-$ENDPOINT_IP}

install -m 0600 "$SOURCE_CONF" "${TMP_ROOT}/original-wg.conf"
install -m 0600 "$CFWARP_ENV_FILE" "${TMP_ROOT}/original.env"
cat > "${TMP_ROOT}/RECOVERY.txt" <<EOF_RECOVERY
CFWarp endpoint refresh recovery / Endpoint 刷新恢复

Service / 服务: $CFWARP_SERVICE_NAME
Original environment backup / 原环境备份: ${TMP_ROOT}/original.env
Environment destination / 环境文件原位置: $CFWARP_ENV_FILE
Original WireGuard source / 原 WireGuard 配置来源: $SOURCE_CONF
Original WireGuard backup / 原 WireGuard 备份: ${TMP_ROOT}/original-wg.conf
WireGuard runtime destination / WireGuard 运行配置位置: $WG_CONF
Runtime config existed before refresh / 刷新前运行配置存在 (1=yes, 0=no): $HAD_WG_CONF
Probe namespace / 探测命名空间: $PROBE_NETNS
Probe ownership state / 探测资源归属状态: $PROBE_STATE_DIR
Startup block / 启动阻断标记: $CFWARP_REFRESH_PENDING
Log / 日志: $RECOVERY_LOG
Health check command / 健康检查脚本: ${SCRIPT_DIR}/cfwarp-healthcheck.sh --wait

Manual recovery / 人工恢复:
1. Inspect recovery.log and stop the service before changing its configuration.
   查看日志，并在改动配置前停止上述服务。
2. Restore original.env to its destination above; keep mode 0600.
   将 original.env 恢复至上述环境文件位置，权限保持 0600。
3. If the runtime config existed (1), restore original-wg.conf to the runtime
   destination with mode 0600. Otherwise (0), confirm and remove only the runtime
   config generated by this refresh; the backup came from the profile source.
   若运行配置原先存在(1)，恢复 original-wg.conf，权限 0600；若原先不存在(0)，
   核实后仅移除本次刷新生成的运行配置，备份来自原 profile。
4. Clean any remaining probe resources using their ownership state. Confirm the
   probe WireGuard interface is gone and configuration recovery is complete,
   then remove the startup block above. Start the service, run the health
   check with the same CFWARP_ENV_FILE, and verify that the service stays active.
   按归属状态清理探测残留；确认探测 WireGuard 接口已删除且配置恢复完整后，
   删除上述启动阻断标记，再启动服务并用相同环境文件运行健康检查。
5. Delete only this recovery directory after recovery has been verified.
   仅在验证恢复完成后，删除本次恢复目录。

Backups contain credentials. Do not publish them or source them as shell code.
备份包含凭证，请勿公开或作为 Shell 脚本执行。
EOF_RECOVERY
record_recovery_event 'Protected original configurations saved before refresh.'

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
    if ! RESOLVED_CANDIDATE_ENDPOINT=$(cfwarp_resolve_endpoint "$CANDIDATE_ENDPOINT"); then
        echo "==> [CFwarp] 宿主机无法解析候选 Endpoint，已跳过。" >&2
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
        ENDPOINT_IP="$RESOLVED_CANDIDATE_ENDPOINT" ENDPOINT_CANDIDATES='' \
        CFWARP_PROBE_MODE=1 CFWARP_PROBE_URL="$CFWARP_ENDPOINT_PROBE_URL" \
        CFWARP_PROBE_SAMPLES="$CFWARP_ENDPOINT_PROBE_SAMPLES" CFWARP_PROBE_METRICS_FILE="$CANDIDATE_METRICS" \
        setsid timeout --kill-after=5 "$CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS" \
        sh "${TMP_ROOT}/worker.sh" > "${CANDIDATE_DIR}/probe.log" 2>&1 9>&- 6>&- &
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
    if [ "$SELECTED_ENDPOINT" != "$RESOLVED_CANDIDATE_ENDPOINT" ] || ! cfwarp_validate_endpoint "$RUNTIME_ENDPOINT" || ! valid_score "$SCORE"; then
        echo "==> [ERROR] 候选指标与实际探测目标不一致或格式非法，忽略结果。" >&2
        continue
    fi
    if score_is_better "$SCORE" "$BEST_SCORE"; then
        BEST_ENDPOINT=$CANDIDATE_ENDPOINT
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
