#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

CFWARP_MODE=${CFWARP_MODE:-${MICROWARP_MODE:-"netns-proxy"}}
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${MICROWARP_DATA_DIR:-"${SCRIPT_DIR}/var"}}
WG_CONF_DIR=${WG_CONF_DIR:-"${CFWARP_DATA_DIR}"}
WG_CONF=${WG_CONF:-"${WG_CONF_DIR}/${WG_INTERFACE}.conf"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}

case "$CFWARP_MODE" in
    host-global)
        "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
        ;;
    netns-proxy)
        sh "$SCRIPT_DIR/cfwarp-netns.sh" down
        ;;
    *)
        echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2
        exit 1
        ;;
esac
