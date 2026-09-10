# Shared POSIX-shell helpers for CFwarp.
# shellcheck shell=sh
# This file is sourced by the entry points; it is not intended to be executed.

cfwarp_default_env_file() {
    CFWARP_COMMON_SCRIPT_DIR=${1:-}
    if [ -n "${CFWARP_ENV_FILE:-}" ]; then
        printf '%s\n' "$CFWARP_ENV_FILE"
    elif [ -n "$CFWARP_COMMON_SCRIPT_DIR" ] && [ -r "$CFWARP_COMMON_SCRIPT_DIR/deploy/installation.env" ]; then
        cfwarp_read_env_key CFWARP_ENV_FILE "$CFWARP_COMMON_SCRIPT_DIR/deploy/installation.env"
    elif [ -f /etc/cfwarp/cfwarp.env ]; then
        printf '%s\n' /etc/cfwarp/cfwarp.env
    elif [ -n "$CFWARP_COMMON_SCRIPT_DIR" ] && [ -f "$CFWARP_COMMON_SCRIPT_DIR/deploy/local/cfwarp.env" ]; then
        # Development/upgrade fallback. This directory is ignored by Git.
        printf '%s\n' "$CFWARP_COMMON_SCRIPT_DIR/deploy/local/cfwarp.env"
    else
        printf '%s\n' /etc/cfwarp/cfwarp.env
    fi
}

