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
[ -z "${CFWARP_DATA_DIR+x}" ] || DATA_DIR_SET=1

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
  --skip-patch-wg-quick       兼容旧命令；现在始终保留完整 wg-quick
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
        --skip-patch-wg-quick) shift ;;
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
    case "$2" in
        /|*/../*|*/..|*/./*|*/.|*[!A-Za-z0-9_./-]*)
            echo "==> [ERROR] $1 must be a non-root absolute path using letters, digits, /, _, . and -." >&2
            exit 1 ;;
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
        apt-get install -y bash ca-certificates curl git build-essential wireguard-tools iproute2 iptables coreutils util-linux
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash ca-certificates curl git build-base wireguard-tools iproute2 iptables coreutils util-linux
    else
        echo "当前仅自动支持 apt-get 和 apk。请手动安装 bash ca-certificates curl git gcc make wireguard-tools iproute2 iptables coreutils util-linux。" >&2
        exit 1
    fi
}

CFWARP_BUILD_TMP=
CFWARP_MICROSOCKS_STAGED=
cleanup_install_temporary_files() {
    CFWARP_INSTALL_EXIT_STATUS=$?
    trap - EXIT HUP INT TERM
    if [ -n "$CFWARP_BUILD_TMP" ]; then
        rm -rf "$CFWARP_BUILD_TMP" || CFWARP_INSTALL_EXIT_STATUS=1
    fi
    if [ -n "$CFWARP_MICROSOCKS_STAGED" ]; then
        rm -f "$CFWARP_MICROSOCKS_STAGED" || CFWARP_INSTALL_EXIT_STATUS=1
    fi
    exit "$CFWARP_INSTALL_EXIT_STATUS"
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
    CFWARP_BUILD_TMP=$(mktemp -d)
    CFWARP_MICROSOCKS_STAGED="${BIN_DIR}/.microsocks.new.$$"
    git clone "$MICROSOCKS_REPO" "${CFWARP_BUILD_TMP}/microsocks"
    (
        cd "${CFWARP_BUILD_TMP}/microsocks"
        git checkout --detach "$MICROSOCKS_COMMIT"
        ACTUAL_COMMIT=$(git rev-parse HEAD)
        [ "$ACTUAL_COMMIT" = "$MICROSOCKS_COMMIT" ] || { echo "==> [ERROR] microsocks commit 校验失败。" >&2; exit 1; }
        make CFLAGS="$MICROSOCKS_CFLAGS"
        install -d "$BIN_DIR"
        install -m 0755 microsocks "$CFWARP_MICROSOCKS_STAGED"
    )
    rm -rf "$CFWARP_BUILD_TMP"
    CFWARP_BUILD_TMP=
}

publish_microsocks() {
    [ -n "$CFWARP_MICROSOCKS_STAGED" ] || return 0
    mv -f "$CFWARP_MICROSOCKS_STAGED" "${BIN_DIR}/microsocks"
    CFWARP_MICROSOCKS_STAGED=
}

install_private_wg_quick() {
    if [ -z "${WG_QUICK_SRC:-}" ]; then
        # Prefer the package copy, not a previously patched private binary on PATH.
        if [ -x /usr/bin/wg-quick ]; then
            WG_QUICK_SRC=/usr/bin/wg-quick
        else
            WG_QUICK_SRC=$(command -v wg-quick 2>/dev/null || true)
        fi
    fi
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
    # src_valid_mark is network-namespaced and needed with strict rp_filter.
    # Preserve the complete distribution script, including its routing setup.
    if ! command -v bash >/dev/null 2>&1 || ! bash -n "${BIN_DIR}/wg-quick"; then
        echo "==> [ERROR] 私有 wg-quick 语法校验失败。" >&2
        exit 1
    fi
}

