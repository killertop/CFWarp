#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
CFWARP_SERVICE_NAME=${CFWARP_SERVICE_NAME:-cfwarp.service}
CFWARP_WATCHDOG_RETRIES=${CFWARP_WATCHDOG_RETRIES:-3}
CFWARP_WATCHDOG_RETRY_DELAY_SECONDS=${CFWARP_WATCHDOG_RETRY_DELAY_SECONDS:-2}
CFWARP_WATCHDOG_FAILURE_THRESHOLD=${CFWARP_WATCHDOG_FAILURE_THRESHOLD:-2}
CFWARP_WATCHDOG_STATE_FILE=${CFWARP_WATCHDOG_STATE_FILE:-/run/cfwarp/watchdog-failure-count}
CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS=${CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS:-900}
CFWARP_WATCHDOG_RESTART_STATE_FILE=${CFWARP_WATCHDOG_RESTART_STATE_FILE:-/run/cfwarp/watchdog-last-restart}

case "$CFWARP_WATCHDOG_RETRIES" in ''|*[!0-9]*) CFWARP_WATCHDOG_RETRIES=3 ;; esac
case "$CFWARP_WATCHDOG_RETRY_DELAY_SECONDS" in ''|*[!0-9]*) CFWARP_WATCHDOG_RETRY_DELAY_SECONDS=2 ;; esac
case "$CFWARP_WATCHDOG_FAILURE_THRESHOLD" in ''|*[!0-9]*) CFWARP_WATCHDOG_FAILURE_THRESHOLD=2 ;; esac
case "$CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS" in ''|*[!0-9]*) CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS=900 ;; esac
[ "$CFWARP_WATCHDOG_RETRIES" -ge 1 ] || CFWARP_WATCHDOG_RETRIES=1
[ "$CFWARP_WATCHDOG_FAILURE_THRESHOLD" -ge 2 ] || CFWARP_WATCHDOG_FAILURE_THRESHOLD=2

TMP_HEALTH=$(mktemp)
cleanup() { rm -f "$TMP_HEALTH"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

reset_failure_count() {
    rm -f "$CFWARP_WATCHDOG_STATE_FILE"
}

read_uint_file() {
    CFWARP_NUMBER=$(tr -d '[:space:]' < "$1" 2>/dev/null || true)
    case "$CFWARP_NUMBER" in
        ''|*[!0-9]*) printf '%s\n' '' ;;
        *) printf '%s\n' "$CFWARP_NUMBER" ;;
    esac
}

record_failure() {
    CFWARP_FAILURE_COUNT=0
    if [ -r "$CFWARP_WATCHDOG_STATE_FILE" ]; then
        CFWARP_FAILURE_COUNT=$(read_uint_file "$CFWARP_WATCHDOG_STATE_FILE")
    fi
    case "$CFWARP_FAILURE_COUNT" in ''|*[!0-9]*) CFWARP_FAILURE_COUNT=0 ;; esac
    CFWARP_FAILURE_COUNT=$((CFWARP_FAILURE_COUNT + 1))
    umask 077
    mkdir -p "$(dirname "$CFWARP_WATCHDOG_STATE_FILE")"
    printf '%s\n' "$CFWARP_FAILURE_COUNT" > "${CFWARP_WATCHDOG_STATE_FILE}.tmp"
    mv "${CFWARP_WATCHDOG_STATE_FILE}.tmp" "$CFWARP_WATCHDOG_STATE_FILE"
    printf '%s\n' "$CFWARP_FAILURE_COUNT"
}

record_restart_time() {
    umask 077
    mkdir -p "$(dirname "$CFWARP_WATCHDOG_RESTART_STATE_FILE")"
    printf '%s\n' "$(date +%s)" > "${CFWARP_WATCHDOG_RESTART_STATE_FILE}.tmp"
    mv "${CFWARP_WATCHDOG_RESTART_STATE_FILE}.tmp" "$CFWARP_WATCHDOG_RESTART_STATE_FILE"
}

restart_is_in_cooldown() {
    [ -r "$CFWARP_WATCHDOG_RESTART_STATE_FILE" ] || return 1
    CFWARP_LAST_RESTART=$(read_uint_file "$CFWARP_WATCHDOG_RESTART_STATE_FILE")
    case "$CFWARP_LAST_RESTART" in ''|*[!0-9]*) return 1 ;; esac
    CFWARP_NOW=$(date +%s)
    [ "$CFWARP_NOW" -lt "$CFWARP_LAST_RESTART" ] && return 0
    [ $((CFWARP_NOW - CFWARP_LAST_RESTART)) -lt "$CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS" ]
}

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "==> [CFwarp] 未检测到运行中的 systemd，跳过健康守护。"
    exit 0
fi

# A manually stopped service is respected. An enabled service in failed state
# may be recovered once, with a cooldown to prevent restart storms.
if ! systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
    if systemctl is-failed --quiet "$CFWARP_SERVICE_NAME" && systemctl is-enabled --quiet "$CFWARP_SERVICE_NAME"; then
        if restart_is_in_cooldown; then
            echo "==> [CFwarp] 服务仍在恢复冷却期，暂不重启。" >&2
            exit 0
        fi
        record_restart_time
        if systemctl start "$CFWARP_SERVICE_NAME"; then
            echo "==> [CFwarp] 已尝试恢复失败的 cfwarp.service。"
        else
            echo "==> [CFwarp] 恢复 cfwarp.service 失败，将等待冷却期后再试。" >&2
            exit 1
        fi
    fi
    reset_failure_count
    exit 0
fi

if CFWARP_HEALTH_RETRIES="$CFWARP_WATCHDOG_RETRIES" \
   CFWARP_HEALTH_RETRY_DELAY_SECONDS="$CFWARP_WATCHDOG_RETRY_DELAY_SECONDS" \
   "$SCRIPT_DIR/cfwarp-healthcheck.sh" --format env > "$TMP_HEALTH" 2>&1; then
    reset_failure_count
    exit 0
fi

CFWARP_FAILURE_COUNT=$(record_failure)
if [ "$CFWARP_FAILURE_COUNT" -lt "$CFWARP_WATCHDOG_FAILURE_THRESHOLD" ]; then
    echo "==> [CFwarp] 健康检查连续失败 ${CFWARP_FAILURE_COUNT}/${CFWARP_WATCHDOG_FAILURE_THRESHOLD}，暂不重启。" >&2
    cat "$TMP_HEALTH" >&2
    exit 0
fi

if restart_is_in_cooldown; then
    echo "==> [CFwarp] 已达到重启阈值，但仍在恢复冷却期，暂不重启。" >&2
    cat "$TMP_HEALTH" >&2
    exit 0
fi

record_restart_time
reset_failure_count
echo "==> [CFwarp] 健康检查连续失败，正在重启 ${CFWARP_SERVICE_NAME}。" >&2
cat "$TMP_HEALTH" >&2
if ! systemctl restart "$CFWARP_SERVICE_NAME"; then
    echo "==> [CFwarp] 重启失败，将等待冷却期后再试。" >&2
    exit 1
fi
if ! "$SCRIPT_DIR/cfwarp-healthcheck.sh" --wait --format env > "$TMP_HEALTH" 2>&1; then
    echo "==> [CFwarp] 重启后健康检查仍失败：" >&2
    cat "$TMP_HEALTH" >&2
    exit 1
fi
echo "==> [CFwarp] 重启后健康检查恢复。"
