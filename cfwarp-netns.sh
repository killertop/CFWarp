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

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
NETNS_NAME=${NETNS_NAME:-cfwarp}
NETNS_HOST_IF=${NETNS_HOST_IF:-cfwarp-host}
NETNS_NS_IF=${NETNS_NS_IF:-cfwarp-ns}
NETNS_HOST_ADDR=${NETNS_HOST_ADDR:-169.254.240.1/30}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-169.254.240.2/30}
NETNS_CIDR=${NETNS_CIDR:-169.254.240.0/30}
NETNS_OUT_IF=${NETNS_OUT_IF:-}
CFWARP_STATE_DIR=${CFWARP_STATE_DIR:-/run/cfwarp}
CFWARP_GLOBAL_STATE_DIR=${CFWARP_GLOBAL_STATE_DIR:-/run/cfwarp}
WG_INTERFACE=${WG_INTERFACE:-wg0}
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}
NAT_CHAIN=${NAT_CHAIN:-CFWARP_NAT}
FWD_CHAIN=${FWD_CHAIN:-CFWARP_FWD}
IPTABLES_WAIT_SECONDS=${IPTABLES_WAIT_SECONDS:-5}
IP_FORWARD_PREV_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.prev"
IP_FORWARD_REF_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.refs"
IP_FORWARD_LOCK_DIR="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.lock"
IP_FORWARD_LOCK_PID_FILE="${IP_FORWARD_LOCK_DIR}/pid"
IP_FORWARD_LOCK_WAIT_ATTEMPTS=${IP_FORWARD_LOCK_WAIT_ATTEMPTS:-100}
STATE_FILE="${CFWARP_STATE_DIR}/${NETNS_NAME}.env"
IP_FORWARD_REF_HELD=${IP_FORWARD_REF_HELD:-0}

usage() {
    echo "用法: $0 {up|down}" >&2
}

if [ "$ACTION" != "up" ] && [ "$ACTION" != "down" ]; then
    usage
    exit 1
fi

if [ "$CFWARP_MODE" = "host-global" ]; then
    exit 0
fi
if [ "$CFWARP_MODE" != "netns-proxy" ]; then
    echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2
    exit 1
fi

validate_config() {
    cfwarp_validate_netns_name "$NETNS_NAME" NETNS_NAME || exit 1
    cfwarp_validate_link_name "$NETNS_HOST_IF" NETNS_HOST_IF || exit 1
    cfwarp_validate_link_name "$NETNS_NS_IF" NETNS_NS_IF || exit 1
    cfwarp_validate_chain_name "$NAT_CHAIN" NAT_CHAIN || exit 1
    cfwarp_validate_chain_name "$FWD_CHAIN" FWD_CHAIN || exit 1
    cfwarp_validate_uint "$IPTABLES_WAIT_SECONDS" IPTABLES_WAIT_SECONDS 0 60 || exit 1
    cfwarp_validate_uint "$IP_FORWARD_LOCK_WAIT_ATTEMPTS" IP_FORWARD_LOCK_WAIT_ATTEMPTS 1 10000 || exit 1
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
    while iptables_cmd -t "$CFWARP_RULE_TABLE" -C "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1; do
        iptables_cmd -t "$CFWARP_RULE_TABLE" -D "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1 || break
    done
}

add_rule_if_missing() {
    CFWARP_RULE_TABLE=$1
    CFWARP_RULE_CHAIN=$2
    shift 2
    if ! iptables_cmd -t "$CFWARP_RULE_TABLE" -C "$CFWARP_RULE_CHAIN" "$@" >/dev/null 2>&1; then
        iptables_cmd -t "$CFWARP_RULE_TABLE" -A "$CFWARP_RULE_CHAIN" "$@"
    fi
}

