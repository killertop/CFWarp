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

WG_INTERFACE=${WG_INTERFACE:-wg0}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${SCRIPT_DIR}/var}
WG_CONF_DIR=${WG_CONF_DIR:-$CFWARP_DATA_DIR}
WG_CONF=${WG_CONF:-${WG_CONF_DIR}/${WG_INTERFACE}.conf}
WGCF_PROFILE=${WGCF_PROFILE:-${CFWARP_DATA_DIR}/wgcf-profile.conf}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-${CFWARP_DATA_DIR}/wgcf-account.toml}
WG_QUICK_BIN=${WG_QUICK_BIN:-wg-quick}
WGCF_DEFAULT_VERSION=${WGCF_DEFAULT_VERSION:-2.2.30}
WGCF_VERSION=${WGCF_VERSION:-$WGCF_DEFAULT_VERSION}
WGCF_SHA256=${WGCF_SHA256:-}
CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD=${CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD:-0}
WARP_MTU=${WARP_MTU:-1280}
WARP_PERSISTENT_KEEPALIVE=${WARP_PERSISTENT_KEEPALIVE:-15}
WARP_READY_ATTEMPTS=${WARP_READY_ATTEMPTS:-6}
WARP_READY_DELAY_SECONDS=${WARP_READY_DELAY_SECONDS:-2}
WARP_HEALTHCHECK_CONNECT_TIMEOUT=${WARP_HEALTHCHECK_CONNECT_TIMEOUT:-4}
WARP_HEALTHCHECK_TOTAL_TIMEOUT=${WARP_HEALTHCHECK_TOTAL_TIMEOUT:-8}
WARP_HEALTHCHECK_TRACE_URL=${WARP_HEALTHCHECK_TRACE_URL:-https://1.1.1.1/cdn-cgi/trace}
WARP_HEALTHCHECK_TEST_URL=${WARP_HEALTHCHECK_TEST_URL:-https://www.gstatic.com/generate_204}
LEGACY_SYSTEM_WG_CONF=${LEGACY_SYSTEM_WG_CONF:-/etc/wireguard/${WG_INTERFACE}.conf}
CFWARP_TEST_MODE=${CFWARP_TEST_MODE:-0}
CFWARP_PROBE_MODE=${CFWARP_PROBE_MODE:-0}
CFWARP_PROBE_URL=${CFWARP_PROBE_URL:-$WARP_HEALTHCHECK_TRACE_URL}
CFWARP_PROBE_SAMPLES=${CFWARP_PROBE_SAMPLES:-2}
CFWARP_PROBE_METRICS_FILE=${CFWARP_PROBE_METRICS_FILE:-}
ENDPOINT_IP=${ENDPOINT_IP:-}
ENDPOINT_CANDIDATES=${ENDPOINT_CANDIDATES:-}
SOCKS_USER=${SOCKS_USER:-}
SOCKS_PASS=${SOCKS_PASS:-}

# This mode is intentionally dependency-free so CI and package checks can
# validate the entry point without touching the host network.
if [ "$CFWARP_TEST_MODE" = "1" ]; then
    exit 0
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "==> [ERROR] 缺少依赖命令: $1" >&2
        exit 1
    fi
}

require_command awk
require_command curl
require_command ip
require_command wg
require_command mktemp

umask 077

cfwarp_validate_uint "$WARP_MTU" WARP_MTU 576 9000 || exit 1
cfwarp_validate_uint "$WARP_PERSISTENT_KEEPALIVE" WARP_PERSISTENT_KEEPALIVE 0 65535 || exit 1
cfwarp_validate_uint "$WARP_READY_ATTEMPTS" WARP_READY_ATTEMPTS 1 100 || exit 1
cfwarp_validate_uint "$WARP_READY_DELAY_SECONDS" WARP_READY_DELAY_SECONDS 0 3600 || exit 1
cfwarp_validate_uint "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" WARP_HEALTHCHECK_CONNECT_TIMEOUT 1 300 || exit 1
cfwarp_validate_uint "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" WARP_HEALTHCHECK_TOTAL_TIMEOUT 1 900 || exit 1
cfwarp_validate_uint "$CFWARP_PROBE_SAMPLES" CFWARP_PROBE_SAMPLES 1 100 || exit 1
case "$CFWARP_PROBE_MODE" in
    0|1) ;;
    *) echo "==> [ERROR] CFWARP_PROBE_MODE 仅支持 0 或 1。" >&2; exit 1 ;;
