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

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
WG_INTERFACE=${WG_INTERFACE:-wg0}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${SCRIPT_DIR}/var}
WG_CONF_DIR=${WG_CONF_DIR:-$CFWARP_DATA_DIR}
WG_CONF=${WG_CONF:-${WG_CONF_DIR}/${WG_INTERFACE}.conf}
WGCF_PROFILE=${WGCF_PROFILE:-${CFWARP_DATA_DIR}/wgcf-profile.conf}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-${CFWARP_DATA_DIR}/wgcf-account.toml}
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}
CFWARP_TEST_MODE=${CFWARP_TEST_MODE:-0}

if [ "$CFWARP_TEST_MODE" = "1" ]; then
    exec sh "${SCRIPT_DIR}/entrypoint.sh"
fi

case "$CFWARP_MODE" in
    host-global|netns-proxy) ;;
    *) echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2; exit 1 ;;
esac

if [ "$CFWARP_MODE" = "host-global" ]; then
    # The host-global mode intentionally leaves routing decisions to the
    # supplied wg-quick config. Stop any old interface before rebuilding it.
    "$WG_QUICK_BIN" down "$WG_INTERFACE" >/dev/null 2>&1 || true
    exec sh "${SCRIPT_DIR}/entrypoint.sh"
fi

NETNS_NAME=${NETNS_NAME:-cfwarp}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-169.254.240.2/30}
PROXY_CONNECT_HOST=${NETNS_PEER_HOST:-$(printf '%s\n' "$NETNS_PEER_ADDR" | cut -d/ -f1)}
export PROXY_CONNECT_HOST

sh "${SCRIPT_DIR}/cfwarp-netns.sh" up
CFWARP_NETNS_CLEANED=0
cleanup_netns() {
    CFWARP_EXIT_STATUS=$?
    if [ "$CFWARP_NETNS_CLEANED" = "0" ]; then
        sh "${SCRIPT_DIR}/cfwarp-netns.sh" down >/dev/null 2>&1 || true
        CFWARP_NETNS_CLEANED=1
    fi
    exit "$CFWARP_EXIT_STATUS"
}
trap 'cleanup_netns' EXIT
trap 'exit 143' HUP INT TERM

# The environment is inherited from systemd/its EnvironmentFile. Only the
# namespace-local helper variable must be added here.
ip netns exec "$NETNS_NAME" env \
    CFWARP_MODE="$CFWARP_MODE" \
    PROXY_CONNECT_HOST="$PROXY_CONNECT_HOST" \
    WG_INTERFACE="$WG_INTERFACE" \
    CFWARP_DATA_DIR="$CFWARP_DATA_DIR" \
    WG_CONF_DIR="$WG_CONF_DIR" \
    WG_CONF="$WG_CONF" \
    WGCF_PROFILE="$WGCF_PROFILE" \
    WGCF_ACCOUNT="$WGCF_ACCOUNT" \
    WG_QUICK_BIN="$WG_QUICK_BIN" \
    sh "${SCRIPT_DIR}/entrypoint.sh"
