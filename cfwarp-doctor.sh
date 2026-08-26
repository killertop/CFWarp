#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
COMMON_FILE="${SCRIPT_DIR}/lib/cfwarp-common.sh"
if [ ! -r "$COMMON_FILE" ]; then
    echo "==> [ERROR] 找不到共享库: $COMMON_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$COMMON_FILE"

CFWARP_ENV_FILE=$(cfwarp_default_env_file "$SCRIPT_DIR")
CFWARP_SERVICE_NAME=${CFWARP_SERVICE_NAME:-cfwarp.service}
CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-/var/lib/cfwarp}
CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
CFWARP_DOCTOR_METRICS_FILE=${CFWARP_DOCTOR_METRICS_FILE:-}
FIX_MODE=0
CLI_METRICS_FILE=
FAILURES=0
WARNINGS=0
FIXES=0
TMP_HEALTH=$(mktemp)

cleanup() { rm -f "$TMP_HEALTH"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --fix)
            FIX_MODE=1
            shift
            ;;
        --metrics-file)
            CLI_METRICS_FILE=${2:-}
            [ -n "$CLI_METRICS_FILE" ] || { echo "==> [ERROR] --metrics-file 需要路径参数。" >&2; exit 1; }
            shift 2
            ;;
        -h|--help)
            cat <<EOF
用法: $0 [--fix] [--metrics-file PATH]

默认只检查；--fix 只修复文件权限、运行目录和陈旧状态锁，不会修改 sing-box、路由策略或防火墙规则。
EOF
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

METRICS_FILE=${CLI_METRICS_FILE:-$CFWARP_DOCTOR_METRICS_FILE}
info() { printf '%s\n' "==> [CFwarp] $*"; }
ok() { printf '%s\n' "ok: $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s\n' "warn: $*" >&2; }
fail() { FAILURES=$((FAILURES + 1)); printf '%s\n' "fail: $*" >&2; }
fixed() { FIXES=$((FIXES + 1)); printf '%s\n' "fix: $*"; }

load_env() {
    if [ -r "$CFWARP_ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$CFWARP_ENV_FILE"
        set +a
        CFWARP_MODE=${CFWARP_MODE:-netns-proxy}
        CFWARP_DATA_DIR=${CFWARP_DATA_DIR:-/var/lib/cfwarp}
        ok "已加载环境文件"
    elif [ -f "$CFWARP_ENV_FILE" ]; then
        warn "环境文件不可读，跳过依赖运行态配置的检查"
    elif [ -e "/etc/systemd/system/${CFWARP_SERVICE_NAME}" ]; then
        fail "环境文件不存在: $CFWARP_ENV_FILE"
    else
        warn "未找到已安装的环境文件；当前按源码检查模式运行"
    fi
    if [ -z "$METRICS_FILE" ]; then
        METRICS_FILE=${CFWARP_DOCTOR_METRICS_FILE:-}
    fi
}

check_scripts() {
    SCRIPT_LIST="lib/cfwarp-common.sh entrypoint.sh cfwarp-start.sh cfwarp-stop.sh cfwarp-netns.sh cfwarp-refresh-endpoint.sh cfwarp-healthcheck.sh cfwarp-watchdog.sh cfwarp-doctor.sh cfwarp-exec install.sh"
    for relative in $SCRIPT_LIST; do
        pathname="${SCRIPT_DIR}/${relative}"
        if [ ! -f "$pathname" ]; then
            fail "缺少文件: $pathname"
            continue
        fi
        if ! sh -n "$pathname"; then
            fail "脚本语法错误: $pathname"
            continue
        fi
        if [ ! -x "$pathname" ] && [ "$relative" != "lib/cfwarp-common.sh" ]; then
            if [ "$FIX_MODE" = "1" ]; then
                chmod 0755 "$pathname" && fixed "设置可执行权限: $relative" || fail "无法设置权限: $relative"
            else
                warn "脚本不可执行: $relative"
            fi
        fi
    done
    ok "核心脚本语法检查完成"
}

check_env_and_data() {
    if [ ! -r "$CFWARP_ENV_FILE" ]; then
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        ENV_MODE=$(stat -c '%a' "$CFWARP_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$CFWARP_ENV_FILE" 2>/dev/null || echo 600)
        case "$ENV_MODE" in
            600|640|400|440) ;;
            *)
                if [ "$FIX_MODE" = "1" ]; then
                    chmod 0600 "$CFWARP_ENV_FILE" && fixed "收紧环境文件权限" || fail "无法收紧环境文件权限"
                else
                    warn "环境文件权限偏宽: $ENV_MODE"
                fi
                ;;
        esac
    fi

    case "$CFWARP_MODE" in
        netns-proxy|host-global) ;;
        *) fail "不支持的 CFWARP_MODE: $CFWARP_MODE" ;;
    esac
    if [ "$(id -u)" -eq 0 ] && [ -d "$CFWARP_DATA_DIR" ]; then
        DATA_MODE=$(stat -c '%a' "$CFWARP_DATA_DIR" 2>/dev/null || stat -f '%Lp' "$CFWARP_DATA_DIR" 2>/dev/null || echo 700)
        case "$DATA_MODE" in
            700|750|710) ;;
            *)
                if [ "$FIX_MODE" = "1" ]; then
                    chmod 0700 "$CFWARP_DATA_DIR" && fixed "收紧 WARP 数据目录权限" || fail "无法收紧 WARP 数据目录权限"
                else
                    warn "WARP 数据目录权限偏宽: $DATA_MODE"
                fi
                ;;
        esac
    elif [ "$(id -u)" -eq 0 ]; then
        if [ "$FIX_MODE" = "1" ]; then
            install -d -m 0700 "$CFWARP_DATA_DIR" && fixed "创建 WARP 数据目录" || fail "无法创建 WARP 数据目录"
        else
            warn "WARP 数据目录不存在: $CFWARP_DATA_DIR"
        fi
    fi
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