esac
case "$CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD" in
    0|1) ;;
    *) echo "==> [ERROR] CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD 仅支持 0 或 1。" >&2; exit 1 ;;
esac

if [ ! -x "$WG_QUICK_BIN" ]; then
    WG_QUICK_BIN=$(command -v "$WG_QUICK_BIN" 2>/dev/null || true)
fi
if [ -z "$WG_QUICK_BIN" ] || [ ! -x "$WG_QUICK_BIN" ]; then
    echo "==> [ERROR] 找不到可执行的 wg-quick，请检查 WG_QUICK_BIN。" >&2
    exit 1
fi

build_wgcf_download_url() {
    CFWARP_WGCF_VERSION=$1
    CFWARP_WGCF_ARCH=$2
    CFWARP_WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${CFWARP_WGCF_VERSION}/wgcf_${CFWARP_WGCF_VERSION}_linux_${CFWARP_WGCF_ARCH}"
    if [ -n "${GH_PROXY:-}" ]; then
        printf '%s/%s\n' "${GH_PROXY%/}" "$CFWARP_WGCF_URL"
    else
        printf '%s\n' "$CFWARP_WGCF_URL"
    fi
}

resolve_default_wgcf_sha256() {
    case "$1:$2" in
        2.2.30:amd64) printf '%s\n' fc443008fe29a6f0b05b45d27436b7ce89e87a6836718597ccb39e41da418304 ;;
        2.2.30:arm64) printf '%s\n' 761f1d35157feb7c527cd8b13fbe428b47a9786af207a73e380630609c3d1f40 ;;
        *) printf '%s\n' '' ;;
    esac
}

validate_wgcf_version() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.)
            echo "==> [ERROR] WGCF_VERSION 必须是固定的数字版本，例如 2.2.30；不支持 latest。" >&2
            return 1
            ;;
    esac
}

validate_sha256() {
    printf '%s\n' "${1:-}" | awk 'length($0) == 64 && $0 ~ /^[0-9A-Fa-f]+$/ { exit 0 } { exit 1 }'
}

sync_wg_conf_from_profile() {
    [ -f "$WGCF_PROFILE" ] || return 1
    CFWARP_CONFIG_TMP=$(mktemp "${WG_CONF}.tmp.XXXXXX")
    if ! cp "$WGCF_PROFILE" "$CFWARP_CONFIG_TMP"; then
        rm -f "$CFWARP_CONFIG_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_CONFIG_TMP"
    mv "$CFWARP_CONFIG_TMP" "$WG_CONF"
}

migrate_legacy_wg_conf() {
    if [ -f "$WG_CONF" ] || [ "$WG_CONF" = "$LEGACY_SYSTEM_WG_CONF" ] || [ ! -f "$LEGACY_SYSTEM_WG_CONF" ]; then
        return 0
    fi
    echo "==> [CFwarp] 检测到旧版 WireGuard 配置，正在迁移到持久化目录。"
    CFWARP_CONFIG_TMP=$(mktemp "${WG_CONF}.tmp.XXXXXX")
    if ! cp "$LEGACY_SYSTEM_WG_CONF" "$CFWARP_CONFIG_TMP"; then
        rm -f "$CFWARP_CONFIG_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_CONFIG_TMP"
    mv "$CFWARP_CONFIG_TMP" "$WG_CONF"
}

