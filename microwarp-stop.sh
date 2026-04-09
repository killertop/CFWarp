#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

MICROWARP_MODE=${MICROWARP_MODE:-"netns-proxy"}
WG_INTERFACE=${WG_INTERFACE:-"wg0"}
MICROWARP_DATA_DIR=${MICROWARP_DATA_DIR:-"/var/lib/microwarp"}
WG_CONF_DIR=${WG_CONF_DIR:-"${MICROWARP_DATA_DIR}"}
WG_CONF=${WG_CONF:-"${WG_CONF_DIR}/${WG_INTERFACE}.conf"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"${SCRIPT_DIR}/bin/wg-quick"}

case "$MICROWARP_MODE" in
    host-global)
        "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
        ;;
    netns-proxy)
        "$SCRIPT_DIR/microwarp-netns.sh" down
        ;;
    *)
        echo "==> [ERROR] 不支持的 MICROWARP_MODE: $MICROWARP_MODE" >&2
        exit 1
        ;;
esac
