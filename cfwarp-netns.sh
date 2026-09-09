#!/bin/sh
set -eu

ACTION=${1:-}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
COMMON_FILE="${SCRIPT_DIR}/lib/cfwarp-common.sh"
if [ ! -r "$COMMON_FILE" ]; then
    echo "==> [ERROR] 找不到共享库: $COMMON_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$COMMON_FILE"
cfwarp_load_env "$SCRIPT_DIR"

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
NETNS_NAME=${NETNS_NAME:-cfwarp}
NETNS_HOST_IF=${NETNS_HOST_IF:-cfwarp-host}
NETNS_NS_IF=${NETNS_NS_IF:-cfwarp-ns}
NETNS_HOST_ADDR=${NETNS_HOST_ADDR:-169.254.240.1/30}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-169.254.240.2/30}
NETNS_CIDR=${NETNS_CIDR:-169.254.240.0/30}
NETNS_OUT_IF=${NETNS_OUT_IF:-}
NETNS_DNS_SERVERS=${NETNS_DNS_SERVERS:-1.1.1.1 1.0.0.1}
CFWARP_STATE_DIR=${CFWARP_STATE_DIR:-/run/cfwarp}
CFWARP_GLOBAL_STATE_DIR=${CFWARP_GLOBAL_STATE_DIR:-/run/cfwarp}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${SCRIPT_DIR}/var}
WG_INTERFACE=${WG_INTERFACE:-wg0}
WG_CONF_DIR=${WG_CONF_DIR:-$CFWARP_DATA_DIR}
WG_CONF=${WG_CONF:-${WG_CONF_DIR}/${WG_INTERFACE}.conf}
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}
IPTABLES_WAIT_SECONDS=${IPTABLES_WAIT_SECONDS:-5}
CFWARP_LOCK_WAIT_SECONDS=${CFWARP_LOCK_WAIT_SECONDS:-30}
IP_FORWARD_PREV_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.prev"
IP_FORWARD_REF_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.refs"
IP_FORWARD_LOCK_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.flock"
STATE_FILE="${CFWARP_STATE_DIR}/${NETNS_NAME}.env"
RESOLV_DIR="/etc/netns/${NETNS_NAME}"
IP_FORWARD_REF_HELD=0
CFWARP_FORWARD_LOCKED=0
CFWARP_SIGNAL_STATUS=0
CFWARP_SETUP_ACTIVE=0
CFWARP_NS_INODE=
CFWARP_HOST_INDEX=
CFWARP_DNS_CREATED=0
CFWARP_DNS_INODE=
CFWARP_RULES_STARTED=0

fail() { echo "==> [ERROR] $*" >&2; return 1; }