cleanup_legacy_chain() {
    CFWARP_CHAIN_TABLE=$1
    CFWARP_CHAIN_NAME=$2
    shift 2
    if ! iptables_cmd -t "$CFWARP_CHAIN_TABLE" -L "$CFWARP_CHAIN_NAME" >/dev/null 2>&1; then
        return 0
    fi
    # Remove only the rule shape written by older CFwarp versions. Never flush
    # a chain that may contain rules owned by another application.
    delete_rule_all "$CFWARP_CHAIN_TABLE" "$CFWARP_CHAIN_NAME" "$@"
    if ! iptables_cmd -t "$CFWARP_CHAIN_TABLE" -S "$CFWARP_CHAIN_NAME" 2>/dev/null | \
        awk '$1 == "-A" { found = 1 } END { exit found ? 0 : 1 }'; then
        iptables_cmd -t "$CFWARP_CHAIN_TABLE" -X "$CFWARP_CHAIN_NAME" >/dev/null 2>&1 || true
    fi
}

lock_ip_forward_state() {
    install -d -m 0700 "$CFWARP_GLOBAL_STATE_DIR"
    CFWARP_LOCK_ATTEMPTS=0
    while ! mkdir "$IP_FORWARD_LOCK_DIR" 2>/dev/null; do
        CFWARP_LOCK_PID=$(cat "$IP_FORWARD_LOCK_PID_FILE" 2>/dev/null || true)
        if [ -n "$CFWARP_LOCK_PID" ] && ! kill -0 "$CFWARP_LOCK_PID" 2>/dev/null; then
            rm -f "$IP_FORWARD_LOCK_PID_FILE" >/dev/null 2>&1 || true
            rmdir "$IP_FORWARD_LOCK_DIR" >/dev/null 2>&1 || true
            continue
        fi
        CFWARP_LOCK_ATTEMPTS=$((CFWARP_LOCK_ATTEMPTS + 1))
        if [ "$CFWARP_LOCK_ATTEMPTS" -ge "$IP_FORWARD_LOCK_WAIT_ATTEMPTS" ]; then
            if [ -z "$CFWARP_LOCK_PID" ]; then
                rm -f "$IP_FORWARD_LOCK_PID_FILE" >/dev/null 2>&1 || true
                rmdir "$IP_FORWARD_LOCK_DIR" >/dev/null 2>&1 || true
                CFWARP_LOCK_ATTEMPTS=0
                continue
            fi
            echo "==> [ERROR] 等待 ip_forward 状态锁超时: $IP_FORWARD_LOCK_DIR" >&2
            return 1
        fi
        sleep 0.05
    done
    printf '%s\n' "$$" > "$IP_FORWARD_LOCK_PID_FILE"
}

unlock_ip_forward_state() {
    rm -f "$IP_FORWARD_LOCK_PID_FILE" >/dev/null 2>&1 || true
    rmdir "$IP_FORWARD_LOCK_DIR" >/dev/null 2>&1 || true
}

acquire_ip_forward_ref() {
    lock_ip_forward_state
    CFWARP_CURRENT_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf '0\n')
    CFWARP_REF_COUNT=$(cat "$IP_FORWARD_REF_FILE" 2>/dev/null || printf '0\n')
    case "$CFWARP_REF_COUNT" in
        ''|*[!0-9]*) CFWARP_REF_COUNT=0 ;;
    esac
    if [ "$CFWARP_REF_COUNT" -eq 0 ]; then
        printf '%s\n' "$CFWARP_CURRENT_FORWARD" > "$IP_FORWARD_PREV_FILE"
    fi
    CFWARP_REF_COUNT=$((CFWARP_REF_COUNT + 1))
    printf '%s\n' "$CFWARP_REF_COUNT" > "$IP_FORWARD_REF_FILE"
    unlock_ip_forward_state
    # Rollback is enabled before the kernel change so the EXIT trap can undo a
    # partial setup if sysctl fails.
    IP_FORWARD_REF_HELD=1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

release_ip_forward_ref() {
    if [ "${IP_FORWARD_REF_HELD:-0}" != "1" ]; then
        return 0
    fi

    lock_ip_forward_state
    CFWARP_REF_COUNT=$(cat "$IP_FORWARD_REF_FILE" 2>/dev/null || printf '0\n')
    case "$CFWARP_REF_COUNT" in
        ''|*[!0-9]*) CFWARP_REF_COUNT=0 ;;
    esac
    if [ "$CFWARP_REF_COUNT" -gt 0 ]; then
        CFWARP_REF_COUNT=$((CFWARP_REF_COUNT - 1))
    fi

    if [ "$CFWARP_REF_COUNT" -eq 0 ]; then
        CFWARP_PREVIOUS_FORWARD=$(cat "$IP_FORWARD_PREV_FILE" 2>/dev/null || true)
        rm -f "$IP_FORWARD_REF_FILE" "$IP_FORWARD_PREV_FILE"
        unlock_ip_forward_state
        if [ -n "$CFWARP_PREVIOUS_FORWARD" ]; then
            sysctl -w "net.ipv4.ip_forward=${CFWARP_PREVIOUS_FORWARD}" >/dev/null || true
        fi
    else
        printf '%s\n' "$CFWARP_REF_COUNT" > "$IP_FORWARD_REF_FILE"
        unlock_ip_forward_state
    fi
    IP_FORWARD_REF_HELD=0
}

