#!/bin/sh
set -e

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)

INSTALL_PREFIX="/opt/microwarp"
ENV_DIR="/etc/microwarp"
SYSTEMD_DIR="/etc/systemd/system"
BIN_DIR="/usr/local/bin"

ENABLE_SERVICE=1
START_SERVICE=0
SKIP_DEPS=0
SKIP_BUILD=0
SKIP_PATCH_WG_QUICK=0

usage() {
    cat <<EOF
用法: ./install.sh [选项]

选项:
  --prefix PATH               安装运行文件目录，默认 /opt/microwarp
  --env-dir PATH              环境变量目录，默认 /etc/microwarp
  --systemd-dir PATH          systemd unit 目录，默认 /etc/systemd/system
  --bin-dir PATH              二进制安装目录，默认 /usr/local/bin
  --skip-deps                 跳过系统依赖安装
  --skip-build                跳过 microsocks 编译，要求目标目录中已存在 microsocks
  --skip-patch-wg-quick       跳过私有 wg-quick 兼容性补丁
  --no-enable                 不执行 systemd enable
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
        --systemd-dir)
            SYSTEMD_DIR=$2
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

ENV_FILE="${ENV_DIR}/microwarp.env"
SYSTEMD_UNIT="${SYSTEMD_DIR}/microwarp.service"

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

write_systemd_unit() {
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=MicroWARP SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
WorkingDirectory=${INSTALL_PREFIX}
ExecStart=${INSTALL_PREFIX}/microwarp-start.sh
ExecStopPost=${INSTALL_PREFIX}/microwarp-stop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_runtime_files() {
    install -d "$INSTALL_PREFIX" "$ENV_DIR" "$SYSTEMD_DIR" "$BIN_DIR"
    install -m 0755 "${SCRIPT_DIR}/entrypoint.sh" "${INSTALL_PREFIX}/entrypoint.sh"
    install -m 0755 "${SCRIPT_DIR}/microwarp-netns.sh" "${INSTALL_PREFIX}/microwarp-netns.sh"
    install -m 0755 "${SCRIPT_DIR}/microwarp-start.sh" "${INSTALL_PREFIX}/microwarp-start.sh"
    install -m 0755 "${SCRIPT_DIR}/microwarp-stop.sh" "${INSTALL_PREFIX}/microwarp-stop.sh"
    sed "s|__MICROWARP_ENV_FILE__|${ENV_FILE}|g" "${SCRIPT_DIR}/microwarp-exec" > "${BIN_DIR}/microwarp-exec"
    chmod 0755 "${BIN_DIR}/microwarp-exec"

    if [ ! -f "$ENV_FILE" ]; then
        install -m 0600 "${SCRIPT_DIR}/deploy/microwarp.env.example" "$ENV_FILE"
    fi

    write_systemd_unit
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
        systemctl enable microwarp.service
    fi

    if [ "$START_SERVICE" = "1" ]; then
        systemctl restart microwarp.service
    fi
}

print_summary() {
    cat <<EOF
MicroWARP 裸机部署文件已安装完成:
  运行目录: ${INSTALL_PREFIX}
  环境文件: ${ENV_FILE}
  服务文件: ${SYSTEMD_UNIT}
  MicroSOCKS: ${BIN_DIR}/microsocks
  命令执行助手: ${BIN_DIR}/microwarp-exec
  私有 wg-quick: ${INSTALL_PREFIX}/bin/wg-quick

默认推荐模式是 netns-proxy，只在独立 namespace 内接管 WARP。
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
