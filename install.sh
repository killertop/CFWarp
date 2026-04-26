#!/bin/sh
set -e

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

INSTALL_PREFIX="${SCRIPT_DIR}"
DATA_DIR=""
ENV_DIR=""
SYSTEMD_DIR=""
SYSTEMD_LINK_DIR="/etc/systemd/system"
BIN_DIR=""

ENABLE_SERVICE=1
ENABLE_REFRESH_TIMER=0
START_SERVICE=0
SKIP_DEPS=0
SKIP_BUILD=0
SKIP_PATCH_WG_QUICK=0

usage() {
    cat <<EOF
用法: ./install.sh [选项]

选项:
  --prefix PATH               安装根目录，默认当前仓库目录
  --data-dir PATH             WARP 持久化状态目录，默认 <prefix>/var
  --env-dir PATH              环境变量目录，默认 <prefix>/deploy/local
  --systemd-dir PATH          systemd unit 生成目录，默认 <prefix>/deploy/systemd
  --systemd-link-dir PATH     systemd 链接目录，默认 /etc/systemd/system
  --bin-dir PATH              二进制安装目录，默认 <prefix>/bin
  --skip-deps                 跳过系统依赖安装
  --skip-build                跳过 microsocks 编译，要求目标目录中已存在 microsocks
  --skip-patch-wg-quick       跳过私有 wg-quick 兼容性补丁
  --no-enable                 不执行 systemd enable
  --enable-refresh-timer      额外启用并启动每日 Endpoint 刷新定时器
  --start                     安装完成后立即启动服务
  -h, --help                  显示帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            INSTALL_PREFIX=$2
            shift 2
            ;;
        --env-dir)
            ENV_DIR=$2
            shift 2
            ;;
        --data-dir)
            DATA_DIR=$2
            shift 2
            ;;
        --systemd-dir)
            SYSTEMD_DIR=$2
            shift 2
            ;;
        --systemd-link-dir)
            SYSTEMD_LINK_DIR=$2
            shift 2
            ;;
        --bin-dir)
            BIN_DIR=$2
            shift 2
            ;;
        --skip-deps)
            SKIP_DEPS=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --skip-patch-wg-quick)
            SKIP_PATCH_WG_QUICK=1
            shift
            ;;
        --no-enable)
            ENABLE_SERVICE=0
            shift
            ;;
        --enable-refresh-timer)
            ENABLE_REFRESH_TIMER=1
            shift
            ;;
        --start)
            START_SERVICE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[ -n "$DATA_DIR" ] || DATA_DIR="${INSTALL_PREFIX}/var"
[ -n "$ENV_DIR" ] || ENV_DIR="${INSTALL_PREFIX}/deploy/local"
[ -n "$SYSTEMD_DIR" ] || SYSTEMD_DIR="${INSTALL_PREFIX}/deploy/systemd"
[ -n "$BIN_DIR" ] || BIN_DIR="${INSTALL_PREFIX}/bin"

ENV_FILE="${ENV_DIR}/cfwarp.env"
LEGACY_ENV_LINK="${ENV_DIR}/microwarp.env"
SYSTEMD_UNIT="${SYSTEMD_DIR}/cfwarp.service"
REFRESH_SYSTEMD_UNIT="${SYSTEMD_DIR}/cfwarp-endpoint-refresh.service"
REFRESH_TIMER_UNIT="${SYSTEMD_DIR}/cfwarp-endpoint-refresh.timer"
SYSTEMD_LINK="${SYSTEMD_LINK_DIR}/cfwarp.service"
LEGACY_SYSTEMD_LINK="${SYSTEMD_LINK_DIR}/microwarp.service"
REFRESH_SYSTEMD_LINK="${SYSTEMD_LINK_DIR}/cfwarp-endpoint-refresh.service"
REFRESH_TIMER_LINK="${SYSTEMD_LINK_DIR}/cfwarp-endpoint-refresh.timer"
EXEC_FILE="${BIN_DIR}/cfwarp-exec"
REFRESH_EXEC_FILE="${INSTALL_PREFIX}/cfwarp-refresh-endpoint.sh"
LEGACY_EXEC_LINK="${BIN_DIR}/microwarp-exec"
ENV_TEMPLATE="${SCRIPT_DIR}/deploy/cfwarp.env.example"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行安装脚本。" >&2
        exit 1
    fi
}

install_deps() {
    if [ "$SKIP_DEPS" = "1" ]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ca-certificates curl wget git build-essential wireguard-tools iproute2 iptables
        return
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl wget git build-base wireguard-tools iproute2 iptables
        return
    fi

    echo "当前仅自动支持 apt-get 和 apk。请手动安装: ca-certificates curl wget git gcc make wireguard-tools iproute/iproute2 iptables" >&2
    exit 1
}