write_state_file() {
    umask 077
    cfwarp_atomic_write_from_stdin "$STATE_FILE" <<EOF
CFWARP_STATE_NETNS_NAME='${NETNS_NAME}'
CFWARP_STATE_NETNS_HOST_IF='${NETNS_HOST_IF}'
CFWARP_STATE_NETNS_NS_IF='${NETNS_NS_IF}'
CFWARP_STATE_NETNS_CIDR='${NETNS_CIDR}'
CFWARP_STATE_OUT_IF='${NETNS_OUT_IF}'
CFWARP_STATE_WG_INTERFACE='${WG_INTERFACE}'
CFWARP_STATE_NAT_CHAIN='${NAT_CHAIN}'
CFWARP_STATE_FWD_CHAIN='${FWD_CHAIN}'
CFWARP_STATE_IP_FORWARD_REF_HELD='${IP_FORWARD_REF_HELD}'
EOF
}

write_netns_resolv_conf() {
    CFWARP_RESOLV_DIR="/etc/netns/${NETNS_NAME}"
    CFWARP_RESOLV_TMP=$(mktemp "${CFWARP_RESOLV_DIR}/resolv.conf.tmp.XXXXXX")
    CFWARP_HOST_DNS=$(awk '$1 == "nameserver" && $2 !~ /^127\./ && $2 != "::1" {print $2}' /etc/resolv.conf 2>/dev/null || true)
    if [ -n "$CFWARP_HOST_DNS" ]; then
        for CFWARP_DNS in $CFWARP_HOST_DNS; do
            printf 'nameserver %s\n' "$CFWARP_DNS" >> "$CFWARP_RESOLV_TMP"
        done
    else
        printf '%s\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' >> "$CFWARP_RESOLV_TMP"
    fi
    chmod 0644 "$CFWARP_RESOLV_TMP"
    mv "$CFWARP_RESOLV_TMP" "${CFWARP_RESOLV_DIR}/resolv.conf"
}

