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
WG_QUICK_BIN=${WG_QUICK_BIN:-${SCRIPT_DIR}/bin/wg-quick}

case "$CFWARP_MODE" in
    host-global)
        "$WG_QUICK_BIN" down "$WG_INTERFACE" >/dev/null 2>&1 || true
        ;;
    netns-proxy)
        sh "${SCRIPT_DIR}/cfwarp-netns.sh" down
        ;;
    *)
        echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2
        exit 1
        ;;
esac
