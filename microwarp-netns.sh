#!/bin/sh
set -eu

ACTION=${1:-}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

MICROWARP_MODE=${MICROWARP_MODE:-"netns-proxy"}
NETNS_NAME=${NETNS_NAME:-"microwarp"}
NETNS_HOST_IF=${NETNS_HOST_IF:-"microwarp-host"}
NETNS_NS_IF=${NETNS_NS_IF:-"microwarp-ns"}
NETNS_HOST_ADDR=${NETNS_HOST_ADDR:-"169.254.240.1/30"}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-"169.254.240.2/30"}
NETNS_CIDR=${NETNS_CIDR:-"169.254.240.0/30"}
NETNS_OUT_IF=${NETNS_OUT_IF:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}
MICROWARP_STATE_DIR=${MICROWARP_STATE_DIR:-"/run/microwarp"}
STATE_FILE="${MICROWARP_STATE_DIR}/${NETNS_NAME}.env"
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}

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
    rm -f "$STATE_FILE"
}

setup() {
    if [ "$MICROWARP_MODE" = "host-global" ]; then
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

    mkdir -p "$MICROWARP_STATE_DIR"

    ip netns add "$NETNS_NAME"
    ip link add "$NETNS_HOST_IF" type veth peer name "$NETNS_NS_IF"
    ip addr add "$NETNS_HOST_ADDR" dev "$NETNS_HOST_IF"
    ip link set "$NETNS_HOST_IF" up
    ip link set "$NETNS_NS_IF" netns "$NETNS_NAME"

    ip netns exec "$NETNS_NAME" ip link set lo up
    ip netns exec "$NETNS_NAME" ip addr add "$NETNS_PEER_ADDR" dev "$NETNS_NS_IF"
    ip netns exec "$NETNS_NAME" ip link set "$NETNS_NS_IF" up
    ip netns exec "$NETNS_NAME" ip route replace default via "$HOST_IP" dev "$NETNS_NS_IF"

    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    iptables -t nat -C POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -j MASQUERADE > /dev/null 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$NETNS_CIDR" -o "$NETNS_OUT_IF" -j MASQUERADE
    iptables -C FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -j ACCEPT > /dev/null 2>&1 || \
        iptables -A FORWARD -i "$NETNS_HOST_IF" -o "$NETNS_OUT_IF" -j ACCEPT
    iptables -C FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT > /dev/null 2>&1 || \
        iptables -A FORWARD -i "$NETNS_OUT_IF" -o "$NETNS_HOST_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    cat > "$STATE_FILE" <<EOF
OUT_IF='$NETNS_OUT_IF'
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
