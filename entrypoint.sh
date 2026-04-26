#!/bin/sh
set -e

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

WG_INTERFACE=${WG_INTERFACE:-"wg0"}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-${MICROWARP_DATA_DIR:-"${SCRIPT_DIR}/var"}}
WG_CONF_DIR=${WG_CONF_DIR:-"${CFWARP_DATA_DIR}"}
WG_CONF=${WG_CONF:-"${WG_CONF_DIR}/${WG_INTERFACE}.conf"}
WGCF_PROFILE=${WGCF_PROFILE:-"${CFWARP_DATA_DIR}/wgcf-profile.conf"}
WGCF_ACCOUNT=${WGCF_ACCOUNT:-"${CFWARP_DATA_DIR}/wgcf-account.toml"}
WG_QUICK_BIN=${WG_QUICK_BIN:-"wg-quick"}
WARP_READY_ATTEMPTS=${WARP_READY_ATTEMPTS:-6}
WARP_READY_DELAY_SECONDS=${WARP_READY_DELAY_SECONDS:-2}
WARP_HEALTHCHECK_CONNECT_TIMEOUT=${WARP_HEALTHCHECK_CONNECT_TIMEOUT:-4}
WARP_HEALTHCHECK_TOTAL_TIMEOUT=${WARP_HEALTHCHECK_TOTAL_TIMEOUT:-8}
WARP_HEALTHCHECK_TRACE_URL=${WARP_HEALTHCHECK_TRACE_URL:-"https://1.1.1.1/cdn-cgi/trace"}
WARP_HEALTHCHECK_TEST_URL=${WARP_HEALTHCHECK_TEST_URL:-"https://www.gstatic.com/generate_204"}
LEGACY_SYSTEM_WG_CONF=${LEGACY_SYSTEM_WG_CONF:-"/etc/wireguard/${WG_INTERFACE}.conf"}
CFWARP_TEST_MODE=${CFWARP_TEST_MODE:-${MICROWARP_TEST_MODE:-0}}
CFWARP_PROBE_MODE=${CFWARP_PROBE_MODE:-0}
CFWARP_PROBE_URL=${CFWARP_PROBE_URL:-"$WARP_HEALTHCHECK_TRACE_URL"}
CFWARP_PROBE_SAMPLES=${CFWARP_PROBE_SAMPLES:-2}
CFWARP_PROBE_METRICS_FILE=${CFWARP_PROBE_METRICS_FILE:-""}

build_wgcf_download_url() {
    WGCF_VER=$1
    WGCF_ARCH=$2
    RAW_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"

    if [ -n "${GH_PROXY:-}" ]; then
        echo "${GH_PROXY%/}/${RAW_URL}"
        return 0
    fi

    echo "$RAW_URL"
}

current_runtime_endpoint() {
    wg show "$WG_INTERFACE" endpoints 2>/dev/null | awk 'NF >= 2 {print $2; exit}'
}

peer_public_key() {
    sed -n 's/^PublicKey = //p' "$WG_CONF" | head -n 1
}

has_latest_handshake() {
    wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk 'NF >= 2 && $2 + 0 > 0 {found = 1} END {exit found ? 0 : 1}'
}

fetch_trace() {
    curl -4 -sS \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        "$WARP_HEALTHCHECK_TRACE_URL" 2>/dev/null || true
}

trace_warp_active() {
    printf '%s\n' "$1" | awk -F= '$1 == "warp" && $2 != "off" && $2 != "" {found = 1} END {exit found ? 0 : 1}'
}

test_warp_http() {
    curl -4 -fsS -o /dev/null \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        "$WARP_HEALTHCHECK_TEST_URL" >/dev/null 2>&1
}

probe_http_total() {
    curl -4 -sS -o /dev/null \
        --connect-timeout "$WARP_HEALTHCHECK_CONNECT_TIMEOUT" \
        --max-time "$WARP_HEALTHCHECK_TOTAL_TIMEOUT" \
        -w '%{time_total}\n' \
        "$CFWARP_PROBE_URL" 2>/dev/null
}

