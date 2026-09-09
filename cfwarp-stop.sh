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

case "$CFWARP_MODE" in
    host-global)
        cfwarp_host_guard_cleanup
        ;;
    netns-proxy)
        sh "${SCRIPT_DIR}/cfwarp-netns.sh" down
        ;;
    *)
        echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2
        exit 1
        ;;
esac
