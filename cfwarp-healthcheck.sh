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

CFWARP_ENV_FILE=$(cfwarp_default_env_file "$SCRIPT_DIR")
WAIT_MODE=0
OUTPUT_FORMAT=text
CLI_METRICS_FILE=

while [ $# -gt 0 ]; do
    case "$1" in
        --wait)
            WAIT_MODE=1
            shift
            ;;
        --format|--env)
            if [ "$1" = "--env" ]; then
                OUTPUT_FORMAT=env
                shift
                continue
            fi
            if [ "$#" -lt 2 ]; then
                echo "==> [ERROR] --format 需要参数 text 或 env。" >&2
                exit 1
            fi
            OUTPUT_FORMAT=$2
            case "$OUTPUT_FORMAT" in
                text|env) ;;
                *) echo "==> [ERROR] --format 仅支持 text 或 env。" >&2; exit 1 ;;
            esac
            shift 2
            ;;
        --metrics-file)
            if [ "$#" -lt 2 ]; then
                echo "==> [ERROR] --metrics-file 需要路径参数。" >&2
                exit 1
            fi
            CLI_METRICS_FILE=${2:-}
            [ -n "$CLI_METRICS_FILE" ] || { echo "==> [ERROR] --metrics-file 需要路径参数。" >&2; exit 1; }
            shift 2
            ;;
        -h|--help)
            cat <<EOF
用法: $0 [--wait] [--format text|env] [--metrics-file PATH]

检查 CFwarp SOCKS5 是否能通过 WARP 访问 Cloudflare trace。
EOF
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

if [ -r "$CFWARP_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$CFWARP_ENV_FILE"
    set +a
elif [ -f "$CFWARP_ENV_FILE" ]; then
    echo "==> [CFwarp] 环境文件不可读，将使用默认代理参数: $CFWARP_ENV_FILE" >&2
fi

CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
NETNS_NAME=${NETNS_NAME:-cfwarp}
NETNS_PEER_ADDR=${NETNS_PEER_ADDR:-169.254.240.2/30}
NETNS_PEER_HOST=${NETNS_PEER_HOST:-$(printf '%s\n' "$NETNS_PEER_ADDR" | cut -d/ -f1)}
BIND_ADDR=${BIND_ADDR:-}
BIND_PORT=${BIND_PORT:-1080}
SOCKS_USER=${SOCKS_USER:-}
SOCKS_PASS=${SOCKS_PASS:-}
CFWARP_HEALTH_TRACE_URL=${CFWARP_HEALTH_TRACE_URL:-${WARP_HEALTHCHECK_TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}}
CFWARP_HEALTH_CONNECT_TIMEOUT=${CFWARP_HEALTH_CONNECT_TIMEOUT:-4}
CFWARP_HEALTH_TOTAL_TIMEOUT=${CFWARP_HEALTH_TOTAL_TIMEOUT:-8}
CFWARP_HEALTH_WAIT_SECONDS=${CFWARP_HEALTH_WAIT_SECONDS:-90}
CFWARP_HEALTH_INTERVAL_SECONDS=${CFWARP_HEALTH_INTERVAL_SECONDS:-2}
CFWARP_HEALTH_RETRIES=${CFWARP_HEALTH_RETRIES:-2}
CFWARP_HEALTH_RETRY_DELAY_SECONDS=${CFWARP_HEALTH_RETRY_DELAY_SECONDS:-1}
CFWARP_HEALTH_WARN_TOTAL_SECONDS=${CFWARP_HEALTH_WARN_TOTAL_SECONDS:-2}
METRICS_FILE=${CLI_METRICS_FILE:-${CFWARP_HEALTH_METRICS_FILE:-}}

cfwarp_validate_uint "$CFWARP_HEALTH_CONNECT_TIMEOUT" CFWARP_HEALTH_CONNECT_TIMEOUT 1 300 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_TOTAL_TIMEOUT" CFWARP_HEALTH_TOTAL_TIMEOUT 1 900 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_WAIT_SECONDS" CFWARP_HEALTH_WAIT_SECONDS 1 86400 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_INTERVAL_SECONDS" CFWARP_HEALTH_INTERVAL_SECONDS 1 3600 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_RETRIES" CFWARP_HEALTH_RETRIES 1 100 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_RETRY_DELAY_SECONDS" CFWARP_HEALTH_RETRY_DELAY_SECONDS 0 3600 || exit 1
cfwarp_validate_uint "$CFWARP_HEALTH_WARN_TOTAL_SECONDS" CFWARP_HEALTH_WARN_TOTAL_SECONDS 0 900 || exit 1
cfwarp_validate_port "$BIND_PORT" BIND_PORT || exit 1
if { [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; } || { [ -z "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; }; then
    echo "==> [ERROR] SOCKS_USER 和 SOCKS_PASS 必须同时设置，或同时留空。" >&2
    exit 1
fi

case "$CFWARP_MODE" in
    netns-proxy|host-global) ;;
    *) echo "==> [ERROR] 不支持的 CFWARP_MODE: $CFWARP_MODE" >&2; exit 1 ;;
esac
if [ "$CFWARP_MODE" = "netns-proxy" ] && ! command -v ip >/dev/null 2>&1; then
    echo "==> [ERROR] 缺少 ip 命令，无法检查 network namespace。" >&2
    exit 1
fi

TMP_BODY=$(mktemp)
TMP_TIME=$(mktemp)
cleanup() {
    rm -f "$TMP_BODY" "$TMP_TIME"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

proxy_connect_host() {
    case "$CFWARP_MODE" in
        netns-proxy) printf '%s\n' "$NETNS_PEER_HOST" ;;
        host-global)
            case "$BIND_ADDR" in
                ''|0.0.0.0|::|\[::\]) printf '%s\n' 127.0.0.1 ;;
                *) printf '%s\n' "$BIND_ADDR" ;;
            esac
            ;;
    esac
}