initialize_wgcf() {
    case "$(uname -m)" in
        x86_64) CFWARP_WGCF_ARCH=amd64 ;;
        aarch64) CFWARP_WGCF_ARCH=arm64 ;;
        *) echo "==> [ERROR] 不支持的架构: $(uname -m)" >&2; return 1 ;;
    esac
    validate_wgcf_version "$WGCF_VERSION" || return 1
    EFFECTIVE_WGCF_SHA256=${WGCF_SHA256:-}
    if [ -z "$EFFECTIVE_WGCF_SHA256" ]; then
        EFFECTIVE_WGCF_SHA256=$(resolve_default_wgcf_sha256 "$WGCF_VERSION" "$CFWARP_WGCF_ARCH")
    fi
    if [ -n "$EFFECTIVE_WGCF_SHA256" ] && ! validate_sha256 "$EFFECTIVE_WGCF_SHA256"; then
        echo "==> [ERROR] WGCF_SHA256 必须是 64 位十六进制字符串。" >&2
        return 1
    fi
    if [ -z "$EFFECTIVE_WGCF_SHA256" ] && [ "$CFWARP_ALLOW_INSECURE_WGCF_DOWNLOAD" != "1" ]; then
        echo "==> [ERROR] 当前 wgcf 版本/架构没有内置 SHA256，请设置 WGCF_SHA256；不建议关闭校验。" >&2
        return 1
    fi
    require_command sha256sum
    require_command git

    CFWARP_WGCF_TMP=$(mktemp -d)
    cleanup_wgcf_tmp() { rm -rf "$CFWARP_WGCF_TMP"; }
    trap 'cleanup_wgcf_tmp' EXIT HUP INT TERM
    echo "==> [CFwarp] 正在下载并校验固定版本 wgcf。"
    curl -fL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 90 \
        -o "${CFWARP_WGCF_TMP}/wgcf" "$(build_wgcf_download_url "$WGCF_VERSION" "$CFWARP_WGCF_ARCH")"
    if [ -n "$EFFECTIVE_WGCF_SHA256" ]; then
        printf '%s  %s\n' "$EFFECTIVE_WGCF_SHA256" "${CFWARP_WGCF_TMP}/wgcf" | sha256sum -c -
    fi
    chmod 0700 "${CFWARP_WGCF_TMP}/wgcf"
    (
        cd "$CFWARP_WGCF_TMP"
        ./wgcf register --accept-tos >/dev/null
        ./wgcf generate >/dev/null
    )
    [ -f "${CFWARP_WGCF_TMP}/wgcf-profile.conf" ] || { echo "==> [ERROR] wgcf 未生成 profile。" >&2; return 1; }
    [ -f "${CFWARP_WGCF_TMP}/wgcf-account.toml" ] || { echo "==> [ERROR] wgcf 未生成 account。" >&2; return 1; }
    install -m 0600 "${CFWARP_WGCF_TMP}/wgcf-profile.conf" "$WGCF_PROFILE"
    install -m 0600 "${CFWARP_WGCF_TMP}/wgcf-account.toml" "$WGCF_ACCOUNT"
    sync_wg_conf_from_profile
    trap - EXIT HUP INT TERM
    cleanup_wgcf_tmp
}