# Read a deliberately small EnvironmentFile-compatible grammar as data, never
# as shell code. Values are single-line literals (optionally quoted); expansion,
# command execution and multiline shell programs are not supported.
cfwarp_parse_env() {
    awk '
        function bad() { print "Invalid environment assignment at line " NR > "/dev/stderr"; failed=1; exit 1 }
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        {
            line=$0; sub(/\r$/, "", line)
            if (line ~ /^[ \t]*(#|$)/) next
            pos=index(line,"="); if (!pos) bad()
            key=trim(substr(line,1,pos-1)); value=trim(substr(line,pos+1))
            if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) bad()
            q=substr(value,1,1); out=""
            if (q == "\"" || q == sprintf("%c",39)) {
                closed=0
                for (i=2;i<=length(value);i++) {
                    c=substr(value,i,1)
                    if (c == q) { closed=1; rest=trim(substr(value,i+1)); if (rest != "" && substr(rest,1,1) != "#") bad(); break }
                    if (q == "\"" && c == "\\") {
                        i++; if (i>length(value)) bad()
                        c=substr(value,i,1)
                        if (c != "\\" && c != "\"" && c != "$" && c != "`") bad()
                    }
                    out=out c
                }
                if (!closed) bad()
            } else {
                sub(/[ \t]+#.*/, "", value); value=trim(value)
                if (value ~ /[ \t\\]/ || index(value,"\"") || index(value,sprintf("%c",39))) bad()
                out=value
            }
            if (out ~ /[[:cntrl:]]/) bad()
            values[key]=out; if (!seen[key]++) keys[++n]=key
        }
        END { if (!failed) for (i=1;i<=n;i++) print keys[i] "=" values[keys[i]] }
    ' "$1"
}

cfwarp_read_env_key() {
    CFWARP_READ_KEY=$1
    CFWARP_READ_TMP=$(mktemp) || return 1
    if ! cfwarp_parse_env "$2" > "$CFWARP_READ_TMP"; then rm -f "$CFWARP_READ_TMP"; return 1; fi
    awk -v key="$CFWARP_READ_KEY" 'index($0,key "=")==1 { print substr($0,length(key)+2); found=1 } END { if (!found) exit 1 }' "$CFWARP_READ_TMP"
    CFWARP_READ_STATUS=$?
    rm -f "$CFWARP_READ_TMP"
    return "$CFWARP_READ_STATUS"
}

cfwarp_import_env() {
    CFWARP_IMPORT_TMP=$(mktemp) || return 1
    if ! cfwarp_parse_env "$1" > "$CFWARP_IMPORT_TMP"; then rm -f "$CFWARP_IMPORT_TMP"; return 1; fi
    while IFS= read -r CFWARP_IMPORT_ASSIGNMENT; do
        CFWARP_IMPORT_KEY=${CFWARP_IMPORT_ASSIGNMENT%%=*}
        # Preserve inherited values, including explicitly empty values.
        if ! printenv "$CFWARP_IMPORT_KEY" >/dev/null 2>&1; then
            export "${CFWARP_IMPORT_ASSIGNMENT?}"
        fi
    done < "$CFWARP_IMPORT_TMP"
    rm -f "$CFWARP_IMPORT_TMP"
}

cfwarp_load_env() {
    [ "${CFWARP_ENV_LOADED:-0}" = 1 ] && return 0
    CFWARP_LOAD_DIR=$1
    CFWARP_ENV_FILE=$(cfwarp_default_env_file "$CFWARP_LOAD_DIR") || return 1
    export CFWARP_ENV_FILE
    if [ -r "$CFWARP_ENV_FILE" ]; then
        cfwarp_import_env "$CFWARP_ENV_FILE" || return 1
    elif [ -e "$CFWARP_ENV_FILE" ]; then
        echo "==> [ERROR] Environment file is not readable: $CFWARP_ENV_FILE" >&2
        return 1
    fi
    if [ -r "$CFWARP_LOAD_DIR/deploy/installation.env" ]; then
        cfwarp_import_env "$CFWARP_LOAD_DIR/deploy/installation.env" || return 1
    fi
    CFWARP_ENV_LOADED=1
    export CFWARP_ENV_LOADED
}

# Main startup and endpoint refresh share fd 6 for their whole network lifetime.
# The data directory is root-controlled, as are the existing private profiles.
cfwarp_lifecycle_lock() {
    case "$1" in /*) ;; *) echo '==> [ERROR] 生命周期数据目录必须为绝对路径。' >&2; return 1 ;; esac
    command -v flock >/dev/null 2>&1 || return 1
    install -d -m 0700 "$1" || return 1
    CFWARP_LIFECYCLE_DIR=$(CDPATH='' cd -- "$1" && pwd -P) || return 1
    CFWARP_REFRESH_PENDING="$CFWARP_LIFECYCLE_DIR/.refresh-pending"
    CFWARP_LIFECYCLE_FILE="$CFWARP_LIFECYCLE_DIR/.service-probe.lock"
    [ ! -L "$CFWARP_LIFECYCLE_FILE" ] || return 1
    exec 6>>"$CFWARP_LIFECYCLE_FILE"
    if ! flock -n 6; then
        exec 6>&-
        echo '==> [ERROR] 主服务或 Endpoint 刷新正在使用此数据目录，拒绝并发启动。' >&2
        return 1
    fi
}

cfwarp_lifecycle_unlock() {
    flock -u 6 || return 1
    exec 6>&-
}

cfwarp_refresh_is_clear() {
    if [ -e "$CFWARP_REFRESH_PENDING" ] || [ -L "$CFWARP_REFRESH_PENDING" ]; then
        echo "==> [ERROR] 刷新恢复尚未完成，拒绝启动或再次探测；请检查 ${CFWARP_REFRESH_PENDING}。" >&2
        return 1
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
    if ! awk -v v="$CFWARP_COMMON_VALUE" -v lo="$CFWARP_COMMON_MIN" -v hi="$CFWARP_COMMON_MAX" '
        function compare(a,b) {
            sub(/^0+/, "", a); sub(/^0+/, "", b)
            if (length(a) != length(b)) return length(a) < length(b) ? -1 : 1
            return "x" a == "x" b ? 0 : ("x" a < "x" b ? -1 : 1)
        }
        BEGIN { exit !(v ~ /^[0-9]+$/ && compare(v,lo)>=0 && compare(v,hi)<=0) }'; then
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
        .|..|-*|*[!A-Za-z0-9_.-]*)
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
        .|..|-*|*[!A-Za-z0-9_.-]*)
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
        .|..|-*|*[!A-Za-z0-9_.-]*)
            echo "==> [ERROR] ${CFWARP_COMMON_LABEL} 含有非法字符: ${CFWARP_COMMON_NAME}" >&2
            return 1
            ;;
    esac
}

cfwarp_validate_ipv6() {
    printf '%s\n' "$1" | awk '
        function groups(s, parts, n, i) {
            if (s == "") return 0
            n=split(s,parts,":")
            for(i=1;i<=n;i++) if(parts[i] !~ /^[0-9A-Fa-f]+$/ || length(parts[i])>4) return -100
            return n
        }
        {
            value=$0
            if (value == "" || value ~ /[^0-9A-Fa-f:.]/ || value ~ /:::/) exit 1
            if (index(value,".")) {
                tail=value; sub(/^.*:/,"",tail)
                if (tail == value || split(tail,octets,".") != 4) exit 1
                for(i=1;i<=4;i++) if(octets[i] !~ /^[0-9]+$/ || octets[i]>255 || (length(octets[i])>1 && octets[i] ~ /^0/)) exit 1
                value=substr(value,1,length(value)-length(tail)) "0:0"
            }
            if (index(value,"::")) {
                if (split(value,halves,"::") != 2) exit 1
                left=groups(halves[1]); right=groups(halves[2])
                if(left<0 || right<0 || left+right>=8) exit 1
            } else if(groups(value) != 8) exit 1
        }
        END {if(NR != 1) exit 1}
    '
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
            [ "$CFWARP_COMMON_ENDPOINT" = "[$CFWARP_COMMON_HOST]:$CFWARP_COMMON_PORT" ] || return 1
            [ -n "$CFWARP_COMMON_HOST" ] || return 1
            case "$CFWARP_COMMON_HOST" in *[!0-9A-Fa-f:.]*|*..*) return 1 ;; esac
            case "$CFWARP_COMMON_HOST" in *:*) ;; *) return 1 ;; esac
            cfwarp_validate_ipv6 "$CFWARP_COMMON_HOST" || return 1
            ;;
        *:*)
            case "$CFWARP_COMMON_ENDPOINT" in
                *:*:*) return 1 ;;
            esac
            CFWARP_COMMON_HOST=${CFWARP_COMMON_ENDPOINT%:*}
            CFWARP_COMMON_PORT=${CFWARP_COMMON_ENDPOINT##*:}
            [ -n "$CFWARP_COMMON_HOST" ] || return 1
            case "$CFWARP_COMMON_HOST" in -*|.*|*..*|*[!A-Za-z0-9.-]*) return 1 ;; esac
            ;;
        *)
            return 1
            ;;
    esac
    cfwarp_validate_port "$CFWARP_COMMON_PORT" endpoint >/dev/null 2>&1
}

# Resolve control-plane endpoints before entering the fail-closed namespace.
# Domain endpoints use host IPv4 DNS; literal addresses never require DNS.
cfwarp_resolve_endpoint() (
    CFWARP_RESOLVE_ENDPOINT=$1
    cfwarp_validate_endpoint "$CFWARP_RESOLVE_ENDPOINT" || return 1
    case "$CFWARP_RESOLVE_ENDPOINT" in
        \[*\]:*) printf '%s\n' "$CFWARP_RESOLVE_ENDPOINT"; return 0 ;;
    esac
    CFWARP_RESOLVE_HOST=${CFWARP_RESOLVE_ENDPOINT%:*}
    CFWARP_RESOLVE_PORT=${CFWARP_RESOLVE_ENDPOINT##*:}
    case "$CFWARP_RESOLVE_HOST" in
        *[!0-9.]*)
            command -v getent >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 1
            CFWARP_RESOLVE_ANSWERS=$(timeout --kill-after=1 5 getent ahostsv4 "$CFWARP_RESOLVE_HOST" 2>/dev/null) || return 1
            CFWARP_RESOLVE_HOST=$(printf '%s\n' "$CFWARP_RESOLVE_ANSWERS" | awk 'NF {print $1; exit}')
            ;;
    esac
    printf '%s\n' "$CFWARP_RESOLVE_HOST" | awk -F. '
        NF != 4 {exit 1}
        {for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i>255 || (length($i)>1 && $i ~ /^0/)) exit 1}
    ' || return 1
    printf '%s:%s\n' "$CFWARP_RESOLVE_HOST" "$CFWARP_RESOLVE_PORT"
)

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
    case "$CFWARP_COMMON_KEY" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
    case "$CFWARP_COMMON_VALUE" in *[![:print:]]*) return 1 ;; esac
    CFWARP_COMMON_TMP=$(mktemp "${CFWARP_COMMON_FILE}.tmp.XXXXXX") || return 1
    if ! CFWARP_WRITE_VALUE="$CFWARP_COMMON_VALUE" awk -v key="$CFWARP_COMMON_KEY" '
        BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*="; found = 0 }
        function assignment(    v,i,c,out) {
            v=ENVIRON["CFWARP_WRITE_VALUE"]; out="\""
            for(i=1;i<=length(v);i++) { c=substr(v,i,1); if(c=="\\" || c=="\"" || c=="$" || c=="`") out=out "\\"; out=out c }
            return key "=" out "\""
        }
        $0 ~ pattern { if (!found) print assignment(); found = 1; next }
        { print }
        END { if (!found) print assignment() }
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

# host-global interface ownership. The operation lock stays open for the full
# entrypoint lifetime; an independent stop waits for that owner to exit.
cfwarp_host_guard_lock() {
    [ "${CFWARP_HOST_LOCKED:-0}" -eq 0 ] || return 0
    cfwarp_validate_link_name "$WG_INTERFACE" WG_INTERFACE || return 1
    case "$WG_CONF" in /*) ;; *) echo 'WG_CONF must be absolute.' >&2; return 1 ;; esac
    [ "$(basename "$WG_CONF")" = "${WG_INTERFACE}.conf" ] || return 1
    CFWARP_HOST_STATE_DIR=${CFWARP_HOST_STATE_DIR:-/run/cfwarp/host-global}
    CFWARP_HOST_LOCK_WAIT_SECONDS=${CFWARP_HOST_LOCK_WAIT_SECONDS:-30}
    cfwarp_validate_uint "$CFWARP_HOST_LOCK_WAIT_SECONDS" CFWARP_HOST_LOCK_WAIT_SECONDS 1 600 || return 1
    install -d -m 0700 "$CFWARP_HOST_STATE_DIR" || return 1
    CFWARP_HOST_STATE_FILE="${CFWARP_HOST_STATE_DIR}/${WG_INTERFACE}.env"
    exec 7> "${CFWARP_HOST_STATE_DIR}/${WG_INTERFACE}.flock"
    flock -w "$CFWARP_HOST_LOCK_WAIT_SECONDS" 7 || {
        echo '==> [ERROR] host-global interface is still owned by a running process.' >&2
        return 1
    }
    CFWARP_HOST_LOCKED=1
}

cfwarp_host_interface_index() {
    ip -o link show dev "$WG_INTERFACE" 2>/dev/null | awk -F: 'NR==1 {gsub(/ /,"",$1); print $1}'
}

cfwarp_host_guard_record() {
    [ "${CFWARP_HOST_CREATE_ALLOWED:-0}" -eq 1 ] || return 1
    CFWARP_HOST_LIVE_INDEX=$(cfwarp_host_interface_index)
    [ -n "$CFWARP_HOST_LIVE_INDEX" ] || return 0
    CFWARP_HOST_LIVE_KEY=$(wg show "$WG_INTERFACE" public-key 2>/dev/null) || return 1
    CFWARP_HOST_EXPECTED_KEY=$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]]*#.*/,""); sub(/[[:space:]]*$/,""); print; exit}' "$WG_CONF" | wg pubkey) || return 1
    if [ "$CFWARP_HOST_LIVE_KEY" != "$CFWARP_HOST_EXPECTED_KEY" ] && [ "$CFWARP_HOST_LIVE_KEY" != '(none)' ]; then
        echo '==> [ERROR] Newly observed interface key does not match this configuration; refusing ownership.' >&2
        return 1
    fi
    if [ -e "$CFWARP_HOST_STATE_FILE" ]; then
        CFWARP_HOST_OLD_INDEX=$(cfwarp_read_env_key IF_INDEX "$CFWARP_HOST_STATE_FILE") || return 1
        [ "$CFWARP_HOST_OLD_INDEX" = "$CFWARP_HOST_LIVE_INDEX" ] || return 1
    fi
    # An unkeyed interface is accepted only within this lock holder's creation
    # attempt, after prepare proved the name absent. This permits partial-up
    # rollback without granting a later stop ownership over arbitrary wg0.
    CFWARP_HOST_STATE_TMP=$(mktemp "${CFWARP_HOST_STATE_FILE}.tmp.XXXXXX") || return 1
    : > "$CFWARP_HOST_STATE_TMP"
    cfwarp_set_env_key INTERFACE "$WG_INTERFACE" "$CFWARP_HOST_STATE_TMP" &&
        cfwarp_set_env_key IF_INDEX "$CFWARP_HOST_LIVE_INDEX" "$CFWARP_HOST_STATE_TMP" &&
        cfwarp_set_env_key PUBLIC_KEY "$CFWARP_HOST_LIVE_KEY" "$CFWARP_HOST_STATE_TMP" &&
        cfwarp_set_env_key WG_CONF "$WG_CONF" "$CFWARP_HOST_STATE_TMP" || {
            rm -f "$CFWARP_HOST_STATE_TMP"
            return 1
        }
    mv "$CFWARP_HOST_STATE_TMP" "$CFWARP_HOST_STATE_FILE"
}