validate_config() {
    cfwarp_validate_netns_name "$NETNS_NAME" NETNS_NAME || return 1
    cfwarp_validate_link_name "$NETNS_HOST_IF" NETNS_HOST_IF || return 1
    cfwarp_validate_link_name "$NETNS_NS_IF" NETNS_NS_IF || return 1
    cfwarp_validate_link_name "$WG_INTERFACE" WG_INTERFACE || return 1
    [ "$NETNS_HOST_IF" != "$NETNS_NS_IF" ] || { fail 'veth 两端名称必须不同。'; return 1; }
    cfwarp_validate_uint "$IPTABLES_WAIT_SECONDS" IPTABLES_WAIT_SECONDS 0 60 || return 1
    cfwarp_validate_uint "$CFWARP_LOCK_WAIT_SECONDS" CFWARP_LOCK_WAIT_SECONDS 1 600 || return 1
    for CFWARP_ADDRESS in "$NETNS_HOST_ADDR" "$NETNS_PEER_ADDR" "$NETNS_CIDR"; do
        printf '%s\n' "$CFWARP_ADDRESS" | awk -F'[./]' '
            NF != 5 {exit 1}
            {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1;
             if($5 !~ /^[0-9]+$/ || $5>32) exit 1}' || { fail 'NETNS 地址必须为 IPv4 CIDR。'; return 1; }
    done
    case "$WG_CONF" in /*) ;; *) fail 'WG_CONF 必须为绝对路径。'; return 1 ;; esac
    [ "$(basename "$WG_CONF")" = "${WG_INTERFACE}.conf" ] || { fail 'WG_CONF 文件名必须与 WG_INTERFACE 一致。'; return 1; }
    for CFWARP_PATH in "$WG_CONF" "$CFWARP_STATE_DIR" "$CFWARP_GLOBAL_STATE_DIR"; do
        case "$CFWARP_PATH" in *'
'*) fail '配置路径不能包含换行。'; return 1 ;; esac
    done
    # Explicit namespace DNS avoids host-only private resolvers becoming
    # unreachable after wg-quick routes the namespace through WARP.
    [ -n "$NETNS_DNS_SERVERS" ] || { fail 'NETNS_DNS_SERVERS 不能为空。'; return 1; }
    for CFWARP_DNS in $NETNS_DNS_SERVERS; do
        case "$CFWARP_DNS" in ''|*[!0-9A-Fa-f.:]*) fail 'NETNS_DNS_SERVERS 仅支持 IP 地址。'; return 1 ;; esac
    done
}

iptables_cmd() {
    if [ "$IPTABLES_WAIT_SECONDS" -gt 0 ]; then
        iptables -w "$IPTABLES_WAIT_SECONDS" "$@"
    else
        iptables "$@"
    fi
}

delete_rule_all() {
    CFWARP_RULE_TABLE=$1
    CFWARP_RULE_CHAIN=$2
    shift 2
    while :; do
        if iptables_cmd -t "$CFWARP_RULE_TABLE" -C "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1; then
            iptables_cmd -t "$CFWARP_RULE_TABLE" -D "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1 || return 1
        else
            CFWARP_RULE_STATUS=$?
            [ "$CFWARP_RULE_STATUS" -eq 1 ] && return 0
            fail "无法读取 iptables 规则 (exit $CFWARP_RULE_STATUS)，保留清理状态。"
            return 1
        fi
    done
}

add_rule_if_missing() {
    CFWARP_RULE_TABLE=$1
    CFWARP_RULE_CHAIN=$2
    shift 2
    if iptables_cmd -t "$CFWARP_RULE_TABLE" -C "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1; then
        return 0
    else
        CFWARP_RULE_STATUS=$?
        [ "$CFWARP_RULE_STATUS" -eq 1 ] || { fail "无法读取 iptables 规则 (exit $CFWARP_RULE_STATUS)。"; return 1; }
        iptables_cmd -t "$CFWARP_RULE_TABLE" -A "$CFWARP_RULE_CHAIN" "$@"
    fi
}

check_signal() {
    [ "$CFWARP_SIGNAL_STATUS" -eq 0 ] || exit "$CFWARP_SIGNAL_STATUS"
}

request_signal() {
    CFWARP_SIGNAL_STATUS=$1
    # Finish the current ownership/refcount update before the EXIT rollback.
    if [ "$CFWARP_SETUP_ACTIVE" -eq 0 ] && [ "$CFWARP_FORWARD_LOCKED" -eq 0 ]; then
        exit "$CFWARP_SIGNAL_STATUS"
    fi
}

lock_ip_forward_state() {
    [ "$CFWARP_FORWARD_LOCKED" -eq 0 ] || return 0
    exec 9> "$IP_FORWARD_LOCK_FILE"
    flock -w "$CFWARP_LOCK_WAIT_SECONDS" 9 || fail '等待 ip_forward 状态锁超时。'
    CFWARP_FORWARD_LOCKED=1
}

unlock_ip_forward_state() {
    flock -u 9
    exec 9>&-
    CFWARP_FORWARD_LOCKED=0
}

read_ref_count() {
    CFWARP_REF_COUNT=$(cat "$IP_FORWARD_REF_FILE" 2>/dev/null || printf '0\n')
    cfwarp_validate_uint "$CFWARP_REF_COUNT" ip_forward.refs 0 2147483646
}

acquire_ip_forward_ref() {
    lock_ip_forward_state
    read_ref_count
    if [ "$CFWARP_REF_COUNT" -eq 0 ]; then
        CFWARP_CURRENT_FORWARD=$(sysctl -n net.ipv4.ip_forward)
        case "$CFWARP_CURRENT_FORWARD" in 0|1) ;; *) fail '无法读取 ip_forward。' ;; esac
        printf '%s\n' "$CFWARP_CURRENT_FORWARD" | cfwarp_atomic_write_from_stdin "$IP_FORWARD_PREV_FILE"
    fi
    CFWARP_REF_COUNT=$((CFWARP_REF_COUNT + 1))
    printf '%s\n' "$CFWARP_REF_COUNT" | cfwarp_atomic_write_from_stdin "$IP_FORWARD_REF_FILE"
    IP_FORWARD_REF_HELD=1
    # Kernel mutation and reference bookkeeping share the same kernel lock.
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    write_state_file
    unlock_ip_forward_state
    check_signal
}

release_ip_forward_ref() {
    [ "$IP_FORWARD_REF_HELD" -eq 1 ] || return 0
    lock_ip_forward_state || return 1
    read_ref_count || return 1
    [ "$CFWARP_REF_COUNT" -gt 0 ] || { fail 'ip_forward 引用状态缺失，保留资源状态供重试。'; return 1; }
    CFWARP_REF_COUNT=$((CFWARP_REF_COUNT - 1))
    if [ "$CFWARP_REF_COUNT" -eq 0 ]; then
        CFWARP_PREVIOUS_FORWARD=$(cat "$IP_FORWARD_PREV_FILE" 2>/dev/null || true)
        case "$CFWARP_PREVIOUS_FORWARD" in 0|1) ;; *) fail 'ip_forward 原始状态缺失。'; return 1 ;; esac
        sysctl -w "net.ipv4.ip_forward=${CFWARP_PREVIOUS_FORWARD}" >/dev/null || return 1
        rm -f "$IP_FORWARD_REF_FILE" "$IP_FORWARD_PREV_FILE" || return 1
    else
        printf '%s\n' "$CFWARP_REF_COUNT" | cfwarp_atomic_write_from_stdin "$IP_FORWARD_REF_FILE" || return 1
    fi
    IP_FORWARD_REF_HELD=0
    write_state_file || return 1
    unlock_ip_forward_state
}

write_state_file() {
    # This is data, never sourced as shell code. Newlines were rejected above.
    cfwarp_atomic_write_from_stdin "$STATE_FILE" <<EOF_STATE
VERSION=2
NETNS_NAME=$NETNS_NAME
NETNS_HOST_IF=$NETNS_HOST_IF
NETNS_NS_IF=$NETNS_NS_IF
NETNS_CIDR=$NETNS_CIDR
NETNS_OUT_IF=$NETNS_OUT_IF
WG_INTERFACE=$WG_INTERFACE
WG_CONF=$WG_CONF
NS_INODE=$CFWARP_NS_INODE
HOST_INDEX=$CFWARP_HOST_INDEX
DNS_CREATED=$CFWARP_DNS_CREATED
DNS_INODE=$CFWARP_DNS_INODE
RULES_STARTED=$CFWARP_RULES_STARTED
IP_FORWARD_REF_HELD=$IP_FORWARD_REF_HELD
EOF_STATE
}

state_value() {
    awk -v key="$1" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$STATE_FILE"
}

load_state() {
    [ -r "$STATE_FILE" ] || return 1
    [ "$(state_value VERSION)" = 2 ] || {
        fail "旧版本或无效的网络状态: $STATE_FILE；请先用创建它的版本停止服务。"
        return 1
    }
    [ "$(state_value NETNS_NAME)" = "$NETNS_NAME" ] || { fail '状态 namespace 不匹配。'; return 1; }
    NETNS_HOST_IF=$(state_value NETNS_HOST_IF)
    NETNS_NS_IF=$(state_value NETNS_NS_IF)
    NETNS_CIDR=$(state_value NETNS_CIDR)
    NETNS_OUT_IF=$(state_value NETNS_OUT_IF)
    WG_INTERFACE=$(state_value WG_INTERFACE)
    WG_CONF=$(state_value WG_CONF)
    CFWARP_NS_INODE=$(state_value NS_INODE)
    CFWARP_HOST_INDEX=$(state_value HOST_INDEX)
    CFWARP_DNS_CREATED=$(state_value DNS_CREATED)
    CFWARP_DNS_INODE=$(state_value DNS_INODE)
    CFWARP_RULES_STARTED=$(state_value RULES_STARTED)
    IP_FORWARD_REF_HELD=$(state_value IP_FORWARD_REF_HELD)
    validate_config || return 1
    [ -z "$NETNS_OUT_IF" ] || cfwarp_validate_link_name "$NETNS_OUT_IF" NETNS_OUT_IF || return 1
    [ -z "$CFWARP_NS_INODE" ] || cfwarp_validate_uint "$CFWARP_NS_INODE" NS_INODE 1 9223372036854775807 || return 1
    [ -z "$CFWARP_DNS_INODE" ] || cfwarp_validate_uint "$CFWARP_DNS_INODE" DNS_INODE 1 9223372036854775807 || return 1
    [ -z "$CFWARP_HOST_INDEX" ] || cfwarp_validate_uint "$CFWARP_HOST_INDEX" HOST_INDEX 1 2147483647 || return 1
    for CFWARP_FLAG in "$CFWARP_DNS_CREATED" "$CFWARP_RULES_STARTED" "$IP_FORWARD_REF_HELD"; do
        case "$CFWARP_FLAG" in 0|1) ;; *) fail '无效的资源所有权状态。'; return 1 ;; esac
    done
}

namespace_inode() { stat -Lc '%i' "/run/netns/$NETNS_NAME" 2>/dev/null || true; }
link_index() { ip -o link show dev "$NETNS_HOST_IF" 2>/dev/null | awk -F: 'NR==1 {gsub(/ /,"",$1); print $1}'; }
namespace_exists() { ip netns list | awk -v name="$NETNS_NAME" '$1==name {found=1} END {exit !found}'; }

write_netns_resolv_conf() {
    {
        for CFWARP_DNS in $NETNS_DNS_SERVERS; do
            printf 'nameserver %s\n' "$CFWARP_DNS"
        done
    } | cfwarp_atomic_write_from_stdin "${RESOLV_DIR}/resolv.conf"
    chmod 0644 "${RESOLV_DIR}/resolv.conf"
}

teardown() {
    # Without ownership state, even familiar-looking resource names are foreign.
    if [ "$CFWARP_SETUP_ACTIVE" -eq 0 ]; then
        [ -e "$STATE_FILE" ] || return 0
        load_state || return 1
    fi
    CFWARP_TEARDOWN_FAILED=0
    CFWARP_LIVE_INODE=$(namespace_inode)
    CFWARP_LIVE_INDEX=$(link_index)
    if [ -n "$CFWARP_LIVE_INODE" ] && [ "$CFWARP_LIVE_INODE" != "$CFWARP_NS_INODE" ]; then
        fail 'namespace 所有权已改变，拒绝删除。'; return 1
    fi
    if [ -n "$CFWARP_LIVE_INDEX" ] && [ "$CFWARP_LIVE_INDEX" != "$CFWARP_HOST_INDEX" ]; then
        fail 'veth 所有权已改变，拒绝删除。'; return 1
    fi
    if [ "$CFWARP_DNS_CREATED" -eq 1 ] && [ -e "$RESOLV_DIR" ]; then
        CFWARP_LIVE_DNS_INODE=$(stat -c '%i' "$RESOLV_DIR")
        if [ "$CFWARP_LIVE_DNS_INODE" != "$CFWARP_DNS_INODE" ] || [ -L "$RESOLV_DIR" ]; then
            fail 'DNS 目录所有权已改变，拒绝删除。'; return 1
        fi
    fi
    if [ -n "$CFWARP_LIVE_INODE" ]; then
        ip netns exec "$NETNS_NAME" "$WG_QUICK_BIN" down "$WG_CONF" >/dev/null 2>&1 || true
    fi
    if [ "$CFWARP_RULES_STARTED" -eq 1 ]; then
        delete_rule_all nat POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -m comment --comment "CFwarp-${NETNS_NAME}-NAT" -j MASQUERADE || CFWARP_TEARDOWN_FAILED=1
        delete_rule_all filter FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -m comment --comment "CFwarp-${NETNS_NAME}-FORWARD" -j ACCEPT || CFWARP_TEARDOWN_FAILED=1
        delete_rule_all filter FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m comment --comment "CFwarp-${NETNS_NAME}-RETURN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || CFWARP_TEARDOWN_FAILED=1
        [ "$CFWARP_TEARDOWN_FAILED" -ne 0 ] || CFWARP_RULES_STARTED=0
    fi
    if [ -n "$CFWARP_LIVE_INDEX" ]; then
        ip link del "$NETNS_HOST_IF" >/dev/null 2>&1 || CFWARP_TEARDOWN_FAILED=1
    fi
    if [ -n "$CFWARP_LIVE_INODE" ]; then
        ip netns del "$NETNS_NAME" >/dev/null 2>&1 || CFWARP_TEARDOWN_FAILED=1
    fi
    if [ "$CFWARP_DNS_CREATED" -eq 1 ]; then
        rm -f "${RESOLV_DIR}/resolv.conf" || CFWARP_TEARDOWN_FAILED=1
        if [ -d "$RESOLV_DIR" ]; then
            rmdir "$RESOLV_DIR" 2>/dev/null || CFWARP_TEARDOWN_FAILED=1
        fi
        [ -d "$RESOLV_DIR" ] || CFWARP_DNS_CREATED=0
    fi
    # Keep refs until all routing resources have actually gone away.
    if [ "$CFWARP_TEARDOWN_FAILED" -eq 0 ]; then
        release_ip_forward_ref || CFWARP_TEARDOWN_FAILED=1
    fi
    if [ "$CFWARP_TEARDOWN_FAILED" -eq 0 ]; then
        rm -f "$STATE_FILE"
    else
        write_state_file || true
        fail "网络清理未完成，状态保留在 $STATE_FILE。"
        return 1
    fi
}

setup() {
    # Run recovery in a subshell so old state cannot overwrite new settings.
    if [ -e "$STATE_FILE" ]; then
        (teardown) || return 1
    fi
    if namespace_exists || ip link show dev "$NETNS_HOST_IF" >/dev/null 2>&1 || \
       ip link show dev "$NETNS_NS_IF" >/dev/null 2>&1 || [ -e "$RESOLV_DIR" ] || [ -L "$RESOLV_DIR" ]; then
        fail 'namespace、veth 或 DNS 目录已存在且不属于本次启动，拒绝覆盖。'
        return 1
    fi
    if [ -z "$NETNS_OUT_IF" ]; then
        NETNS_OUT_IF=$(ip -4 route show default | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    fi
    cfwarp_validate_link_name "$NETNS_OUT_IF" NETNS_OUT_IF
    CFWARP_SETUP_ACTIVE=1
    ip netns add "$NETNS_NAME"
    CFWARP_NS_INODE=$(namespace_inode)
    [ -n "$CFWARP_NS_INODE" ] || fail '无法记录 namespace 所有权。'
    write_state_file
    check_signal
    mkdir "$RESOLV_DIR"
    CFWARP_DNS_CREATED=1
    CFWARP_DNS_INODE=$(stat -c '%i' "$RESOLV_DIR")
    write_state_file
    write_netns_resolv_conf
    check_signal
    ip link add "$NETNS_HOST_IF" type veth peer name "$NETNS_NS_IF"
    CFWARP_HOST_INDEX=$(link_index)
    [ -n "$CFWARP_HOST_INDEX" ] || fail '无法记录 veth 所有权。'
    write_state_file
    check_signal
    ip addr replace "$NETNS_HOST_ADDR" dev "$NETNS_HOST_IF"
    ip link set "$NETNS_HOST_IF" up
    ip link set "$NETNS_NS_IF" netns "$NETNS_NAME"
    ip netns exec "$NETNS_NAME" ip link set lo up
    ip netns exec "$NETNS_NAME" ip addr replace "$NETNS_PEER_ADDR" dev "$NETNS_NS_IF"
    ip netns exec "$NETNS_NAME" ip link set "$NETNS_NS_IF" up
    ip netns exec "$NETNS_NAME" ip route replace default via "${NETNS_HOST_ADDR%/*}" dev "$NETNS_NS_IF"
    check_signal
    acquire_ip_forward_ref
    CFWARP_RULES_STARTED=1
    write_state_file
    add_rule_if_missing nat POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -m comment --comment "CFwarp-${NETNS_NAME}-NAT" -j MASQUERADE
    add_rule_if_missing filter FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -m comment --comment "CFwarp-${NETNS_NAME}-FORWARD" -j ACCEPT
    add_rule_if_missing filter FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m comment --comment "CFwarp-${NETNS_NAME}-RETURN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    check_signal
}

cleanup_exit() {
    CFWARP_EXIT_STATUS=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$CFWARP_SETUP_ACTIVE" -eq 1 ]; then
        teardown || CFWARP_EXIT_STATUS=1
    fi
    exit "$CFWARP_EXIT_STATUS"
}

case "$ACTION" in up|down) ;; *) echo "用法: $0 {up|down}" >&2; exit 1 ;; esac
case "$CFWARP_MODE" in host-global) exit 0 ;; netns-proxy) ;; *) fail "不支持的 CFWARP_MODE: $CFWARP_MODE"; exit 1 ;; esac
validate_config
[ "$(id -u)" -eq 0 ] || { fail 'cfwarp-netns.sh 需要 root 权限。'; exit 1; }
for CFWARP_COMMAND in ip iptables sysctl flock; do
    command -v "$CFWARP_COMMAND" >/dev/null 2>&1 || { fail "缺少命令: $CFWARP_COMMAND"; exit 1; }
done
install -d -m 0700 "$CFWARP_STATE_DIR" "$CFWARP_GLOBAL_STATE_DIR"
install -d -m 0755 /etc/netns
# flock files deliberately remain on disk: deleting them would allow two
# processes to lock different inodes. The kernel releases locks on process exit.
exec 8> "${CFWARP_GLOBAL_STATE_DIR}/netns-${NETNS_NAME}.flock"
flock -w "$CFWARP_LOCK_WAIT_SECONDS" 8 || { fail '等待 namespace 操作锁超时。'; exit 1; }
trap cleanup_exit EXIT
trap 'request_signal 129' HUP
trap 'request_signal 130' INT
trap 'request_signal 143' TERM
case "$ACTION" in
    up) setup; check_signal ;;
    down) teardown; check_signal ;;
esac
trap - EXIT HUP INT TERM
