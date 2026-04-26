#!/bin/sh
set -eu

ACTION=${1:-}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

CFWARP_MODE=${CFWARP_MODE:-${MICROWARP_MODE:-"netns-proxy"}}
NETNS_NAME=${NETNS_NAME:-"cfwarp"}
NETNS_HOST_IF=${NETNS_HOST_IF:-"cfwarp-host"}
NETNS_NS_IF=${NETNS_NS_IF:-"cfwarp-ns"}
NETNS_HOST_ADDR=${NETNS_HOST_ADDR:-"169.254.240.1/30"}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-"169.254.240.2/30"}
NETNS_CIDR=${NETNS_CIDR:-"169.254.240.0/30"}
NETNS_OUT_IF=${NETNS_OUT_IF:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}
CFWARP_STATE_DIR=${CFWARP_STATE_DIR:-${MICROWARP_STATE_DIR:-"/run/cfwarp"}}
CFWARP_GLOBAL_STATE_DIR=${CFWARP_GLOBAL_STATE_DIR:-${MICROWARP_GLOBAL_STATE_DIR:-"/run/cfwarp"}}
STATE_FILE="${CFWARP_STATE_DIR}/${NETNS_NAME}.env"
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}
IP_FORWARD_PREV_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.prev"
IP_FORWARD_REF_FILE="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.refs"
IP_FORWARD_LOCK_DIR="${CFWARP_GLOBAL_STATE_DIR}/ip_forward.lock"

strip_cidr() {
    printf '%s\n' "$1" | cut -d/ -f1
}

validate_link_name() {
    NAME=$1
    LABEL=$2
    if [ -z "$NAME" ]; then
        echo "==> [ERROR] ${LABEL} 不能为空。" >&2
        exit 1
    fi
    if [ "${#NAME}" -gt 15 ]; then
        echo "==> [ERROR] ${LABEL} 不能超过 15 个字符: ${NAME}" >&2
        exit 1
    fi
}

rule_delete_if_present() {
    TABLE=$1
    shift
    if iptables -t "$TABLE" -C "$@" > /dev/null 2>&1; then
        iptables -t "$TABLE" -D "$@"
    fi
}

lock_ip_forward_state() {
    install -d "$CFWARP_GLOBAL_STATE_DIR"
    while ! mkdir "$IP_FORWARD_LOCK_DIR" 2>/dev/null; do
        sleep 0.05
    done
}

unlock_ip_forward_state() {
    rmdir "$IP_FORWARD_LOCK_DIR" > /dev/null 2>&1 || true
}

acquire_ip_forward_ref() {
    lock_ip_forward_state
    CURRENT_VALUE=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf '0\n')
    REF_COUNT=$(cat "$IP_FORWARD_REF_FILE" 2>/dev/null || printf '0\n')
    case "$REF_COUNT" in
        ''|*[!0-9]*)
            REF_COUNT=0
            ;;
    esac
    if [ "$REF_COUNT" -eq 0 ]; then
        printf '%s\n' "$CURRENT_VALUE" > "$IP_FORWARD_PREV_FILE"
    fi
    REF_COUNT=$((REF_COUNT + 1))
    printf '%s\n' "$REF_COUNT" > "$IP_FORWARD_REF_FILE"
    unlock_ip_forward_state
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
}

release_ip_forward_ref() {
    if [ "${IP_FORWARD_REF_HELD:-0}" != "1" ]; then
        return 0
    fi

    lock_ip_forward_state
    REF_COUNT=$(cat "$IP_FORWARD_REF_FILE" 2>/dev/null || printf '0\n')
    case "$REF_COUNT" in
        ''|*[!0-9]*)
            REF_COUNT=0
            ;;
    esac
    if [ "$REF_COUNT" -gt 0 ]; then
        REF_COUNT=$((REF_COUNT - 1))
    fi

    if [ "$REF_COUNT" -eq 0 ]; then
        PREV_VALUE=$(cat "$IP_FORWARD_PREV_FILE" 2>/dev/null || true)
        rm -f "$IP_FORWARD_REF_FILE" "$IP_FORWARD_PREV_FILE"
        unlock_ip_forward_state
        if [ -n "$PREV_VALUE" ]; then
            sysctl -w "net.ipv4.ip_forward=${PREV_VALUE}" > /dev/null || true
        fi
        return 0
    fi

    printf '%s\n' "$REF_COUNT" > "$IP_FORWARD_REF_FILE"
    unlock_ip_forward_state
}

teardown() {
    OUT_IF=${NETNS_OUT_IF:-}
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi

    if ip netns list 2>/dev/null | awk '{print $1}' | grep -Fx "$NETNS_NAME" > /dev/null 2>&1; then
        ip netns exec "$NETNS_NAME" "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
    fi

    if [ -n "$OUT_IF" ]; then
        rule_delete_if_present nat POSTROUTING -s "$NETNS_CIDR" -o "$OUT_IF" -j MASQUERADE
        rule_delete_if_present filter FORWARD -i "$NETNS_HOST_IF" -o "$OUT_IF" -j ACCEPT
        rule_delete_if_present filter FORWARD -i "$OUT_IF" -o "$NETNS_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fi

    ip link del "$NETNS_HOST_IF" > /dev/null 2>&1 || true
    ip netns del "$NETNS_NAME" > /dev/null 2>&1 || true
    release_ip_forward_ref
    rm -f "$STATE_FILE"
}

setup() {
    if [ "$CFWARP_MODE" = "host-global" ]; then
        return 0
    fi

    validate_link_name "$NETNS_HOST_IF" "NETNS_HOST_IF"
    validate_link_name "$NETNS_NS_IF" "NETNS_NS_IF"

    teardown
    trap 'teardown' EXIT HUP INT TERM

    if [ -z "$NETNS_OUT_IF" ]; then
        echo "==> [ERROR] 无法自动检测宿主机默认出口网卡，请设置 NETNS_OUT_IF。" >&2
        exit 1
    fi

    HOST_IP=$(strip_cidr "$NETNS_HOST_ADDR")

    mkdir -p "$CFWARP_STATE_DIR"
    mkdir -p "$CFWARP_GLOBAL_STATE_DIR"

    ip netns add "$NETNS_NAME"
    ip link add "$NETNS_HOST_IF" type veth peer name "$NETNS_NS_IF"
    ip addr add "$NETNS_HOST_ADDR" dev "$NETNS_HOST_IF"
    ip link set "$NETNS_HOST_IF" up
    ip link set "$NETNS_NS_IF" netns "$NETNS_NAME"

    ip netns exec "$NETNS_NAME" ip link set lo up
    ip netns exec "$NETNS_NAME" ip addr add "$NETNS_PEER_ADDR" dev "$NETNS_NS_IF"
    ip netns exec "$NETNS_NAME" ip link set "$NETNS_NS_IF" up
    ip netns exec "$NETNS_NAME" ip route replace default via "$HOST_IP" dev "$NETNS_NS_IF"

    acquire_ip_forward_ref

    iptables -t nat -C POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -j MASQUERADE > /dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -j MASQUERADE
    iptables -C FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -j ACCEPT > /dev/null 2>&1 || \
        iptables -A FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -j ACCEPT
    iptables -C FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT > /dev/null 2>&1 || \
        iptables -A FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    cat > "$STATE_FILE" <<EOF
OUT_IF='$NETNS_OUT_IF'
IP_FORWARD_REF_HELD='1'
EOF

    trap - EXIT HUP INT TERM
}

case "$ACTION" in
    up)
        setup
        ;;
    down)
        teardown
        ;;
    *)
        echo "用法: $0 {up|down}" >&2
        exit 1
        ;;
esac