ensure_env_file() {
    if [ "$DATA_DIR_SET" = "0" ] && [ -f "$ENV_FILE" ]; then
        # Parse quoted assignments with the same grammar used by the runtime.
        cfwarp_parse_env "$ENV_FILE" >/dev/null || exit 1
        EXISTING_DATA_DIR=$(cfwarp_read_env_key CFWARP_DATA_DIR "$ENV_FILE" || true)
        if [ -n "$EXISTING_DATA_DIR" ]; then
            validate_path CFWARP_DATA_DIR "$EXISTING_DATA_DIR"
            DATA_DIR=$EXISTING_DATA_DIR
        fi
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
    CFWARP_INSTALL_MODE=$3
    if [ "$CFWARP_SOURCE" != "$CFWARP_DESTINATION" ]; then
        install -D -m "$CFWARP_INSTALL_MODE" "$CFWARP_SOURCE" "${CFWARP_DESTINATION}.new.$$"
        mv -f "${CFWARP_DESTINATION}.new.$$" "$CFWARP_DESTINATION"
    else
        chmod "$CFWARP_INSTALL_MODE" "$CFWARP_DESTINATION"
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
    install_file "${SCRIPT_DIR}/cmd/cfwarp" "${INSTALL_PREFIX}/cfwarp" 0755
    if [ "${BIN_DIR}/cfwarp-exec" != "${INSTALL_PREFIX}/cfwarp-exec" ]; then
        ln -sfn "${INSTALL_PREFIX}/cfwarp-exec" "${BIN_DIR}/cfwarp-exec"
    fi
    if [ "${BIN_DIR}/cfwarp" != "${INSTALL_PREFIX}/cfwarp" ]; then
        ln -sfn "${INSTALL_PREFIX}/cfwarp" "${BIN_DIR}/cfwarp"
    fi
    ensure_env_file
    install -d -m 0755 "${INSTALL_PREFIX}/deploy"
    CFWARP_MARKER="${INSTALL_PREFIX}/deploy/installation.env"
    CFWARP_MARKER_TMP=$(mktemp)
    : > "$CFWARP_MARKER_TMP"
    cfwarp_set_env_key CFWARP_ENV_FILE "$ENV_FILE" "$CFWARP_MARKER_TMP"
    cfwarp_set_env_key WG_QUICK_BIN "${BIN_DIR}/wg-quick" "$CFWARP_MARKER_TMP"
    cfwarp_set_env_key MICROSOCKS_BIN "${BIN_DIR}/microsocks" "$CFWARP_MARKER_TMP"
    install_file "$CFWARP_MARKER_TMP" "$CFWARP_MARKER" 0644
    rm -f "$CFWARP_MARKER_TMP"
    render_template "${TEMPLATE_DIR}/cfwarp.service.in" "$SYSTEMD_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-endpoint-refresh.service.in" "$REFRESH_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-endpoint-refresh.timer.in" "$REFRESH_TIMER"
    render_template "${TEMPLATE_DIR}/cfwarp-watchdog.service.in" "$WATCHDOG_UNIT"
    render_template "${TEMPLATE_DIR}/cfwarp-watchdog.timer.in" "$WATCHDOG_TIMER"
}

cleanup_read_unit_state() {
    CFWARP_CLEAN_ACTIVE_STATE=$(systemctl show --property=ActiveState --value "$1") || return 1
    CFWARP_CLEAN_UNIT_RUNNING=1
    case "$CFWARP_CLEAN_ACTIVE_STATE" in
        inactive|failed) CFWARP_CLEAN_UNIT_RUNNING=0 ;;
        '') echo "无法读取 $1 的运行状态，拒绝修改安装。" >&2; return 1 ;;
    esac
}

cleanup_preflight() {
    # A refresh may have temporarily stopped the main service and will restore
    # it when cancelled, so helpers also require --force. This check is read-only.
    if [ "$CFWARP_CLEAN_SYSTEMD" = 1 ] && [ "$FORCE_CLEAN" != 1 ]; then
        for CFWARP_CLEAN_UNIT in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
            # oneshot helpers are activating while their command runs, which
            # systemctl is-active does not recognize as active.
            cleanup_read_unit_state "$CFWARP_CLEAN_UNIT" || return 1
            if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
                echo "$CFWARP_CLEAN_UNIT 正在运行，拒绝清理；请先停止服务或加 --force。" >&2
                return 1
            fi
        done
    fi
}