teardown() {
    CFWARP_TEARDOWN_NAME=$NETNS_NAME
    CFWARP_TEARDOWN_HOST_IF=$NETNS_HOST_IF
    CFWARP_TEARDOWN_CIDR=$NETNS_CIDR
    CFWARP_TEARDOWN_OUT_IF=$NETNS_OUT_IF
    CFWARP_TEARDOWN_WG_INTERFACE=$WG_INTERFACE
    CFWARP_TEARDOWN_NAT_CHAIN=$NAT_CHAIN
    CFWARP_TEARDOWN_FWD_CHAIN=$FWD_CHAIN
    CFWARP_TEARDOWN_REF_HELD=${IP_FORWARD_REF_HELD:-0}

    if [ -r "$STATE_FILE" ]; then
        # The state file is written by CFwarp and contains only prefixed shell
        # assignments. It does not overwrite the desired configuration.
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        CFWARP_TEARDOWN_NAME=${CFWARP_STATE_NETNS_NAME:-$CFWARP_TEARDOWN_NAME}
        CFWARP_TEARDOWN_HOST_IF=${CFWARP_STATE_NETNS_HOST_IF:-$CFWARP_TEARDOWN_HOST_IF}
        CFWARP_TEARDOWN_CIDR=${CFWARP_STATE_NETNS_CIDR:-$CFWARP_TEARDOWN_CIDR}
        CFWARP_TEARDOWN_OUT_IF=${CFWARP_STATE_OUT_IF:-$CFWARP_TEARDOWN_OUT_IF}
        CFWARP_TEARDOWN_WG_INTERFACE=${CFWARP_STATE_WG_INTERFACE:-$CFWARP_TEARDOWN_WG_INTERFACE}
        CFWARP_TEARDOWN_NAT_CHAIN=${CFWARP_STATE_NAT_CHAIN:-$CFWARP_TEARDOWN_NAT_CHAIN}
        CFWARP_TEARDOWN_FWD_CHAIN=${CFWARP_STATE_FWD_CHAIN:-$CFWARP_TEARDOWN_FWD_CHAIN}
        CFWARP_TEARDOWN_REF_HELD=${CFWARP_STATE_IP_FORWARD_REF_HELD:-${IP_FORWARD_REF_HELD:-$CFWARP_TEARDOWN_REF_HELD}}
        # Accept the state names written by the previous release so an
        # upgrade can clean up its namespace and release its forwarding ref.
        CFWARP_TEARDOWN_OUT_IF=${CFWARP_TEARDOWN_OUT_IF:-${OUT_IF:-}}
        CFWARP_TEARDOWN_REF_HELD=${CFWARP_TEARDOWN_REF_HELD:-${IP_FORWARD_REF_HELD:-0}}
    fi

    if ip netns list 2>/dev/null | awk '{print $1}' | grep -Fx "$CFWARP_TEARDOWN_NAME" >/dev/null 2>&1; then
        ip netns exec "$CFWARP_TEARDOWN_NAME" "$WG_QUICK_BIN" down "$CFWARP_TEARDOWN_WG_INTERFACE" >/dev/null 2>&1 || true
    fi

    if [ -n "$CFWARP_TEARDOWN_OUT_IF" ]; then
        # Current rules carry a CFwarp comment. The un-commented forms are
        # removed only for upgrade cleanup and are tied to CFwarp-owned veths.
        delete_rule_all nat POSTROUTING -s "$CFWARP_TEARDOWN_CIDR" -o "$CFWARP_TEARDOWN_OUT_IF" -m comment --comment CFwarp-NAT -j MASQUERADE || true
        delete_rule_all filter FORWARD -i "$CFWARP_TEARDOWN_HOST_IF" -o "$CFWARP_TEARDOWN_OUT_IF" -m comment --comment CFwarp-FORWARD -j ACCEPT || true
        delete_rule_all filter FORWARD -i "$CFWARP_TEARDOWN_OUT_IF" -o "$CFWARP_TEARDOWN_HOST_IF" -m comment --comment CFwarp-RETURN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
        delete_rule_all nat POSTROUTING -s "$CFWARP_TEARDOWN_CIDR" -o "$CFWARP_TEARDOWN_OUT_IF" -j MASQUERADE || true
        delete_rule_all filter FORWARD -i "$CFWARP_TEARDOWN_HOST_IF" -o "$CFWARP_TEARDOWN_OUT_IF" -j ACCEPT || true
        delete_rule_all filter FORWARD -i "$CFWARP_TEARDOWN_OUT_IF" -o "$CFWARP_TEARDOWN_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
    fi

    # Remove jumps left by the short-lived custom-chain implementation, but
    # never flush a chain that may contain third-party rules.
    delete_rule_all nat POSTROUTING -j "$CFWARP_TEARDOWN_NAT_CHAIN" || true
    delete_rule_all filter FORWARD -j "$CFWARP_TEARDOWN_FWD_CHAIN" || true
    cleanup_legacy_chain nat "$CFWARP_TEARDOWN_NAT_CHAIN" -s "$CFWARP_TEARDOWN_CIDR" -o "$CFWARP_TEARDOWN_OUT_IF" -j MASQUERADE || true
    cleanup_legacy_chain filter "$CFWARP_TEARDOWN_FWD_CHAIN" -i "$CFWARP_TEARDOWN_HOST_IF" -o "$CFWARP_TEARDOWN_OUT_IF" -j ACCEPT || true

    ip link del "$CFWARP_TEARDOWN_HOST_IF" >/dev/null 2>&1 || true
    ip netns del "$CFWARP_TEARDOWN_NAME" >/dev/null 2>&1 || true
    if cfwarp_validate_netns_name "$CFWARP_TEARDOWN_NAME" NETNS_NAME >/dev/null 2>&1; then
        rm -f "/etc/netns/${CFWARP_TEARDOWN_NAME}/resolv.conf" >/dev/null 2>&1 || true
        rmdir "/etc/netns/${CFWARP_TEARDOWN_NAME}" >/dev/null 2>&1 || true
    fi

    IP_FORWARD_REF_HELD=$CFWARP_TEARDOWN_REF_HELD
    release_ip_forward_ref || true
    rm -f "$STATE_FILE" >/dev/null 2>&1 || true
}

