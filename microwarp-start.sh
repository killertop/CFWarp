#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

MICROWARP_MODE=${MICROWARP_MODE:-"netns-proxy"}
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
MICROWARP_DATA_DIR=${MICROWARP_DATA_DIR:-"/var/lib/microwarp"}
WG_CONF_DIR=${WG_CONF_DIR:-"${MICROWARP_DATA_DIR}"}
WG_CONF=${WG_CONF:-"${WG_CONF_DIR}/${WG_INTERFACE}.conf"}
WGCF_PROFILE=${WGCF_PROFILE:-"${MICROWARP_DATA_DIR}/wgcf-profile.conf"}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-"${MICROWARP_DATA_DIR}/wgcf-account.toml"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}

export WG_INTERFACE MICROWARP_DATA_DIR WG_CONF_DIR WG_CONF WGCF_PROFILE WGCF_ACCOUNT WG_QUICK_BIN

case "$MICROWARP_MODE" in
    host-global)
        "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
        exec sh "$SCRIPT_DIR/entrypoint.sh"
        ;;
    netns-proxy)
        "$SCRIPT_DIR/microwarp-netns.sh" up
        NETNS_NAME=${NETNS_NAME:-"microwarp"}
        NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-"169.254.240.2/30"}
        PROXY_CONNECT_HOST=${NETNS_PEER_HOST:-$(printf '%s\n' "$NETNS_PEER_ADDR" | cut -d/ -f1)}
        exec ip netns exec "$NETNS_NAME" env \
            WG_INTERFACE="$WG_INTERFACE" \
            MICROWARP_DATA_DIR="$MICROWARP_DATA_DIR" \
            WG_CONF_DIR="$WG_CONF_DIR" \
            WG_CONF="$WG_CONF" \
            WGCF_PROFILE="$WGCF_PROFILE" \
            WGCF_ACCOUNT="$WGCF_ACCOUNT" \
            WG_QUICK_BIN="$WG_QUICK_BIN" \
            GH_PROXY="${GH_PROXY:-}" \
            ENDPOINT_IP="${ENDPOINT_IP:-}" \
            ENDPOINT_CANDIDATES="${ENDPOINT_CANDIDATES:-}" \
            WARP_READY_ATTEMPTS="${WARP_READY_ATTEMPTS:-}" \
            WARP_READY_DELAY_SECONDS="${WARP_READY_DELAY_SECONDS:-}" \
            WARP_HEALTHCHECK_CONNECT_TIMEOUT="${WARP_HEALTHCHECK_CONNECT_TIMEOUT:-}" \
            WARP_HEALTHCHECK_TOTAL_TIMEOUT="${WARP_HEALTHCHECK_TOTAL_TIMEOUT:-}" \
            WARP_HEALTHCHECK_TRACE_URL="${WARP_HEALTHCHECK_TRACE_URL:-}" \
            WARP_HEALTHCHECK_TEST_URL="${WARP_HEALTHCHECK_TEST_URL:-}" \
            TAILSCALE_CIDR="${TAILSCALE_CIDR:-}" \
            BIND_ADDR="${BIND_ADDR:-}" \
            BIND_PORT="${BIND_PORT:-}" \
            SOCKS_USER="${SOCKS_USER:-}" \
            SOCKS_PASS="${SOCKS_PASS:-}" \
            MICROWARP_TEST_MODE="${MICROWARP_TEST_MODE:-0}" \
            PROXY_CONNECT_HOST="$PROXY_CONNECT_HOST" \
            sh "$SCRIPT_DIR/entrypoint.sh"
        ;;
    *)
        echo "==> [ERROR] 不支持的 MICROWARP_MODE: $MICROWARP_MODE" >&2
        exit 1
        ;;
esac