clean_generated() {
    require_root
    CFWARP_CLEAN_SYSTEMD=0
    if systemd_available; then CFWARP_CLEAN_SYSTEMD=1; fi
    cleanup_preflight || return 1
    acquire_install_lock
    # Another installer may have started a service before this lock was acquired.
    # Recheck before the first stop/disable instead of acting on stale state.
    cleanup_preflight || return 1
    if [ "$CFWARP_CLEAN_SYSTEMD" = 1 ]; then
        systemctl stop cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer >/dev/null 2>&1 || true
        for CFWARP_CLEAN_UNIT in cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
            cleanup_read_unit_state "$CFWARP_CLEAN_UNIT" || return 1
            if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then systemctl stop "$CFWARP_CLEAN_UNIT"; fi
        done
        cleanup_read_unit_state cfwarp.service || return 1
        if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
            systemctl stop cfwarp.service
        fi
        systemctl disable --now cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer >/dev/null 2>&1 || true
        systemctl disable cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service >/dev/null 2>&1 || true
    fi
    rm -f "$SYSTEMD_UNIT" "$REFRESH_UNIT" "$REFRESH_TIMER" "$WATCHDOG_UNIT" "$WATCHDOG_TIMER"
    rm -f "${BIN_DIR}/cfwarp-exec" "${BIN_DIR}/microsocks" "${BIN_DIR}/wg-quick"
    rm -f "${BIN_DIR}/cfwarp" "${INSTALL_PREFIX}/cfwarp"
    rm -f "${INSTALL_PREFIX}/cfwarp-exec" "${INSTALL_PREFIX}/entrypoint.sh" "${INSTALL_PREFIX}/cfwarp-start.sh" "${INSTALL_PREFIX}/cfwarp-stop.sh" "${INSTALL_PREFIX}/cfwarp-netns.sh" "${INSTALL_PREFIX}/cfwarp-refresh-endpoint.sh" "${INSTALL_PREFIX}/cfwarp-healthcheck.sh" "${INSTALL_PREFIX}/cfwarp-watchdog.sh" "${INSTALL_PREFIX}/cfwarp-doctor.sh"
    rm -f "${INSTALL_PREFIX}/lib/cfwarp-common.sh" "${INSTALL_PREFIX}/deploy/installation.env"
    systemd_available && systemctl daemon-reload || true
    echo "已清理 CFwarp 生成物；未删除环境文件和 WARP 数据目录。"
}

reload_and_enable() {
    if ! systemd_available; then
        echo "未检测到运行中的 systemd，已安装文件但未执行 daemon-reload/enable/start。"
        return 0
    fi
    if [ "$SYSTEMD_DIR" != /etc/systemd/system ]; then
        systemctl link "$SYSTEMD_UNIT" "$REFRESH_UNIT" "$REFRESH_TIMER" "$WATCHDOG_UNIT" "$WATCHDOG_TIMER"
    fi
    systemctl daemon-reload
    [ "$ENABLE_SERVICE" = "1" ] && systemctl enable cfwarp.service
    if [ "$ENABLE_REFRESH_TIMER" = "1" ]; then
        systemctl enable --now cfwarp-endpoint-refresh.timer
    fi
    if [ "$ENABLE_WATCHDOG_TIMER" = "1" ]; then
        systemctl enable --now cfwarp-watchdog.timer
    fi
    if [ "$START_SERVICE" = "1" ] || [ "${SERVICE_WAS_ACTIVE:-0}" = 1 ]; then
        if systemctl is-active --quiet cfwarp.service; then
            systemctl restart cfwarp.service
        else
            systemctl start cfwarp.service
        fi
    fi
    for CFWARP_TIMER in ${ACTIVE_TIMERS:-}; do
        systemctl start "$CFWARP_TIMER"
    done
}

stop_upgrade_unit() {
    systemctl stop "$1" || return 1
    cleanup_read_unit_state "$1" || return 1
    if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
        echo "$1 停止后仍处于 ${CFWARP_CLEAN_ACTIVE_STATE}，拒绝替换运行文件。" >&2
        return 1
    fi
}

stop_for_upgrade() {
    SERVICE_WAS_ACTIVE=0
    ACTIVE_TIMERS=
    systemd_available || return 0
    for CFWARP_TIMER in cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer; do
        cleanup_read_unit_state "$CFWARP_TIMER" || return 1
        if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
            ACTIVE_TIMERS="${ACTIVE_TIMERS} $CFWARP_TIMER"
            stop_upgrade_unit "$CFWARP_TIMER" || return 1
        fi
    done
    for CFWARP_UNIT in cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
        cleanup_read_unit_state "$CFWARP_UNIT" || return 1
        if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
            stop_upgrade_unit "$CFWARP_UNIT" || return 1
        fi
    done
    # A cancelled refresh may restore a main service it temporarily stopped.
    # Read its state only after helper stop/cleanup has completed. ActiveState
    # also covers activating/reloading/deactivating, unlike is-active.
    cleanup_read_unit_state cfwarp.service || return 1
    if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
        SERVICE_WAS_ACTIVE=1
        # Only the previous runtime may clean resources using its ownership
        # records. A failed stop blocks upgrade; never compensate by name.
        stop_upgrade_unit cfwarp.service || return 1
    fi
    for CFWARP_UNIT in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
        cleanup_read_unit_state "$CFWARP_UNIT" || return 1
        if [ "$CFWARP_CLEAN_UNIT_RUNNING" = 1 ]; then
            echo "$CFWARP_UNIT 尚未停止，拒绝替换运行文件。" >&2
            return 1
        fi
    done
}