setup() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "==> [ERROR] cfwarp-netns.sh 需要 root 权限。" >&2
        exit 1
    fi
    if ! command -v ip >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1 || ! command -v sysctl >/dev/null 2>&1; then
        echo "==> [ERROR] 缺少 ip、iptables 或 sysctl 命令。" >&2
        exit 1
    fi
    validate_config

    CFWARP_DESIRED_NETNS_NAME=$NETNS_NAME
    CFWARP_DESIRED_HOST_IF=$NETNS_HOST_IF
    CFWARP_DESIRED_CIDR=$NETNS_CIDR
    CFWARP_DESIRED_OUT_IF=$NETNS_OUT_IF
    CFWARP_DESIRED_WG_INTERFACE=$WG_INTERFACE
    CFWARP_DESIRED_NAT_CHAIN=$NAT_CHAIN
    CFWARP_DESIRED_FWD_CHAIN=$FWD_CHAIN
    teardown
    NETNS_NAME=$CFWARP_DESIRED_NETNS_NAME
    NETNS_HOST_IF=$CFWARP_DESIRED_HOST_IF
    NETNS_CIDR=$CFWARP_DESIRED_CIDR
    NETNS_OUT_IF=$CFWARP_DESIRED_OUT_IF
    WG_INTERFACE=$CFWARP_DESIRED_WG_INTERFACE
    NAT_CHAIN=$CFWARP_DESIRED_NAT_CHAIN
    FWD_CHAIN=$CFWARP_DESIRED_FWD_CHAIN
    STATE_FILE="${CFWARP_STATE_DIR}/${NETNS_NAME}.env"

    if [ -z "$NETNS_OUT_IF" ]; then
        NETNS_OUT_IF=$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    fi
    if [ -z "$NETNS_OUT_IF" ]; then
        echo "==> [ERROR] 无法检测默认出口网卡，请设置 NETNS_OUT_IF。" >&2
        exit 1
    fi

    HOST_IP=$(printf '%s\n' "$NETNS_HOST_ADDR" | cut -d/ -f1)
    install -d -m 0700 "$CFWARP_STATE_DIR" "$CFWARP_GLOBAL_STATE_DIR"
    ip netns add "$NETNS_NAME"
    install -d -m 0755 "/etc/netns/${NETNS_NAME}"
    write_netns_resolv_conf

    ip link add "$NETNS_HOST_IF" type veth peer name "$NETNS_NS_IF"
    ip addr replace "$NETNS_HOST_ADDR" dev "$NETNS_HOST_IF"
    ip link set "$NETNS_HOST_IF" up
    ip link set "$NETNS_NS_IF" netns "$NETNS_NAME"
    ip netns exec "$NETNS_NAME" ip link set lo up
    ip netns exec "$NETNS_NAME" ip addr replace "$NETNS_PEER_ADDR" dev "$NETNS_NS_IF"
    ip netns exec "$NETNS_NAME" ip link set "$NETNS_NS_IF" up
    ip netns exec "$NETNS_NAME" ip route replace default via "$HOST_IP" dev "$NETNS_NS_IF"

    acquire_ip_forward_ref
    write_state_file
    add_rule_if_missing nat POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -m comment --comment CFwarp-NAT -j MASQUERADE
    add_rule_if_missing filter FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -m comment --comment CFwarp-FORWARD -j ACCEPT
    add_rule_if_missing filter FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m comment --comment CFwarp-RETURN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    write_state_file
}

case "$ACTION" in
    up)
        trap 'teardown; exit 143' HUP INT TERM
        trap 'teardown' EXIT
        setup
        trap - EXIT HUP INT TERM
        ;;
    down)
        validate_config
        teardown
        ;;
esac