build_microsocks() {
    if [ "$SKIP_BUILD" = "1" ]; then
        if [ ! -x "${BIN_DIR}/microsocks" ]; then
            echo "已跳过编译，但 ${BIN_DIR}/microsocks 不存在或不可执行。" >&2
            exit 1
        fi
        return
    fi

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

    git clone --depth 1 https://github.com/rofl0r/microsocks.git "${TMP_DIR}/microsocks"
    (
        cd "${TMP_DIR}/microsocks"
        make CFLAGS="-O3 -flto"
        install -d "$BIN_DIR"
        install -m 0755 microsocks "${BIN_DIR}/microsocks"
    )

    rm -rf "$TMP_DIR"
    trap - EXIT HUP INT TERM
}

install_private_wg_quick() {
    WG_QUICK_SRC=$(command -v wg-quick 2>/dev/null || true)
    if [ -z "$WG_QUICK_SRC" ]; then
        echo "未找到 wg-quick，请先安装 wireguard-tools。" >&2
        exit 1
    fi

    install -d "${INSTALL_PREFIX}/bin"
    install -m 0755 "$WG_QUICK_SRC" "${INSTALL_PREFIX}/bin/wg-quick"

    if [ "$SKIP_PATCH_WG_QUICK" != "1" ]; then
        sed -i '/src_valid_mark/d' "${INSTALL_PREFIX}/bin/wg-quick"
    fi
}

set_env_key() {
    KEY=$1
    VALUE=$2
    FILE=$3
    if grep -q "^${KEY}=" "$FILE" 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$FILE"
    fi
}

rename_env_key() {
    OLD_KEY=$1
    NEW_KEY=$2
    FILE=$3
    VALUE=$(sed -n "s/^${OLD_KEY}=//p" "$FILE" | tail -n 1)
    if [ -n "$VALUE" ]; then
        set_env_key "$NEW_KEY" "$VALUE" "$FILE"
        sed -i "/^${OLD_KEY}=/d" "$FILE"
    fi
}

replace_default_env_value() {
    KEY=$1
    OLD_VALUE=$2
    NEW_VALUE=$3
    FILE=$4
    VALUE=$(sed -n "s/^${KEY}=//p" "$FILE" | tail -n 1)
    if [ -z "$VALUE" ] || [ "$VALUE" = "$OLD_VALUE" ]; then
        set_env_key "$KEY" "$NEW_VALUE" "$FILE"
    fi
}

ensure_env_file() {
    LEGACY_ENV_FILE_SYSTEM="/etc/microwarp/microwarp.env"
    LEGACY_ENV_FILE_LOCAL="${ENV_DIR}/microwarp.env"

    if [ ! -f "$ENV_FILE" ]; then
        if [ "$ENV_FILE" != "$LEGACY_ENV_FILE_LOCAL" ] && [ -f "$LEGACY_ENV_FILE_LOCAL" ]; then
            cp "$LEGACY_ENV_FILE_LOCAL" "$ENV_FILE"
        elif [ "$ENV_FILE" != "$LEGACY_ENV_FILE_SYSTEM" ] && [ -f "$LEGACY_ENV_FILE_SYSTEM" ]; then
            cp "$LEGACY_ENV_FILE_SYSTEM" "$ENV_FILE"
        else
            sed "s|__CFWARP_DATA_DIR__|${DATA_DIR}|g" "$ENV_TEMPLATE" > "$ENV_FILE"
        fi
    else
        sed -i "s|__CFWARP_DATA_DIR__|${DATA_DIR}|g" "$ENV_FILE"
    fi

    rename_env_key MICROWARP_MODE CFWARP_MODE "$ENV_FILE"
    rename_env_key MICROWARP_DATA_DIR CFWARP_DATA_DIR "$ENV_FILE"
    rename_env_key MICROWARP_STATE_DIR CFWARP_STATE_DIR "$ENV_FILE"
    rename_env_key MICROWARP_TEST_MODE CFWARP_TEST_MODE "$ENV_FILE"
    sed -i "s|/var/lib/microwarp|${DATA_DIR}|g" "$ENV_FILE"
    set_env_key CFWARP_DATA_DIR "$DATA_DIR" "$ENV_FILE"
    replace_default_env_value NETNS_NAME microwarp cfwarp "$ENV_FILE"
    replace_default_env_value NETNS_HOST_IF microwarp-host cfwarp-host "$ENV_FILE"
    replace_default_env_value NETNS_NS_IF microwarp-ns cfwarp-ns "$ENV_FILE"
    sed -i '/^WG_CONF_DIR=/d' "$ENV_FILE"
    sed -i '/^MICROWARP_DATA_DIR=/d;/^MICROWARP_MODE=/d;/^MICROWARP_STATE_DIR=/d;/^MICROWARP_TEST_MODE=/d' "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
}

