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
cfwarp_load_env "$SCRIPT_DIR"

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
WG_INTERFACE=${WG_INTERFACE:-wg0}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${SCRIPT_DIR}/var}
WG_CONF_DIR=${WG_CONF_DIR:-$CFWARP_DATA_DIR}
WG_CONF=${WG_CONF:-${WG_CONF_DIR}/${WG_INTERFACE}.conf}
WGCF_PROFILE=${WGCF_PROFILE:-${CFWARP_DATA_DIR}/wgcf-profile.conf}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-${CFWARP_DATA_DIR}/wgcf-account.toml}
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}
cfwarp_validate_link_name "$WG_INTERFACE" WG_INTERFACE
case "$WG_CONF" in
    /*) ;;
    *) echo '==> [ERROR] WG_CONF 必须为绝对路径。' >&2; exit 1 ;;
esac
[ "$(basename "$WG_CONF")" = "${WG_INTERFACE}.conf" ] || {
    echo '==> [ERROR] WG_CONF 文件名必须与 WG_INTERFACE 一致。' >&2
    exit 1
}
CFWARP_TEST_MODE=${CFWARP_TEST_MODE:-0}

if [ "$CFWARP_TEST_MODE" = "1" ]; then
    exec sh "${SCRIPT_DIR}/entrypoint.sh"
fi

case "$CFWARP_MODE" in
    host-global|netns-proxy) ;;
    *) echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2; exit 1 ;;
esac

if [ "$CFWARP_MODE" = "host-global" ]; then
    # Entrypoint holds the host interface lock and verifies ownership before
    # replacing a tunnel. Never pre-delete an interface by its name here.
    exec sh "${SCRIPT_DIR}/entrypoint.sh"
fi

NETNS_NAME=${NETNS_NAME:-cfwarp}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-169.254.240.2/30}
PROXY_CONNECT_HOST=${NETNS_PEER_HOST:-$(printf '%s\n' "$NETNS_PEER_ADDR" | cut -d/ -f1)}
export PROXY_CONNECT_HOST

command -v setsid >/dev/null 2>&1 || {
    echo '==> [ERROR] 缺少 setsid 命令 (util-linux)。' >&2
    exit 1
}
CFWARP_CHILD_PID=
CFWARP_PREPARED_DIR=$(mktemp -d)
CFWARP_PREPARED_ENDPOINTS_FILE="${CFWARP_PREPARED_DIR}/endpoints"
CFWARP_NETWORK_STARTED=0
cleanup_netns() {
    CFWARP_EXIT_STATUS=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ -n "$CFWARP_CHILD_PID" ]; then
        kill -TERM "$CFWARP_CHILD_PID" 2>/dev/null || true
        CFWARP_CHILD_WAIT=0
        while kill -0 "$CFWARP_CHILD_PID" 2>/dev/null && [ "$CFWARP_CHILD_WAIT" -lt 100 ]; do
            sleep 0.1
            CFWARP_CHILD_WAIT=$((CFWARP_CHILD_WAIT + 1))
        done
        # Every phase has an isolated group; remove any descendant left after
        # graceful shutdown, including a command that ignores TERM.
        kill -KILL "-$CFWARP_CHILD_PID" 2>/dev/null || true
        wait "$CFWARP_CHILD_PID" 2>/dev/null || true
        CFWARP_CHILD_PID=
    fi
    if [ "$CFWARP_NETWORK_STARTED" = 1 ]; then
        if ! sh "${SCRIPT_DIR}/cfwarp-netns.sh" down; then
            CFWARP_EXIT_STATUS=1
        fi
    fi
    rm -rf "$CFWARP_PREPARED_DIR"
    exit "$CFWARP_EXIT_STATUS"
}
# Install supervision before setup: a stop during setup must wait for its
# rollback before attempting another namespace operation.
trap cleanup_netns EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Bootstrap uses the host network, before any application namespace exists.
# Supervise it too so a stop cancels downloads and resolver descendants.
setsid env CFWARP_PREPARE_ONLY=1 CFWARP_PREPARED_ENDPOINTS_FILE="$CFWARP_PREPARED_ENDPOINTS_FILE" \
    sh "${SCRIPT_DIR}/entrypoint.sh" &
CFWARP_CHILD_PID=$!
wait "$CFWARP_CHILD_PID"
CFWARP_CHILD_PID=
CFWARP_NETWORK_STARTED=1
setsid sh "${SCRIPT_DIR}/cfwarp-netns.sh" up &
CFWARP_CHILD_PID=$!
wait "$CFWARP_CHILD_PID"
CFWARP_CHILD_PID=

setsid ip netns exec "$NETNS_NAME" env \
    CFWARP_MODE="$CFWARP_MODE" \
    PROXY_CONNECT_HOST="$PROXY_CONNECT_HOST" \
    WG_INTERFACE="$WG_INTERFACE" \
    CFWARP_DATA_DIR="$CFWARP_DATA_DIR" \
    WG_CONF_DIR="$WG_CONF_DIR" \
    WG_CONF="$WG_CONF" \
    WGCF_PROFILE="$WGCF_PROFILE" \
    WGCF_ACCOUNT="$WGCF_ACCOUNT" \
    WG_QUICK_BIN="$WG_QUICK_BIN" \
    CFWARP_PREPARE_ONLY=0 CFWARP_PREPARED_ENDPOINTS_FILE="$CFWARP_PREPARED_ENDPOINTS_FILE" \
    sh "${SCRIPT_DIR}/entrypoint.sh" &
CFWARP_CHILD_PID=$!
wait "$CFWARP_CHILD_PID"
CFWARP_CHILD_PID=