write_metrics_file() {
    [ -n "$METRICS_FILE" ] || return 0
    CFWARP_METRICS_DIR=$(dirname "$METRICS_FILE")
    mkdir -p "$CFWARP_METRICS_DIR" || return 1
    CFWARP_METRICS_TMP=$(mktemp "${METRICS_FILE}.tmp.XXXXXX") || return 1
    if ! cat > "$CFWARP_METRICS_TMP"; then
        rm -f "$CFWARP_METRICS_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_METRICS_TMP"
    mv "$CFWARP_METRICS_TMP" "$METRICS_FILE"
}

write_failure_metrics() {
    CFWARP_REASON=$1
    CFWARP_HOST=${2:-unknown}
    {
        printf 'CFWARP_HEALTH_OK=0\n'
        printf 'CFWARP_HEALTH_REASON=%s\n' "$CFWARP_REASON"
        printf 'CFWARP_PROXY_HOST=%s\n' "$CFWARP_HOST"
        printf 'CFWARP_PROXY_PORT=%s\n' "$BIND_PORT"
        printf 'CFWARP_EXIT_IP=unknown\nCFWARP_COLO=unknown\nCFWARP_WARP=unknown\n'
        printf 'CFWARP_TOTAL_MS=0\nCFWARP_TIME_TOTAL=0\nCFWARP_WARN_SLOW=0\n'
    } | write_metrics_file || true
}

