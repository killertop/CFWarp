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

INSTALL_PREFIX=${CFWARP_INSTALL_PREFIX:-/opt/cfwarp}
DATA_DIR=${CFWARP_DATA_DIR:-/var/lib/cfwarp}
ENV_DIR=${CFWARP_ENV_DIR:-/etc/cfwarp}
SYSTEMD_DIR=${CFWARP_SYSTEMD_DIR:-/etc/systemd/system}
BIN_DIR=${CFWARP_BIN_DIR:-}
DATA_DIR_SET=0

ENABLE_SERVICE=1
ENABLE_REFRESH_TIMER=0
ENABLE_WATCHDOG_TIMER=1
START_SERVICE=0
RUN_CLEAN_GENERATED=0
RUN_DOCTOR=0
RUN_DOCTOR_FIX=0
FORCE_CLEAN=0
SKIP_DEPS=0
SKIP_BUILD=0
SKIP_PATCH_WG_QUICK=0
MICROSOCKS_REPO=${MICROSOCKS_REPO:-https://github.com/rofl0r/microsocks.git}
MICROSOCKS_COMMIT=${MICROSOCKS_COMMIT:-98421a21c4adc4c77c0cf3a5d650cc28ad3e0107}
MICROSOCKS_CFLAGS=${MICROSOCKS_CFLAGS:--O2 -pipe}

usage() {
    cat <<EOF
用法: ./install.sh [选项]

默认安装位置:
  运行目录: /opt/cfwarp
  环境文件: /etc/cfwarp/cfwarp.env
  WARP 数据: /var/lib/cfwarp
  systemd: /etc/systemd/system

选项:
  --prefix PATH               运行目录
  --data-dir PATH             WARP 持久化目录
  --env-dir PATH              私有环境文件目录
  --systemd-dir PATH          systemd unit 安装目录
  --systemd-link-dir PATH     --systemd-dir 的兼容别名
  --bin-dir PATH              二进制目录，默认 <prefix>/bin
  --skip-deps                 跳过系统依赖安装
  --skip-build                跳过 microsocks 编译，要求目标目录已有可执行文件
  --skip-patch-wg-quick       不移除 wg-quick 的 src_valid_mark 兼容行
  --doctor                    只运行自检
  --doctor-fix                只运行自检并修复权限/运行目录问题
  --no-enable                 不 enable cfwarp.service
  --enable-refresh-timer      额外启用每日 Endpoint 刷新定时器（会短暂停机探测）
  --no-refresh-timer          不启用每日 Endpoint 刷新定时器
  --no-watchdog-timer         不启用运行期健康守护定时器
  --start                     安装完成后启动或重启服务
  --clean-generated           删除本次安装生成的脚本、二进制和 unit
  --force                     配合 --clean-generated，允许服务运行中清理
  -h, --help                  显示帮助
EOF
}

require_arg() {
    if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
        echo "$1 需要一个非空参数。" >&2
        usage >&2
        exit 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            require_arg "$1" "${2:-}"
            INSTALL_PREFIX=$2
            shift 2
            ;;
        --data-dir)
            require_arg "$1" "${2:-}"
            DATA_DIR=$2
            DATA_DIR_SET=1
            shift 2
            ;;
        --env-dir)
            require_arg "$1" "${2:-}"
            ENV_DIR=$2
            shift 2
            ;;
        --systemd-dir|--systemd-link-dir)
            require_arg "$1" "${2:-}"
            SYSTEMD_DIR=$2
            shift 2
            ;;
        --bin-dir)
            require_arg "$1" "${2:-}"
            BIN_DIR=$2
            shift 2
            ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-patch-wg-quick) SKIP_PATCH_WG_QUICK=1; shift ;;
        --doctor) RUN_DOCTOR=1; shift ;;
        --doctor-fix) RUN_DOCTOR=1; RUN_DOCTOR_FIX=1; shift ;;
        --no-enable) ENABLE_SERVICE=0; shift ;;
        --enable-refresh-timer) ENABLE_REFRESH_TIMER=1; shift ;;
        --no-refresh-timer) ENABLE_REFRESH_TIMER=0; shift ;;
        --no-watchdog-timer) ENABLE_WATCHDOG_TIMER=0; shift ;;
        --start) START_SERVICE=1; shift ;;
        --clean-generated) RUN_CLEAN_GENERATED=1; shift ;;
        --force) FORCE_CLEAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$BIN_DIR" ] || BIN_DIR="${INSTALL_PREFIX}/bin"