check_systemd() {
    if ! systemd_available; then
        warn "未检测到运行中的 systemd，跳过服务运行态检查"
        return 0
    fi
    if ! systemctl cat "$CFWARP_SERVICE_NAME" >/dev/null 2>&1; then
        if [ -r "$CFWARP_ENV_FILE" ]; then
            fail "systemd unit 不存在: $CFWARP_SERVICE_NAME"
        else
            warn "尚未安装 $CFWARP_SERVICE_NAME"
        fi
        return 0
    fi
    ok "systemd unit 存在: $CFWARP_SERVICE_NAME"
    if systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
        ok "$CFWARP_SERVICE_NAME 正在运行"
    elif systemctl is-failed --quiet "$CFWARP_SERVICE_NAME"; then
        fail "$CFWARP_SERVICE_NAME 处于 failed 状态"
    else
        warn "$CFWARP_SERVICE_NAME 当前未运行"
    fi
    if systemctl cat cfwarp-watchdog.timer >/dev/null 2>&1; then
        if systemctl is-enabled --quiet cfwarp-watchdog.timer && systemctl is-active --quiet cfwarp-watchdog.timer; then
            ok "健康守护定时器已启用"
        else
            warn "健康守护定时器存在但未运行"
        fi
    fi
}

check_runtime() {
    if ! systemd_available || ! systemctl is-active --quiet "$CFWARP_SERVICE_NAME"; then
        return 0
    fi
    NETNS_NAME=${NETNS_NAME:-cfwarp}
    BIND_PORT=${BIND_PORT:-1080}
    if [ "$CFWARP_MODE" = "netns-proxy" ]; then
        if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -Fx "$NETNS_NAME" >/dev/null 2>&1; then
            fail "network namespace 不存在: $NETNS_NAME"
            return 0
        fi
        ok "network namespace 存在: $NETNS_NAME"
        if ! command -v ss >/dev/null 2>&1; then
            warn "未找到 ss，跳过 namespace 端口监听检查"
        elif ip netns exec "$NETNS_NAME" ss -ltn 2>/dev/null | awk -v port=":${BIND_PORT}" '$4 ~ port "$" { found = 1 } END { exit found ? 0 : 1 }'; then
            ok "SOCKS5 端口正在 namespace 内监听: ${NETNS_NAME}:${BIND_PORT}"
        else
            fail "SOCKS5 端口未在 namespace 内监听: ${NETNS_NAME}:${BIND_PORT}"
        fi
    fi
    if "$SCRIPT_DIR/cfwarp-healthcheck.sh" --format env > "$TMP_HEALTH" 2>&1; then
        eval "$(awk -F= '
            $1 == "CFWARP_EXIT_IP" && !ip_seen { printf "HEALTH_IP='\''%s'\'';\n", $2; ip_seen=1 }
            $1 == "CFWARP_COLO" && !colo_seen { printf "HEALTH_COLO='\''%s'\'';\n", $2; colo_seen=1 }
        ' "$TMP_HEALTH")"
        ok "SOCKS/WARP 健康检查通过: exit_ip=${HEALTH_IP:-unknown} colo=${HEALTH_COLO:-unknown}"
    else
        cat "$TMP_HEALTH" >&2
        fail "SOCKS/WARP 健康检查失败"
    fi
}

write_metrics() {
    [ -n "$METRICS_FILE" ] || return 0
    METRICS_DIR=$(dirname "$METRICS_FILE")
    mkdir -p "$METRICS_DIR" || return 1
    METRICS_TMP=$(mktemp "${METRICS_FILE}.tmp.XXXXXX") || return 1
    if ! cat > "$METRICS_TMP"; then
        rm -f "$METRICS_TMP"
        return 1
    fi
    chmod 0600 "$METRICS_TMP"
    mv "$METRICS_TMP" "$METRICS_FILE"
}

main() {
    if [ "$FIX_MODE" = "1" ]; then
        info "开始自检与修复"
    else
        info "开始自检"
    fi
    load_env
    check_scripts
    check_env_and_data
    check_systemd
    check_runtime
    DOCTOR_OK=0
    [ "$FAILURES" -eq 0 ] && DOCTOR_OK=1
    {
        printf 'CFWARP_DOCTOR_OK=%s\n' "$DOCTOR_OK"
        printf 'CFWARP_DOCTOR_FAILURES=%s\n' "$FAILURES"
        printf 'CFWARP_DOCTOR_WARNINGS=%s\n' "$WARNINGS"
        printf 'CFWARP_DOCTOR_FIXES=%s\n' "$FIXES"
        if [ -s "$TMP_HEALTH" ]; then sed -n '/^CFWARP_/p' "$TMP_HEALTH"; fi
    } | write_metrics || true
    info "自检完成: failures=${FAILURES} warnings=${WARNINGS} fixes=${FIXES}"
    [ "$FAILURES" -eq 0 ]
}

main