acquire_install_lock() {
    command -v flock >/dev/null 2>&1 || { echo 'flock is required (util-linux).' >&2; return 1; }
    # Keep the private lock under root-owned /run. The shared /run/lock
    # directory and its permissions must remain untouched.
    CFWARP_INSTALL_LOCK_DIR=/run/cfwarp-install
    if [ -L "$CFWARP_INSTALL_LOCK_DIR" ]; then
        echo 'Installation lock directory must not be a symlink.' >&2
        return 1
    fi
    if ! mkdir -m 0700 "$CFWARP_INSTALL_LOCK_DIR" 2>/dev/null; then
        [ -d "$CFWARP_INSTALL_LOCK_DIR" ] && [ ! -L "$CFWARP_INSTALL_LOCK_DIR" ] || return 1
    fi
    CFWARP_INSTALL_LOCK_OWNER=$(stat -c '%u:%a' "$CFWARP_INSTALL_LOCK_DIR" 2>/dev/null || stat -f '%u:%Lp' "$CFWARP_INSTALL_LOCK_DIR") || return 1
    if [ "$CFWARP_INSTALL_LOCK_OWNER" != "$(id -u):700" ]; then
        echo 'Installation lock directory must be owned by the installer user with mode 0700.' >&2
        return 1
    fi
    CFWARP_INSTALL_LOCK_FILE="${CFWARP_INSTALL_LOCK_DIR}/install.lock"
    if [ -L "$CFWARP_INSTALL_LOCK_FILE" ] || { [ -e "$CFWARP_INSTALL_LOCK_FILE" ] && [ ! -f "$CFWARP_INSTALL_LOCK_FILE" ]; }; then
        echo 'Installation lock must be a regular, non-symlink file.' >&2
        return 1
    fi
    CFWARP_INSTALL_PREV_UMASK=$(umask)
    umask 077
    exec 9>>"$CFWARP_INSTALL_LOCK_FILE"
    umask "$CFWARP_INSTALL_PREV_UMASK"
    flock -n 9 || { echo 'Another CFwarp installation is running.' >&2; return 1; }
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
  管理命令: ${BIN_DIR}/cfwarp
  systemd unit: ${SYSTEMD_UNIT}
  健康检查: ${INSTALL_PREFIX}/cfwarp-healthcheck.sh
  自检: ${INSTALL_PREFIX}/cfwarp-doctor.sh

默认模式为 netns-proxy；每日 Endpoint 刷新默认关闭，运行期健康守护默认启用。
如需启动服务，请执行: systemctl start cfwarp.service
EOF
}

if [ "$RUN_DOCTOR" = "1" ]; then
    CFWARP_DOCTOR_SCRIPT="${INSTALL_PREFIX}/cfwarp-doctor.sh"
    [ -f "$CFWARP_DOCTOR_SCRIPT" ] || CFWARP_DOCTOR_SCRIPT="${SCRIPT_DIR}/cfwarp-doctor.sh"
    export CFWARP_ENV_FILE="$ENV_FILE" WG_QUICK_BIN="${BIN_DIR}/wg-quick" MICROSOCKS_BIN="${BIN_DIR}/microsocks"
    if [ "$RUN_DOCTOR_FIX" = "1" ]; then
        exec sh "$CFWARP_DOCTOR_SCRIPT" --fix
    fi
    exec sh "$CFWARP_DOCTOR_SCRIPT"
fi
if [ "$RUN_CLEAN_GENERATED" = "1" ]; then
    validate_paths
    clean_generated
    exit 0
fi

require_root
validate_paths
install_deps
acquire_install_lock
cfwarp_parse_env "$ENV_TEMPLATE" >/dev/null
if [ -f "$ENV_FILE" ]; then cfwarp_parse_env "$ENV_FILE" >/dev/null; fi
for CFWARP_SOURCE_SCRIPT in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR/cfwarp-exec" "$SCRIPT_DIR/lib/cfwarp-common.sh"; do
    sh -n "$CFWARP_SOURCE_SCRIPT"
done
trap cleanup_install_temporary_files EXIT
trap 'exit 143' HUP INT TERM
build_microsocks
stop_for_upgrade
publish_microsocks
install_private_wg_quick
install_runtime_files
reload_and_enable
print_summary