measure_probe_http_average() {
    SAMPLE_INDEX=1
    SAMPLE_OUTPUT=""
    while [ "$SAMPLE_INDEX" -le "$CFWARP_PROBE_SAMPLES" ]; do
        SAMPLE_VALUE=$(probe_http_total) || return 1
        SAMPLE_OUTPUT="${SAMPLE_OUTPUT}${SAMPLE_VALUE}
"
        SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
    done

    printf '%s' "$SAMPLE_OUTPUT" | awk 'NF {sum += $1; count += 1} END {if (count == 0) exit 1; printf "%.6f\n", sum / count}'
}

wait_for_warp_ready() {
    attempt=1
    while [ "$attempt" -le "$WARP_READY_ATTEMPTS" ]; do
        TRACE_OUTPUT=$(fetch_trace)
        if has_latest_handshake && trace_warp_active "$TRACE_OUTPUT" && test_warp_http; then
            printf '%s\n' "$TRACE_OUTPUT"
            return 0
        fi
        sleep "$WARP_READY_DELAY_SECONDS"
        attempt=$((attempt + 1))
    done
    return 1
}

set_runtime_endpoint() {
    NEW_ENDPOINT=$1
    PEER_KEY=$2
    [ -n "$NEW_ENDPOINT" ] || return 1
    [ -n "$PEER_KEY" ] || return 1
    wg set "$WG_INTERFACE" peer "$PEER_KEY" endpoint "$NEW_ENDPOINT" > /dev/null 2>&1 || return 1
    sed -i "s|^Endpoint = .*|Endpoint = ${NEW_ENDPOINT}|" "$WG_CONF"
}

build_candidate_endpoints() {
    CURRENT_ENDPOINT=$1
    (
        [ -n "$CURRENT_ENDPOINT" ] && printf '%s\n' "$CURRENT_ENDPOINT"
        [ -n "${ENDPOINT_IP:-}" ] && printf '%s\n' "$ENDPOINT_IP"
        printf '%s\n' "${ENDPOINT_CANDIDATES:-}" | tr ',' '\n'
    ) | awk 'NF && !seen[$0]++'
}

sync_wg_conf_from_profile() {
    [ -f "$WGCF_PROFILE" ] || return 1
    cp "$WGCF_PROFILE" "$WG_CONF"
    chmod 600 "$WG_CONF"
}

migrate_legacy_wg_conf() {
    if [ -f "$WG_CONF" ]; then
        return 0
    fi

    if [ "$WG_CONF" != "$LEGACY_SYSTEM_WG_CONF" ] && [ -f "$LEGACY_SYSTEM_WG_CONF" ]; then
        echo "==> [CFwarp] 检测到旧版 /etc/wireguard 配置，正在迁移到 ${WG_CONF}"
        cp "$LEGACY_SYSTEM_WG_CONF" "$WG_CONF"
        chmod 600 "$WG_CONF"
    fi
}

if [ "$CFWARP_TEST_MODE" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

mkdir -p "$(dirname "$WG_CONF")"
mkdir -p "$CFWARP_DATA_DIR"
migrate_legacy_wg_conf

# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    if [ -f "$WGCF_PROFILE" ]; then
        echo "==> [CFwarp] 检测到已有持久化 profile，正在生成运行配置。"
        sync_wg_conf_from_profile
    else
        echo "==> [CFwarp] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) WGCF_ARCH="amd64" ;;
            aarch64) WGCF_ARCH="arm64" ;;
            *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
        esac

        WGCF_VER_DEFAULT="2.2.31"
        WGCF_VER=$(
            curl -fsSL --connect-timeout 5 --max-time 10 \
                https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' \
            | head -n 1
        )

        if [ -n "$WGCF_VER" ]; then
            echo "==> [CFwarp] 检测到最新 wgcf 版本: v${WGCF_VER}"
        else
            WGCF_VER="$WGCF_VER_DEFAULT"
            echo "==> [CFwarp] 获取最新 wgcf 版本失败，回退到默认版本: v${WGCF_VER}"
        fi

        TMP_WGCF_DIR=$(mktemp -d)
        cleanup_tmp_wgcf_dir() {
            rm -rf "$TMP_WGCF_DIR"
        }
        trap 'cleanup_tmp_wgcf_dir' EXIT HUP INT TERM

        wget --timeout=15 -qO "${TMP_WGCF_DIR}/wgcf" "$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")"
        chmod +x "${TMP_WGCF_DIR}/wgcf"

        echo "==> [CFwarp] 正在向 CF 注册设备..."
        (
            cd "$TMP_WGCF_DIR"
            ./wgcf register --accept-tos > /dev/null
        )

        echo "==> [CFwarp] 正在生成 WireGuard 配置文件..."
        (
            cd "$TMP_WGCF_DIR"
            ./wgcf generate > /dev/null
        )

        mv "${TMP_WGCF_DIR}/wgcf-profile.conf" "$WGCF_PROFILE"
        mv "${TMP_WGCF_DIR}/wgcf-account.toml" "$WGCF_ACCOUNT"
        chmod 600 "$WGCF_PROFILE" "$WGCF_ACCOUNT"
        sync_wg_conf_from_profile

        trap - EXIT HUP INT TERM
        cleanup_tmp_wgcf_dir
        echo "==> [CFwarp] 节点配置生成成功！"
    fi
