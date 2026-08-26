# Shared POSIX-shell helpers for CFwarp.
# This file is sourced by the entry points; it is not intended to be executed.

cfwarp_default_env_file() {
    CFWARP_COMMON_SCRIPT_DIR=${1:-}
    if [ -n "${CFWARP_ENV_FILE:-}" ]; then
        printf '%s\n' "$CFWARP_ENV_FILE"
    elif [ -f /etc/cfwarp/cfwarp.env ]; then
        printf '%s\n' /etc/cfwarp/cfwarp.env
    elif [ -n "$CFWARP_COMMON_SCRIPT_DIR" ] && [ -f "$CFWARP_COMMON_SCRIPT_DIR/deploy/local/cfwarp.env" ]; then
        # Development/upgrade fallback. This directory is ignored by Git.
        printf '%s\n' "$CFWARP_COMMON_SCRIPT_DIR/deploy/local/cfwarp.env"
    else
        printf '%s\n' /etc/cfwarp/cfwarp.env
    fi
}

cfwarp_is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

cfwarp_validate_uint() {
    CFWARP_COMMON_VALUE=${1:-}
    CFWARP_COMMON_LABEL=${2:-value}
    CFWARP_COMMON_MIN=${3:-0}
    CFWARP_COMMON_MAX=${4:-2147483647}
    if ! cfwarp_is_uint "$CFWARP_COMMON_VALUE" || \
       [ "$CFWARP_COMMON_VALUE" -lt "$CFWARP_COMMON_MIN" ] 2>/dev/null || \
       [ "$CFWARP_COMMON_VALUE" -gt "$CFWARP_COMMON_MAX" ] 2>/dev/null; then
        echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 必须是 ${CFWARP_COMMON_MIN}-${CFWARP_COMMON_MAX} 的整数。" >&2
        return 1
    fi
}

cfwarp_validate_port() {
    cfwarp_validate_uint "${1:-}" "${2:-port}" 1 65535
}

cfwarp_validate_link_name() {
    CFWARP_COMMON_NAME=${1:-}
    CFWARP_COMMON_LABEL=${2:-link}
    if [ -z "$CFWARP_COMMON_NAME" ] || [ "${#CFWARP_COMMON_NAME}" -gt 15 ]; then
        echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 不能为空且不能超过 15 个字符。" >&2
        return 1
    fi
    case "$CFWARP_COMMON_NAME" in
        *[!A-Za-z0-9_.-]*)
            echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 含有非法字符: ${CFWARP_COMMON_NAME}" >&2
            return 1
            ;;
    esac
}

cfwarp_validate_netns_name() {
    CFWARP_COMMON_NAME=${1:-}
    CFWARP_COMMON_LABEL=${2:-namespace}
    if [ -z "$CFWARP_COMMON_NAME" ] || [ "${#CFWARP_COMMON_NAME}" -gt 63 ]; then
        echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 不能为空且不能超过 63 个字符。" >&2
        return 1
    fi
    case "$CFWARP_COMMON_NAME" in
        *[!A-Za-z0-9_.-]*)
            echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 含有非法字符: ${CFWARP_COMMON_NAME}" >&2
            return 1
            ;;
    esac
}

cfwarp_validate_chain_name() {
    CFWARP_COMMON_NAME=${1:-}
    CFWARP_COMMON_LABEL=${2:-iptables chain}
    if [ -z "$CFWARP_COMMON_NAME" ] || [ "${#CFWARP_COMMON_NAME}" -gt 28 ]; then
        echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 不能为空且不能超过 28 个字符。" >&2
        return 1
    fi
    case "$CFWARP_COMMON_NAME" in
        *[!A-Za-z0-9_.-]*)
            echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 含有非法字符: ${CFWARP_COMMON_NAME}" >&2
            return 1
            ;;
    esac
}