prepare_wireguard_config() {
    CFWARP_IPV4_ADDR=$(awk '/^[[:space:]]*Address[[:space:]]*=/{match($0, /([0-9]+\.){3}[0-9]+\/[0-9]+/); if (RSTART) {print substr($0, RSTART, RLENGTH); exit}}' "$WG_CONF" 2>/dev/null || true)
    CFWARP_IPV4_ADDR=${CFWARP_IPV4_ADDR:-172.16.0.2/32}
    CFWARP_CONFIG_TMP=$(mktemp "${WG_CONF}.tmp.XXXXXX")
    if ! awk -v address="$CFWARP_IPV4_ADDR" -v mtu="$WARP_MTU" -v keepalive="$WARP_PERSISTENT_KEEPALIVE" '
        /^\[Interface\][[:space:]]*$/ {
            print
            print "Address = " address
            print "MTU = " mtu
            in_interface = 1
            in_peer = 0
            interface_seen = 1
            next
        }
        /^\[Peer\][[:space:]]*$/ {
            print
            print "AllowedIPs = 0.0.0.0/0"
            print "PersistentKeepalive = " keepalive
            in_interface = 0
            in_peer = 1
            peer_seen = 1
            next
        }
        /^\[/ { in_interface = 0; in_peer = 0 }
        in_interface && /^[[:space:]]*(Address|DNS|MTU)[[:space:]]*=/ { next }
        in_peer && /^[[:space:]]*(AllowedIPs|PersistentKeepalive)[[:space:]]*=/ { next }
        { print }
        END { if (!interface_seen || !peer_seen) exit 1 }
    ' "$WG_CONF" > "$CFWARP_CONFIG_TMP"; then
        rm -f "$CFWARP_CONFIG_TMP"
        echo "==> [ERROR] WireGuard 配置缺少 [Interface] 或 [Peer] 段。" >&2
        return 1
    fi
    chmod 0600 "$CFWARP_CONFIG_TMP"
    mv "$CFWARP_CONFIG_TMP" "$WG_CONF"
}

write_endpoint_to_config() {
    CFWARP_NEW_ENDPOINT=$1
    CFWARP_CONFIG_TMP=$(mktemp "${WG_CONF}.tmp.XXXXXX")
    if ! awk -v endpoint="$CFWARP_NEW_ENDPOINT" '
        /^\[Peer\][[:space:]]*$/ {
            if (in_peer && !peer_endpoint_seen) print "Endpoint = " endpoint
            print
            in_peer = 1
            peer_endpoint_seen = 0
            peer_seen = 1
            next
        }
        /^\[/ {
            if (in_peer && !peer_endpoint_seen) print "Endpoint = " endpoint
            in_peer = 0
        }
        in_peer && /^[[:space:]]*Endpoint[[:space:]]*=/ {
            if (!peer_endpoint_seen) print "Endpoint = " endpoint
            peer_endpoint_seen = 1
            next
        }
        { print }
        END {
            if (in_peer && !peer_endpoint_seen) print "Endpoint = " endpoint
            if (!peer_seen) exit 1
        }
    ' "$WG_CONF" > "$CFWARP_CONFIG_TMP"; then
        rm -f "$CFWARP_CONFIG_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_CONFIG_TMP"
    mv "$CFWARP_CONFIG_TMP" "$WG_CONF"
}

current_runtime_endpoint() {
    wg show "$WG_INTERFACE" endpoints 2>/dev/null | awk 'NF >= 2 {print $2; exit}'
}

config_endpoint() {
    awk '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_CONF" 2>/dev/null || true
}

peer_public_key() {
    wg show "$WG_INTERFACE" peers 2>/dev/null | head -n 1
}

has_latest_handshake() {
    wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk 'NF >= 2 && $2 + 0 > 0 { found = 1 } END { exit found ? 0 : 1 }'
}

fetch_trace() {
    curl -4 -fsS --noproxy '*' \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        "$WARP_HEALTHCHECK_TRACE_URL" 2>/dev/null || true
}

trace_warp_active() {
    printf '%s\n' "$1" | awk -F= '$1 == "warp" && ($2 == "on" || $2 == "plus") { found = 1 } END { exit found ? 0 : 1 }'
}

test_warp_http() {
    curl -4 -fsS --noproxy '*' -o /dev/null \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        "$WARP_HEALTHCHECK_TEST_URL" >/dev/null 2>&1
}

probe_http_total() {
    curl -4 -fsS --noproxy '*' -o /dev/null \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        -w '%{time_total}\n' "$CFWARP_PROBE_URL" 2>/dev/null
}

measure_probe_http_average() {
    CFWARP_SAMPLE_INDEX=1
    CFWARP_SAMPLE_OUTPUT=
    while [ "$CFWARP_SAMPLE_INDEX" -le "$CFWARP_PROBE_SAMPLES" ]; do
        CFWARP_SAMPLE_VALUE=$(probe_http_total) || return 1
        CFWARP_SAMPLE_OUTPUT="${CFWARP_SAMPLE_OUTPUT}${CFWARP_SAMPLE_VALUE}
"
        CFWARP_SAMPLE_INDEX=$((CFWARP_SAMPLE_INDEX + 1))
    done
    printf '%s' "$CFWARP_SAMPLE_OUTPUT" | awk 'NF { sum += $1; count += 1 } END { if (count == 0) exit 1; printf "%.6f\n", sum / count }'
}

wait_for_warp_ready() {
    CFWARP_READY_ATTEMPT=1
    while [ "$CFWARP_READY_ATTEMPT" -le "$WARP_READY_ATTEMPTS" ]; do
        CFWARP_TRACE_OUTPUT=$(fetch_trace)
        if has_latest_handshake && trace_warp_active "$CFWARP_TRACE_OUTPUT" && test_warp_http; then
            printf '%s\n' "$CFWARP_TRACE_OUTPUT"
            return 0
        fi
        if [ "$CFWARP_READY_ATTEMPT" -lt "$WARP_READY_ATTEMPTS" ]; then
            sleep "$WARP_READY_DELAY_SECONDS"
        fi
        CFWARP_READY_ATTEMPT=$((CFWARP_READY_ATTEMPT + 1))
    done
    return 1
}

set_runtime_endpoint() {
    CFWARP_NEW_ENDPOINT=$1
    CFWARP_PEER_KEY=$2
    CFWARP_OLD_ENDPOINT=$(current_runtime_endpoint || true)
    [ -n "$CFWARP_NEW_ENDPOINT" ] || return 1
    [ -n "$CFWARP_PEER_KEY" ] || return 1
    cfwarp_validate_endpoint "$CFWARP_NEW_ENDPOINT" || return 1
    wg set "$WG_INTERFACE" peer "$CFWARP_PEER_KEY" endpoint "$CFWARP_NEW_ENDPOINT" >/dev/null 2>&1 || return 1
    if ! write_endpoint_to_config "$CFWARP_NEW_ENDPOINT"; then
        if [ -n "$CFWARP_OLD_ENDPOINT" ]; then
            wg set "$WG_INTERFACE" peer "$CFWARP_PEER_KEY" endpoint "$CFWARP_OLD_ENDPOINT" >/dev/null 2>&1 || true
        fi
        return 1
    fi
}

build_candidate_endpoints() {
    CFWARP_CURRENT_ENDPOINT=$1
    (
        [ -n "$CFWARP_CURRENT_ENDPOINT" ] && printf '%s\n' "$CFWARP_CURRENT_ENDPOINT"
        [ -n "$ENDPOINT_IP" ] && printf '%s\n' "$ENDPOINT_IP"
        printf '%s\n' "$ENDPOINT_CANDIDATES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    ) | awk 'NF && !seen[$0]++'
}

umask 077
mkdir -p "$CFWARP_DATA_DIR" "$(dirname "$WG_CONF")"
if [ -f "$WGCF_PROFILE" ]; then
    sync_wg_conf_from_profile
elif [ ! -f "$WG_CONF" ]; then
    migrate_legacy_wg_conf
fi
if [ ! -f "$WG_CONF" ]; then
    echo "==> [CFwarp] 未检测到配置，正在初始化 Cloudflare WARP。"
    initialize_wgcf
fi
[ -f "$WG_CONF" ] || { echo "==> [ERROR] 缺少 WireGuard 配置: $WG_CONF" >&2; exit 1; }
prepare_wireguard_config
if [ -n "$ENDPOINT_IP" ]; then
    cfwarp_validate_endpoint "$ENDPOINT_IP" || { echo "==> [ERROR] ENDPOINT_IP 格式非法。" >&2; exit 1; }
fi

WG_UP=0
CFWARP_TMP_CANDIDATES=$(mktemp)
cleanup_entrypoint() {
    CFWARP_EXIT_STATUS=$?
    rm -f "$CFWARP_TMP_CANDIDATES"
    if [ "$WG_UP" = "1" ]; then
        "$WG_QUICK_BIN" down "$WG_INTERFACE" >/dev/null 2>&1 || true
        WG_UP=0
    fi
    exit "$CFWARP_EXIT_STATUS"
}
trap 'cleanup_entrypoint' EXIT

"$WG_QUICK_BIN" down "$WG_INTERFACE" >/dev/null 2>&1 || true
echo "==> [CFwarp] 正在启动 WireGuard WARP 隧道。"
WG_UP=1
if ! "$WG_QUICK_BIN" up "$WG_CONF" >/dev/null 2>&1; then
    exit 1
fi

INITIAL_ENDPOINT=$(current_runtime_endpoint || true)
if [ -z "$INITIAL_ENDPOINT" ]; then
    INITIAL_ENDPOINT=$(config_endpoint)
fi
PEER_KEY=$(peer_public_key || true)
WARP_READY=0
TRACE_OUTPUT=
READY_STARTED_AT=$(date +%s)
READY_COMPLETED_AT=$READY_STARTED_AT
build_candidate_endpoints "$INITIAL_ENDPOINT" > "$CFWARP_TMP_CANDIDATES"

while IFS= read -r CFWARP_CANDIDATE_ENDPOINT; do
    [ -n "$CFWARP_CANDIDATE_ENDPOINT" ] || continue
    if ! cfwarp_validate_endpoint "$CFWARP_CANDIDATE_ENDPOINT"; then
        echo "==> [CFwarp] 跳过非法 Endpoint。" >&2
        continue
    fi
    ACTIVE_ENDPOINT=$(current_runtime_endpoint || true)
    if [ "$CFWARP_CANDIDATE_ENDPOINT" != "$ACTIVE_ENDPOINT" ]; then
        if ! set_runtime_endpoint "$CFWARP_CANDIDATE_ENDPOINT" "$PEER_KEY"; then
            echo "==> [CFwarp] Endpoint 切换失败，继续尝试下一个候选。" >&2
            continue
        fi
    fi
    echo "==> [CFwarp] 正在检查 WARP 隧道可用性。"
    if TRACE_OUTPUT=$(wait_for_warp_ready); then
        WARP_READY=1
        READY_COMPLETED_AT=$(date +%s)
        break
    fi
done < "$CFWARP_TMP_CANDIDATES"

if [ "$WARP_READY" != "1" ]; then
    if [ -n "$INITIAL_ENDPOINT" ] && [ -n "$PEER_KEY" ]; then
        wg set "$WG_INTERFACE" peer "$PEER_KEY" endpoint "$INITIAL_ENDPOINT" >/dev/null 2>&1 || true
        write_endpoint_to_config "$INITIAL_ENDPOINT" >/dev/null 2>&1 || true
    fi
    echo "==> [ERROR] WARP 隧道未就绪，请检查 Endpoint、UDP 出口和系统日志。" >&2
    exit 1
fi

CFWARP_EXIT_IP=$(awk -F= '$1 == "ip" {print $2; exit}' <<EOF
$TRACE_OUTPUT
EOF
)
echo "==> [CFwarp] WARP 出口已就绪: ${CFWARP_EXIT_IP:-unknown}"

if [ "$CFWARP_PROBE_MODE" = "1" ]; then
    READY_SECONDS=$((READY_COMPLETED_AT - READY_STARTED_AT))
    HTTP_AVG_TOTAL=$(measure_probe_http_average) || { echo "==> [ERROR] Endpoint 探测延迟测量失败。" >&2; exit 1; }
    SCORE=$(awk -v ready="$READY_SECONDS" -v total="$HTTP_AVG_TOTAL" 'BEGIN { printf "%.6f\n", ready + total }')
    SELECTED_ENDPOINT=$(current_runtime_endpoint || true)
    if [ -n "$CFWARP_PROBE_METRICS_FILE" ]; then
        umask 077
        {
            printf 'SELECTED_ENDPOINT=%s\n' "$SELECTED_ENDPOINT"
            printf 'READY_SECONDS=%s\n' "$READY_SECONDS"
            printf 'HTTP_AVG_TOTAL=%s\n' "$HTTP_AVG_TOTAL"
            printf 'SCORE=%s\n' "$SCORE"
            printf 'EXIT_IP=%s\n' "${CFWARP_EXIT_IP:-}"
        } | cfwarp_atomic_write_from_stdin "$CFWARP_PROBE_METRICS_FILE"
    fi
    echo "==> [CFwarp] Endpoint 探测完成: endpoint=${SELECTED_ENDPOINT} ready=${READY_SECONDS}s avg=${HTTP_AVG_TOTAL}s score=${SCORE}"
    exit 0
fi

LISTEN_ADDR=${BIND_ADDR:-${PROXY_CONNECT_HOST:-127.0.0.1}}
LISTEN_PORT=${BIND_PORT:-1080}
MICROSOCKS_BIN=${MICROSOCKS_BIN:-${SCRIPT_DIR}/bin/microsocks}
MICROSOCKS_QUIET=${MICROSOCKS_QUIET:-1}
cfwarp_validate_port "$LISTEN_PORT" BIND_PORT || exit 1
case "$LISTEN_ADDR" in
    ''|*[[:space:]]*|*[![:print:]]*) echo "==> [ERROR] BIND_ADDR 含有非法字符。" >&2; exit 1 ;;
esac
case "$MICROSOCKS_QUIET" in
    0|1) ;;
    *) echo "==> [ERROR] MICROSOCKS_QUIET 仅支持 0 或 1。" >&2; exit 1 ;;