else
    echo "==> [CFwarp] 检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 2. 强力洗白与内核兼容性处理 (性能优化版)
# ==========================================

# 1. 智能提取出纯 IPv4 地址
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

# 2. 合并配置文件修改逻辑，减少磁盘 I/O
echo "==> [CFwarp] 正在优化 WireGuard 网络配置 (MTU=1280, Keepalive=15)..."
sed -i -e '/^Address/d' \
       -e '/^AllowedIPs/d' \
       -e '/^DNS.*/d' \
       -e '/^MTU/d' \
       -e '/^PersistentKeepalive/d' \
       -e "/\[Interface\]/a Address = ${IPV4_ADDR:-172.16.0.2/32}" \
       -e '/\[Interface\]/a MTU = 1280' \
       -e '/\[Peer\]/a AllowedIPs = 0.0.0.0/0' \
       -e '/\[Peer\]/a PersistentKeepalive = 15' \
       "$WG_CONF"

# 【新增：防阻断绝杀】针对 HK/US 强校验机房，注入自定义优选 Endpoint IP
if [ -n "$ENDPOINT_IP" ]; then
    echo "==> [CFwarp] 🔀 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi

# ==========================================
# 3. 拉起内核网卡
# ==========================================
# 在启用 WARP 前记录 100.64.0.0/10 的原始回程路径，避免发布端口后 Tailscale 客户端握手卡死
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')
PRE_WARP_SRC=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}')

echo "==> [CFwarp] 正在启动 Linux 内核级 ${WG_INTERFACE} 网卡..."
"$WG_QUICK_BIN" up "$WG_CONF" > /dev/null 2>&1

# 仅在 WARP 启动前确实存在原始回程路径时恢复 100.64.0.0/10，减少对非 Tailscale 场景的影响
TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
if [ -n "$PRE_WARP_DEV" ]; then
    ROUTE_RESTORED=0
    if [ -n "$PRE_WARP_GW" ]; then
        if [ -n "$PRE_WARP_SRC" ]; then
            RESTORE_ROUTE_DESC="via ${PRE_WARP_GW} dev ${PRE_WARP_DEV} src ${PRE_WARP_SRC}"
            if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" src "$PRE_WARP_SRC" > /dev/null 2>&1; then
                ROUTE_RESTORED=1
            fi
        else
            RESTORE_ROUTE_DESC="via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
            if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
                ROUTE_RESTORED=1
            fi
        fi
    else
        if [ -n "$PRE_WARP_SRC" ]; then
            RESTORE_ROUTE_DESC="dev ${PRE_WARP_DEV} src ${PRE_WARP_SRC}"
            if ip route replace "$TAILSCALE_CIDR" dev "$PRE_WARP_DEV" src "$PRE_WARP_SRC" > /dev/null 2>&1; then
                ROUTE_RESTORED=1
            fi
        else
            RESTORE_ROUTE_DESC="dev ${PRE_WARP_DEV}"
            if ip route replace "$TAILSCALE_CIDR" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
                ROUTE_RESTORED=1
            fi
        fi
    fi

    if [ "$ROUTE_RESTORED" = "1" ]; then
        echo "==> [CFwarp] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: ${RESTORE_ROUTE_DESC}"
    fi
fi

PEER_KEY=$(peer_public_key)
CURRENT_ENDPOINT=$(current_runtime_endpoint)
TRACE_OUTPUT=""
WARP_READY=0
READY_STARTED_AT=$(date +%s)
READY_COMPLETED_AT=$READY_STARTED_AT