cfwarp_validate_endpoint() {
    CFWARP_COMMON_ENDPOINT=${1:-}
    case "$CFWARP_COMMON_ENDPOINT" in
        ''|*[[:space:]]*|*[![:print:]]*)
            return 1
            ;;
        \[*\]:*)
            CFWARP_COMMON_HOST=${CFWARP_COMMON_ENDPOINT#\[}
            CFWARP_COMMON_HOST=${CFWARP_COMMON_HOST%%\]:*}
            CFWARP_COMMON_PORT=${CFWARP_COMMON_ENDPOINT##*:}
            [ -n "$CFWARP_COMMON_HOST" ] || return 1
            ;;
        *:*)
            case "$CFWARP_COMMON_ENDPOINT" in
                *:*:*) return 1 ;;
            esac
            CFWARP_COMMON_HOST=${CFWARP_COMMON_ENDPOINT%:*}
            CFWARP_COMMON_PORT=${CFWARP_COMMON_ENDPOINT##*:}
            [ -n "$CFWARP_COMMON_HOST" ] || return 1
            ;;
        *)
            return 1
            ;;
    esac
    cfwarp_validate_port "$CFWARP_COMMON_PORT" endpoint >/dev/null 2>&1
}

cfwarp_format_socks_proxy_url() {
    CFWARP_COMMON_HOST=$1
    CFWARP_COMMON_PORT=$2
    case "$CFWARP_COMMON_HOST" in
        \[*\])
            printf 'socks5h://%s:%s\n' "$CFWARP_COMMON_HOST" "$CFWARP_COMMON_PORT"
            ;;
        *:*)
            printf 'socks5h://[%s]:%s\n' "$CFWARP_COMMON_HOST" "$CFWARP_COMMON_PORT"
            ;;
        *)
            printf 'socks5h://%s:%s\n' "$CFWARP_COMMON_HOST" "$CFWARP_COMMON_PORT"
            ;;
    esac
}

cfwarp_is_wildcard_bind() {
    case "${1:-}" in
        ''|0.0.0.0|::|\[::\]) return 0 ;;
        *) return 1 ;;
    esac
}

cfwarp_set_env_key() {
    CFWARP_COMMON_KEY=$1
    CFWARP_COMMON_VALUE=$2
    CFWARP_COMMON_FILE=$3
    CFWARP_COMMON_TMP=$(mktemp "${CFWARP_COMMON_FILE}.tmp.XXXXXX") || return 1
    if ! awk -v key="$CFWARP_COMMON_KEY" -v value="$CFWARP_COMMON_VALUE" '
        BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*="; found = 0 }
        $0 ~ pattern { print key "=" value; found = 1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$CFWARP_COMMON_FILE" > "$CFWARP_COMMON_TMP"; then
        rm -f "$CFWARP_COMMON_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_COMMON_TMP"
    mv "$CFWARP_COMMON_TMP" "$CFWARP_COMMON_FILE"
}

cfwarp_remove_env_key() {
    CFWARP_COMMON_KEY=$1
    CFWARP_COMMON_FILE=$2
    CFWARP_COMMON_TMP=$(mktemp "${CFWARP_COMMON_FILE}.tmp.XXXXXX") || return 1
    if ! awk -v key="$CFWARP_COMMON_KEY" '
        BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*=" }
        $0 !~ pattern { print }
    ' "$CFWARP_COMMON_FILE" > "$CFWARP_COMMON_TMP"; then
        rm -f "$CFWARP_COMMON_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_COMMON_TMP"
    mv "$CFWARP_COMMON_TMP" "$CFWARP_COMMON_FILE"
}

cfwarp_atomic_write_from_stdin() {
    CFWARP_COMMON_FILE=$1
    CFWARP_COMMON_DIR=$(dirname "$CFWARP_COMMON_FILE")
    CFWARP_COMMON_TMP=$(mktemp "${CFWARP_COMMON_FILE}.tmp.XXXXXX") || return 1
    if ! cat > "$CFWARP_COMMON_TMP"; then
        rm -f "$CFWARP_COMMON_TMP"
        return 1
    fi
    chmod 0600 "$CFWARP_COMMON_TMP"
    mv "$CFWARP_COMMON_TMP" "$CFWARP_COMMON_FILE"
}

cfwarp_command_exists() {
    command -v "$1" >/dev/null 2>&1
}