ENV_FILE="${ENV_DIR}/cfwarp.env"
SYSTEMD_UNIT="${SYSTEMD_DIR}/cfwarp.service"
REFRESH_UNIT="${SYSTEMD_DIR}/cfwarp-endpoint-refresh.service"
REFRESH_TIMER="${SYSTEMD_DIR}/cfwarp-endpoint-refresh.timer"
WATCHDOG_UNIT="${SYSTEMD_DIR}/cfwarp-watchdog.service"
WATCHDOG_TIMER="${SYSTEMD_DIR}/cfwarp-watchdog.timer"
ENV_TEMPLATE="${SCRIPT_DIR}/deploy/cfwarp.env.example"
TEMPLATE_DIR="${SCRIPT_DIR}/deploy/systemd"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行安装脚本。" >&2
        exit 1
    fi
}

validate_path() {
    case "$2" in
        /*) ;;
        *) echo "==> [ERROR] $1 必须是绝对路径: $2" >&2; exit 1 ;;
    esac
}

validate_paths() {
    validate_path INSTALL_PREFIX "$INSTALL_PREFIX"
    validate_path DATA_DIR "$DATA_DIR"
    validate_path ENV_DIR "$ENV_DIR"
    validate_path SYSTEMD_DIR "$SYSTEMD_DIR"
    validate_path BIN_DIR "$BIN_DIR"
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

install_deps() {
    [ "$SKIP_DEPS" = "1" ] && return 0
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y bash ca-certificates curl git build-essential wireguard-tools iproute2 iptables coreutils
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash ca-certificates curl git build-base wireguard-tools iproute2 iptables coreutils
    else
        echo "当前仅自动支持 apt-get 和 apk。请手动安装 bash ca-certificates curl git gcc make wireguard-tools iproute2 iptables coreutils。" >&2
        exit 1
    fi
}

build_microsocks() {
    if [ "$SKIP_BUILD" = "1" ]; then
        if [ ! -x "${BIN_DIR}/microsocks" ]; then
            echo "已跳过编译，但 ${BIN_DIR}/microsocks 不存在或不可执行。" >&2
            exit 1
        fi
        return 0
    fi
    if ! printf '%s\n' "$MICROSOCKS_COMMIT" | awk 'length($0) == 40 && $0 ~ /^[0-9A-Fa-f]+$/ { exit 0 } { exit 1 }'; then
        echo "==> [ERROR] MICROSOCKS_COMMIT 必须是 40 位十六进制 commit。" >&2
        exit 1
    fi
    TMP_DIR=$(mktemp -d)
    cleanup_build() { rm -rf "$TMP_DIR"; }
    trap 'cleanup_build' EXIT HUP INT TERM
    git clone "$MICROSOCKS_REPO" "${TMP_DIR}/microsocks"
    (
        cd "${TMP_DIR}/microsocks"
        git checkout --detach "$MICROSOCKS_COMMIT"
        ACTUAL_COMMIT=$(git rev-parse HEAD)
        [ "$ACTUAL_COMMIT" = "$MICROSOCKS_COMMIT" ] || { echo "==> [ERROR] microsocks commit 校验失败。" >&2; exit 1; }
        make CFLAGS="$MICROSOCKS_CFLAGS"
        install -d "$BIN_DIR"
        install -m 0755 microsocks "${BIN_DIR}/microsocks"
    )
    trap - EXIT HUP INT TERM
    cleanup_build
}

install_private_wg_quick() {
    WG_QUICK_SRC=${WG_QUICK_SRC:-$(command -v wg-quick 2>/dev/null || true)}
    if [ -z "$WG_QUICK_SRC" ] || [ ! -f "$WG_QUICK_SRC" ]; then
        echo "==> [ERROR] 未找到 wg-quick，请先安装 wireguard-tools。" >&2
        exit 1
    fi
    install -d "$BIN_DIR"
    if [ "$WG_QUICK_SRC" != "${BIN_DIR}/wg-quick" ]; then
        install -m 0755 "$WG_QUICK_SRC" "${BIN_DIR}/wg-quick"
    else
        chmod 0755 "${BIN_DIR}/wg-quick"
    fi
    if [ "$SKIP_PATCH_WG_QUICK" != "1" ] && grep -q 'src_valid_mark' "${BIN_DIR}/wg-quick"; then
        # wg-quick tries to write a host sysctl while it is executed inside a
        # namespace. Remove only that compatibility line from the private copy.
        sed -i '/src_valid_mark/d' "${BIN_DIR}/wg-quick"
    fi
    if ! command -v bash >/dev/null 2>&1 || ! bash -n "${BIN_DIR}/wg-quick"; then
        echo "==> [ERROR] 私有 wg-quick 语法校验失败。" >&2
        exit 1
    fi
}

ensure_env_file() {
    if [ "$DATA_DIR_SET" = "0" ] && [ -f "$ENV_FILE" ]; then
        EXISTING_DATA_DIR=$(sed -n 's/^CFWARP_DATA_DIR=//p' "$ENV_FILE" | tail -n 1)
        case "$EXISTING_DATA_DIR" in
            /*) DATA_DIR=$EXISTING_DATA_DIR ;;
        esac
    fi
    install -d -m 0700 "$ENV_DIR" "$DATA_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        install -m 0600 "$ENV_TEMPLATE" "$ENV_FILE"
    fi
    cfwarp_set_env_key CFWARP_DATA_DIR "$DATA_DIR" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    chmod 0700 "$DATA_DIR"
}

install_file() {
    CFWARP_SOURCE=$1
    CFWARP_DESTINATION=$2
    CFWARP_MODE=$3
    if [ "$CFWARP_SOURCE" != "$CFWARP_DESTINATION" ]; then
        install -D -m "$CFWARP_MODE" "$CFWARP_SOURCE" "$CFWARP_DESTINATION"
    else
        chmod "$CFWARP_MODE" "$CFWARP_DESTINATION"
    fi
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

render_template() {
    CFWARP_TEMPLATE=$1
    CFWARP_DESTINATION=$2
    CFWARP_TMP="${CFWARP_DESTINATION}.tmp.$$"
    CFWARP_ESC_PREFIX=$(escape_sed_replacement "$INSTALL_PREFIX")
    CFWARP_ESC_ENV=$(escape_sed_replacement "$ENV_FILE")
    CFWARP_ESC_BIN=$(escape_sed_replacement "$BIN_DIR")
    sed -e "s|@INSTALL_PREFIX@|${CFWARP_ESC_PREFIX}|g" \
        -e "s|@ENV_FILE@|${CFWARP_ESC_ENV}|g" \
        -e "s|@BIN_DIR@|${CFWARP_ESC_BIN}|g" \
        "$CFWARP_TEMPLATE" > "$CFWARP_TMP"
    chmod 0644 "$CFWARP_TMP"
    mv "$CFWARP_TMP" "$CFWARP_DESTINATION"
}

install_runtime_files() {
    install -d -m 0755 "$INSTALL_PREFIX" "$BIN_DIR" "$SYSTEMD_DIR"
    install_file "${SCRIPT_DIR}/lib/cfwarp-common.sh" "${INSTALL_PREFIX}/lib/cfwarp-common.sh" 0644
    for script in entrypoint.sh cfwarp-start.sh cfwarp-stop.sh cfwarp-netns.sh cfwarp-refresh-endpoint.sh cfwarp-healthcheck.sh cfwarp-watchdog.sh cfwarp-doctor.sh; do
        install_file "${SCRIPT_DIR}/${script}" "${INSTALL_PREFIX}/${script}" 0755
    done
    install_file "${SCRIPT_DIR}/cfwarp-exec" "${INSTALL_PREFIX}/cfwarp-exec" 0755
    if [ "${BIN_DIR}/cfwarp-exec" != "${INSTALL_PREFIX}/cfwarp-exec" ]; then
        ln -sfn "${INSTALL_PREFIX}/cfwarp-exec" "${BIN_DIR}/cfwarp-exec"
    fi
    ensure_env_file
    render_template "${TEMPLATE_DIR}/cfwarp.service.in" "$SYSTEMD_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-endpoint-refresh.service.in" "$REFRESH_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-endpoint-refresh.timer.in" "$REFRESH_TIMER"
    render_template "${TEMPLATE_DIR}/cfwarp-watchdog.service.in" "$WATCHDOG_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-watchdog.timer.in" "$WATCHDOG_TIMER"
}

clean_generated() {
    require_root
    if systemd_available; then
        if systemctl is-active --quiet cfwarp.service; then
            if [ "$FORCE_CLEAN" != "1" ]; then
                echo "cfwarp.service 正在运行，拒绝清理；请先停止服务或加 --force。" >&2
                exit 1
            fi
            systemctl stop cfwarp.service
        fi
        systemctl disable --now cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer >/dev/null 2>&1 || true
        systemctl disable cfwarp.service >/dev/null 2>&1 || true
    fi
    rm -f "$SYSTEMD_UNIT" "$REFRESH_UNIT" "$REFRESH_TIMER" "$WATCHDOG_UNIT" "$WATCHDOG_TIMER"
    rm -f "${BIN_DIR}/cfwarp-exec" "${BIN_DIR}/microsocks" "${BIN_DIR}/wg-quick"
    rm -f "${INSTALL_PREFIX}/cfwarp-exec" "${INSTALL_PREFIX}/entrypoint.sh" "${INSTALL_PREFIX}/cfwarp-start.sh" "${INSTALL_PREFIX}/cfwarp-stop.sh" "${INSTALL_PREFIX}/cfwarp-netns.sh" "${INSTALL_PREFIX}/cfwarp-refresh-endpoint.sh" "${INSTALL_PREFIX}/cfwarp-healthcheck.sh" "${INSTALL_PREFIX}/cfwarp-watchdog.sh" "${INSTALL_PREFIX}/cfwarp-doctor.sh"
    systemd_available && systemctl daemon-reload || true
    echo "已清理 CFwarp 生成物；未删除环境文件和 WARP 数据目录。"
}

reload_and_enable() {
    if ! systemd_available; then
        echo "未检测到运行中的 systemd，已安装文件但未执行 daemon-reload/enable/start。"
        return 0
    fi
    systemctl daemon-reload
    [ "$ENABLE_SERVICE" = "1" ] && systemctl enable cfwarp.service
    if [ "$ENABLE_REFRESH_TIMER" = "1" ]; then
        systemctl enable --now cfwarp-endpoint-refresh.timer
    fi
    if [ "$ENABLE_WATCHDOG_TIMER" = "1" ]; then
        systemctl enable --now cfwarp-watchdog.timer
    fi
    if [ "$START_SERVICE" = "1" ]; then
        if systemctl is-active --quiet cfwarp.service; then
            systemctl restart cfwarp.service
        else
            systemctl start cfwarp.service
        fi
    fi
}

print_summary() {
    cat <<EOF
CFwarp 安装文件已准备完成:
  运行目录: ${INSTALL_PREFIX}
  环境文件: ${ENV_FILE}（权限 0600）
  WARP 数据: ${DATA_DIR}（权限 0700）
  SOCKS5: ${BIN_DIR}/microsocks
  私有 wg-quick: ${BIN_DIR}/wg-quick
  命令执行助手: ${INSTALL_PREFIX}/cfwarp-exec
  systemd unit: ${SYSTEMD_UNIT}
  健康检查: ${INSTALL_PREFIX}/cfwarp-healthcheck.sh
  自检: ${INSTALL_PREFIX}/cfwarp-doctor.sh

默认模式为 netns-proxy；每日 Endpoint 刷新默认关闭，运行期健康守护默认启用。
如需启动服务，请执行: systemctl start cfwarp.service
EOF
}

if [ "$RUN_DOCTOR" = "1" ]; then
    if [ "$RUN_DOCTOR_FIX" = "1" ]; then
        exec "${SCRIPT_DIR}/cfwarp-doctor.sh" --fix
    fi
    exec "${SCRIPT_DIR}/cfwarp-doctor.sh"
fi
if [ "$RUN_CLEAN_GENERATED" = "1" ]; then
    validate_paths
    clean_generated
    exit 0
fi

require_root
validate_paths
install_deps
build_microsocks
install_private_wg_quick
install_runtime_files
reload_and_enable
print_summary