check_once() {
    PROXY_HOST=$(proxy_connect_host)
    if [ "$CFWARP_MODE" = "netns-proxy" ] && ! ip netns list 2>/dev/null | awk '{print $1}' | grep -Fx "$NETNS_NAME" >/dev/null 2>&1; then
        echo "==> [ERROR] network namespace 不存在: $NETNS_NAME" >&2
        write_failure_metrics netns_missing "$PROXY_HOST"
        return 1
    fi
    PROXY_URL=$(cfwarp_format_socks_proxy_url "$PROXY_HOST" "$BIND_PORT")
    CFWARP_ATTEMPT=1
    CFWARP_CURL_OK=0
    while [ "$CFWARP_ATTEMPT" -le "$CFWARP_HEALTH_RETRIES" ]; do
        if [ -n "$SOCKS_USER" ]; then
            if curl -4 -fsS --noproxy '' -o "$TMP_BODY" -w '%{time_total}' \
                --connect-timeout "$CFWARP_HEALTH_CONNECT_TIMEOUT" \
                --max-time "$CFWARP_HEALTH_TOTAL_TIMEOUT" \
                --proxy "$PROXY_URL" --proxy-user "$SOCKS_USER:$SOCKS_PASS" \
                "$CFWARP_HEALTH_TRACE_URL" > "$TMP_TIME" 2>/dev/null; then
                CFWARP_CURL_OK=1
                break
            fi
        elif curl -4 -fsS --noproxy '' -o "$TMP_BODY" -w '%{time_total}' \
            --connect-timeout "$CFWARP_HEALTH_CONNECT_TIMEOUT" \
            --max-time "$CFWARP_HEALTH_TOTAL_TIMEOUT" \
            --proxy "$PROXY_URL" "$CFWARP_HEALTH_TRACE_URL" > "$TMP_TIME" 2>/dev/null; then
            CFWARP_CURL_OK=1
            break
        fi
        CFWARP_ATTEMPT=$((CFWARP_ATTEMPT + 1))
        [ "$CFWARP_ATTEMPT" -le "$CFWARP_HEALTH_RETRIES" ] && sleep "$CFWARP_HEALTH_RETRY_DELAY_SECONDS"
    done
    if [ "$CFWARP_CURL_OK" != "1" ]; then
        echo "==> [ERROR] SOCKS5 健康检查失败: ${PROXY_HOST}:${BIND_PORT}" >&2
        write_failure_metrics curl_failed "$PROXY_HOST"
        return 1
    fi

    TRACE_OUTPUT=$(cat "$TMP_BODY")
    TIME_TOTAL=$(cat "$TMP_TIME")
    if ! printf '%s\n' "$TRACE_OUTPUT" | awk -F= '$1 == "warp" && ($2 == "on" || $2 == "plus") { found = 1 } END { exit found ? 0 : 1 }'; then
        echo "==> [ERROR] SOCKS5 可连接，但 WARP trace 未显示有效出口。" >&2
        write_failure_metrics warp_inactive "$PROXY_HOST"
        return 1
    fi

    EXIT_IP=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n 's/^ip=//p' | head -n 1)
    COLO=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n 's/^colo=//p' | head -n 1)
    WARP_STATE=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n 's/^warp=//p' | head -n 1)
    TOTAL_MS=$(awk -v total="${TIME_TOTAL:-0}" 'BEGIN { printf "%d", total * 1000 }')
    WARN_SLOW=0
    if awk -v total="${TIME_TOTAL:-0}" -v warn="$CFWARP_HEALTH_WARN_TOTAL_SECONDS" 'BEGIN { exit total > warn ? 0 : 1 }'; then
        WARN_SLOW=1
    fi
    METRICS_OUTPUT=$(cat <<EOF
CFWARP_HEALTH_OK=1
CFWARP_HEALTH_REASON=ok
CFWARP_PROXY_HOST=${PROXY_HOST}
CFWARP_PROXY_PORT=${BIND_PORT}
CFWARP_EXIT_IP=${EXIT_IP:-unknown}
CFWARP_COLO=${COLO:-unknown}
CFWARP_WARP=${WARP_STATE:-unknown}
CFWARP_TOTAL_MS=${TOTAL_MS}
CFWARP_TIME_TOTAL=${TIME_TOTAL:-0}
CFWARP_WARN_SLOW=${WARN_SLOW}
EOF
)
    if [ "$OUTPUT_FORMAT" = "env" ]; then
        printf '%s\n' "$METRICS_OUTPUT"
    else
        echo "==> [CFwarp] 健康检查通过: exit_ip=${EXIT_IP:-unknown} colo=${COLO:-unknown} warp=${WARP_STATE:-unknown} total_ms=${TOTAL_MS}"
    fi
    printf '%s\n' "$METRICS_OUTPUT" | write_metrics_file || true
    if [ "$WARN_SLOW" = "1" ]; then
        echo "==> [CFwarp] 警告：健康检查耗时偏高 (${TIME_TOTAL}s > ${CFWARP_HEALTH_WARN_TOTAL_SECONDS}s)。" >&2
    fi
}

if [ "$WAIT_MODE" = "0" ]; then
    check_once
    exit $?
fi

STARTED_AT=$(date +%s)
while :; do
    if check_once; then
        exit 0
    fi
    NOW=$(date +%s)
    if [ $((NOW - STARTED_AT)) -ge "$CFWARP_HEALTH_WAIT_SECONDS" ]; then
        echo "==> [ERROR] CFwarp 在 ${CFWARP_HEALTH_WAIT_SECONDS}s 内未通过健康检查。" >&2
        exit 1
    fi
    sleep "$CFWARP_HEALTH_INTERVAL_SECONDS"
done