migrate_legacy_data() {
    LEGACY_DATA_DIR="/var/lib/microwarp"

    install -d "$DATA_DIR"
    if [ "$DATA_DIR" = "$LEGACY_DATA_DIR" ]; then
        return
    fi

    if [ -d "$LEGACY_DATA_DIR" ] && [ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
        cp -a "${LEGACY_DATA_DIR}/." "$DATA_DIR/"
    fi
}

write_systemd_unit() {
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=CFwarp SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${INSTALL_PREFIX}
ExecStart=/bin/sh ${INSTALL_PREFIX}/cfwarp-start.sh
ExecStopPost=/bin/sh ${INSTALL_PREFIX}/cfwarp-stop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_refresh_systemd_unit() {
    cat > "$REFRESH_SYSTEMD_UNIT" <<EOF
[Unit]
Description=CFwarp Endpoint Refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${INSTALL_PREFIX}
ExecStart=/bin/sh ${INSTALL_PREFIX}/cfwarp-refresh-endpoint.sh
EOF
}

write_refresh_timer_unit() {
    cat > "$REFRESH_TIMER_UNIT" <<EOF
[Unit]
Description=Run CFwarp endpoint refresh daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
Unit=cfwarp-endpoint-refresh.service

[Install]
WantedBy=timers.target
EOF
}

install_script_if_needed() {
    SRC=$1
    DST=$2
    if [ "$SRC" = "$DST" ]; then
        return 0
    fi
    install -m 0755 "$SRC" "$DST"
}

install_runtime_files() {
    install -d "$INSTALL_PREFIX" "$DATA_DIR" "$ENV_DIR" "$SYSTEMD_DIR" "$SYSTEMD_LINK_DIR" "$BIN_DIR"
    install_script_if_needed "${SCRIPT_DIR}/entrypoint.sh" "${INSTALL_PREFIX}/entrypoint.sh"
    install_script_if_needed "${SCRIPT_DIR}/cfwarp-netns.sh" "${INSTALL_PREFIX}/cfwarp-netns.sh"
    install_script_if_needed "${SCRIPT_DIR}/cfwarp-start.sh" "${INSTALL_PREFIX}/cfwarp-start.sh"
    install_script_if_needed "${SCRIPT_DIR}/cfwarp-stop.sh" "${INSTALL_PREFIX}/cfwarp-stop.sh"
    install_script_if_needed "${SCRIPT_DIR}/cfwarp-refresh-endpoint.sh" "$REFRESH_EXEC_FILE"
    install_script_if_needed "${SCRIPT_DIR}/microwarp-netns.sh" "${INSTALL_PREFIX}/microwarp-netns.sh"
    install_script_if_needed "${SCRIPT_DIR}/microwarp-start.sh" "${INSTALL_PREFIX}/microwarp-start.sh"
    install_script_if_needed "${SCRIPT_DIR}/microwarp-stop.sh" "${INSTALL_PREFIX}/microwarp-stop.sh"
    sed "s|__CFWARP_ENV_FILE__|${ENV_FILE}|g" "${SCRIPT_DIR}/cfwarp-exec" > "$EXEC_FILE"
    chmod 0755 "$EXEC_FILE"
    ln -sfn "$EXEC_FILE" "$LEGACY_EXEC_LINK"
    migrate_legacy_data
    ensure_env_file
    ln -sfn "$ENV_FILE" "$LEGACY_ENV_LINK"
    write_systemd_unit
    write_refresh_systemd_unit
    write_refresh_timer_unit
    ln -sfn "$SYSTEMD_UNIT" "$SYSTEMD_LINK"
    ln -sfn "$SYSTEMD_UNIT" "$LEGACY_SYSTEMD_LINK"
    ln -sfn "$REFRESH_SYSTEMD_UNIT" "$REFRESH_SYSTEMD_LINK"
    ln -sfn "$REFRESH_TIMER_UNIT" "$REFRESH_TIMER_LINK"
}

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

reload_and_enable_service() {
    if ! systemd_available; then
        echo "未检测到运行中的 systemd，已写入服务文件但未执行 daemon-reload/enable/start。"
        return
    fi

    systemctl daemon-reload

    if [ "$ENABLE_SERVICE" = "1" ]; then
        systemctl enable cfwarp.service
    fi

    if [ "$ENABLE_REFRESH_TIMER" = "1" ]; then
        systemctl enable --now cfwarp-endpoint-refresh.timer
    fi

    if [ "$START_SERVICE" = "1" ]; then
        systemctl restart cfwarp.service
    fi
}

print_summary() {
    cat <<EOF
CFwarp 裸机部署文件已安装完成:
  运行目录: ${INSTALL_PREFIX}
  持久化目录: ${DATA_DIR}
  环境文件: ${ENV_FILE}
  服务文件: ${SYSTEMD_UNIT}
  Endpoint 刷新服务: ${REFRESH_SYSTEMD_UNIT}
  Endpoint 刷新定时器: ${REFRESH_TIMER_UNIT}
  systemd 链接: ${SYSTEMD_LINK}
  MicroSOCKS: ${BIN_DIR}/microsocks
  命令执行助手: ${EXEC_FILE}
  私有 wg-quick: ${INSTALL_PREFIX}/bin/wg-quick

默认推荐模式是 netns-proxy，只在独立 namespace 内接管 WARP。
每日自动 Endpoint 选择默认不会自动启用；如需启用，请手动执行:
  systemctl enable --now cfwarp-endpoint-refresh.timer
建议先检查并编辑 ${ENV_FILE}，确认代理地址和模式，再启动服务。
EOF
}

require_root
install_deps
build_microsocks
install_private_wg_quick
install_runtime_files
reload_and_enable_service
print_summary