cfwarp_host_guard_cleanup() {
    cfwarp_host_guard_lock || return 1
    CFWARP_HOST_LIVE_INDEX=$(cfwarp_host_interface_index)
    if [ -z "$CFWARP_HOST_LIVE_INDEX" ]; then
        rm -f "$CFWARP_HOST_STATE_FILE"
        return 0
    fi
    if [ ! -e "$CFWARP_HOST_STATE_FILE" ] && [ "${CFWARP_HOST_CREATE_ALLOWED:-0}" -eq 1 ]; then
        cfwarp_host_guard_record || return 1
    fi
    if [ ! -r "$CFWARP_HOST_STATE_FILE" ]; then
        echo "==> [ERROR] Refusing to remove unowned host interface: $WG_INTERFACE" >&2
        return 1
    fi
    CFWARP_HOST_SAVED_INTERFACE=$(cfwarp_read_env_key INTERFACE "$CFWARP_HOST_STATE_FILE") || return 1
    CFWARP_HOST_SAVED_INDEX=$(cfwarp_read_env_key IF_INDEX "$CFWARP_HOST_STATE_FILE") || return 1
    CFWARP_HOST_SAVED_KEY=$(cfwarp_read_env_key PUBLIC_KEY "$CFWARP_HOST_STATE_FILE") || return 1
    CFWARP_HOST_SAVED_CONF=$(cfwarp_read_env_key WG_CONF "$CFWARP_HOST_STATE_FILE") || return 1
    CFWARP_HOST_LIVE_KEY=$(wg show "$WG_INTERFACE" public-key 2>/dev/null) || return 1
    if [ "$CFWARP_HOST_SAVED_INTERFACE" != "$WG_INTERFACE" ] || \
       [ "$CFWARP_HOST_SAVED_INDEX" != "$CFWARP_HOST_LIVE_INDEX" ] || \
       [ "$CFWARP_HOST_SAVED_KEY" != "$CFWARP_HOST_LIVE_KEY" ]; then
        echo "==> [ERROR] Host interface ownership changed; refusing to remove $WG_INTERFACE." >&2
        return 1
    fi
    case "$CFWARP_HOST_SAVED_CONF" in /*) ;; *) return 1 ;; esac
    [ "$(basename "$CFWARP_HOST_SAVED_CONF")" = "${WG_INTERFACE}.conf" ] || return 1
    if ! "$WG_QUICK_BIN" down "$CFWARP_HOST_SAVED_CONF"; then
        if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
            echo "==> [ERROR] Host interface cleanup failed: $WG_INTERFACE" >&2
            return 1
        fi
    fi
    if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
        echo "==> [ERROR] Host interface remains after wg-quick down: $WG_INTERFACE" >&2
        return 1
    fi
    rm -f "$CFWARP_HOST_STATE_FILE"
}

cfwarp_host_guard_prepare() {
    cfwarp_host_guard_lock || return 1
    CFWARP_HOST_CREATE_ALLOWED=0
    cfwarp_host_guard_cleanup || return 1
    CFWARP_HOST_CREATE_ALLOWED=1
}