for CANDIDATE_ENDPOINT in $(build_candidate_endpoints "$CURRENT_ENDPOINT"); do
    ACTIVE_ENDPOINT=$(current_runtime_endpoint)
    if [ -n "$CANDIDATE_ENDPOINT" ] && [ "$CANDIDATE_ENDPOINT" != "$ACTIVE_ENDPOINT" ]; then
        echo "==> [CFwarp] 正在切换 Endpoint 进行连通性尝试: $CANDIDATE_ENDPOINT"
        if ! set_runtime_endpoint "$CANDIDATE_ENDPOINT" "$PEER_KEY"; then
            echo "==> [CFwarp] ⚠️ Endpoint 切换失败，跳过: $CANDIDATE_ENDPOINT"
            continue
        fi
    fi

    echo "==> [CFwarp] 正在检查 WARP 隧道可用性..."
    if TRACE_OUTPUT=$(wait_for_warp_ready); then
        WARP_READY=1
        READY_COMPLETED_AT=$(date +%s)
        break
    fi
done

if [ "$WARP_READY" != "1" ]; then
    echo "==> [ERROR] WARP 隧道未就绪，未检测到有效握手或可用出口。"
    "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
    exit 1
fi

echo "==> [CFwarp] 当前出口 IP 已成功变更为："
printf '%s\n' "$TRACE_OUTPUT" | grep '^ip=' || echo "⚠️ 未从 trace 输出中解析到 ip 字段"

if [ "$CFWARP_PROBE_MODE" = "1" ]; then
    READY_SECONDS=$((READY_COMPLETED_AT - READY_STARTED_AT))
    HTTP_AVG_TOTAL=$(measure_probe_http_average) || {
        echo "==> [ERROR] Probe 模式下的 HTTP 时延测量失败。"
        "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
        exit 1
    }
    SCORE=$(awk -v ready="$READY_SECONDS" -v total="$HTTP_AVG_TOTAL" 'BEGIN {printf "%.6f\n", ready + total}')
    SELECTED_ENDPOINT=$(current_runtime_endpoint)
    EXIT_IP=$(printf '%s\n' "$TRACE_OUTPUT" | sed -n 's/^ip=//p' | head -n 1)

    if [ -n "$CFWARP_PROBE_METRICS_FILE" ]; then
        cat > "$CFWARP_PROBE_METRICS_FILE" <<EOF
SELECTED_ENDPOINT='${SELECTED_ENDPOINT}'
READY_SECONDS='${READY_SECONDS}'
HTTP_AVG_TOTAL='${HTTP_AVG_TOTAL}'
SCORE='${SCORE}'
EXIT_IP='${EXIT_IP}'
EOF
    fi

    echo "==> [CFwarp] Probe 结果: endpoint=${SELECTED_ENDPOINT} ready=${READY_SECONDS}s avg=${HTTP_AVG_TOTAL}s score=${SCORE}"
    "$WG_QUICK_BIN" down "$WG_INTERFACE" > /dev/null 2>&1 || true
    exit 0
fi

# ==========================================
# 4. 启动 C 语言 SOCKS5 代理服务 (带高级参数绑定)
# ==========================================
# 读取环境变量，如果未设置则使用默认值 0.0.0.0 和 1080
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if { [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; } || { [ -z "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; }; then
    echo "==> [ERROR] SOCKS_USER 和 SOCKS_PASS 必须同时设置，或同时留空。"
    exit 1
fi

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==> [CFwarp] 🔒 身份认证已开启 (User: $SOCKS_USER)"
    if [ -n "${PROXY_CONNECT_HOST:-}" ]; then
        echo "==> [CFwarp] 宿主机可通过 ${PROXY_CONNECT_HOST}:${LISTEN_PORT} 使用该 SOCKS5 代理"
    fi
    echo "==> [CFwarp] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    # 使用 exec 接管进程，实现 Zero-Overhead 的底层进程控制
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    echo "==> [CFwarp] ⚠️ 未设置密码，当前为公开访问模式"
    if [ -n "${PROXY_CONNECT_HOST:-}" ]; then
        echo "==> [CFwarp] 宿主机可通过 ${PROXY_CONNECT_HOST}:${LISTEN_PORT} 使用该 SOCKS5 代理"
    fi
    echo "==> [CFwarp] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