esac
if { [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; } || { [ -z "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; }; then
    echo "==> [ERROR] SOCKS_USER 和 SOCKS_PASS 必须同时设置，或同时留空。" >&2
    exit 1
fi
if [ "${CFWARP_MODE:-netns-proxy}" = "host-global" ] && cfwarp_is_wildcard_bind "$LISTEN_ADDR" && [ -z "$SOCKS_USER" ]; then
    echo "==> [ERROR] host-global 模式禁止无认证监听通配地址，请设置 SOCKS_USER/SOCKS_PASS 或绑定 127.0.0.1。" >&2
    exit 1
fi
if [ ! -x "$MICROSOCKS_BIN" ]; then
    MICROSOCKS_BIN=$(command -v microsocks 2>/dev/null || true)
fi
if [ -z "$MICROSOCKS_BIN" ] || [ ! -x "$MICROSOCKS_BIN" ]; then
    echo "==> [ERROR] 找不到可执行的 microsocks，请检查 MICROSOCKS_BIN。" >&2
    exit 1
fi

set -- "$MICROSOCKS_BIN" -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
[ "$MICROSOCKS_QUIET" = "1" ] && set -- "$@" -q
if [ -n "$SOCKS_USER" ]; then
    set -- "$@" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    echo "==> [CFwarp] SOCKS5 认证已开启。"
else
    echo "==> [CFwarp] SOCKS5 未启用认证；请确保监听地址仅对受控网络可达。"
fi
echo "==> [CFwarp] SOCKS5 正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}。"
set +e
"$@"
CFWARP_PROXY_STATUS=$?
set -e
exit "$CFWARP_PROXY_STATUS"
