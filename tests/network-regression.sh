#!/bin/sh
# Run only in an isolated Linux VM: this suite temporarily changes ip_forward.
set -eu
umask 077
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
if [ "${1:-}" != '--live' ]; then
    echo 'SKIP: isolated Linux/root networking checks require --live.'
    exit 0
fi
[ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || {
    echo 'ERROR: --live requires root in an isolated Linux VM.' >&2
    exit 1
}
for tool in ip iptables ip6tables sysctl flock curl; do command -v "$tool" >/dev/null; done
TMP_DIR=$(mktemp -d /tmp/cfwarp-net-test.XXXXXX)
TEST_TAG=cft$$
REAL_IP=$(command -v ip)
REAL_SYSCTL=$(command -v sysctl)
REAL_IPTABLES=$(command -v iptables)
HOST_TEST_IF="${TEST_TAG}w"
INITIAL_FORWARD=$($REAL_SYSCTL -n net.ipv4.ip_forward)
CFWARP_TEST_UNIT=
CFWARP_TEST_MOUNT_NS=
CFWARP_TEST_START_PID=
export TMP_DIR REAL_IP REAL_SYSCTL REAL_IPTABLES
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state" "$TMP_DIR/global"
WG_QUICK_BIN="$TMP_DIR/bin/wg-quick"
export WG_QUICK_BIN

run_netns() {
    CFWARP_TEST_INSTANCE=$1
    CFWARP_TEST_ACTION=$2
    case "$CFWARP_TEST_INSTANCE" in a) CFWARP_TEST_SUBNET=231 ;; b) CFWARP_TEST_SUBNET=232 ;; esac
    env CFWARP_ENV_LOADED=1 PATH="$TMP_DIR/bin:$PATH" \
        CFWARP_STATE_DIR="$TMP_DIR/state" CFWARP_GLOBAL_STATE_DIR="$TMP_DIR/global" \
        NETNS_NAME="${TEST_TAG}${CFWARP_TEST_INSTANCE}" NETNS_HOST_IF="${TEST_TAG}${CFWARP_TEST_INSTANCE}h" \
        NETNS_NS_IF="${TEST_TAG}${CFWARP_TEST_INSTANCE}n" \
        NETNS_HOST_ADDR="169.254.${CFWARP_TEST_SUBNET}.1/30" \
        NETNS_PEER_ADDR="169.254.${CFWARP_TEST_SUBNET}.2/30" \
        NETNS_CIDR="169.254.${CFWARP_TEST_SUBNET}.0/30" \
        WG_INTERFACE=wgtest WG_CONF="$TMP_DIR/wgtest.conf" \
        sh "$ROOT_DIR/cfwarp-netns.sh" "$CFWARP_TEST_ACTION"
}

cleanup() {
    CFWARP_TEST_STATUS=$?
    trap - EXIT
    trap '' HUP INT TERM
    unset CFWARP_FAIL_STEP NETNS_DNS_SERVERS CFWARP_FAIL_IPTABLES_CHECK
    if [ -n "$CFWARP_TEST_START_PID" ]; then
        kill -TERM "$CFWARP_TEST_START_PID" 2>/dev/null || true
        wait "$CFWARP_TEST_START_PID" 2>/dev/null || true
    fi
    if [ -n "$CFWARP_TEST_UNIT" ]; then
        systemctl stop "$CFWARP_TEST_UNIT" >/dev/null 2>&1 || true
    fi
    if [ -n "$CFWARP_TEST_MOUNT_NS" ]; then
        "$REAL_IP" netns del "$CFWARP_TEST_MOUNT_NS" >/dev/null 2>&1 || true
    fi
    run_netns a down >/dev/null 2>&1 || true
    run_netns b down >/dev/null 2>&1 || true
    # These names were allocated only by this test, including collision fixtures.
    for CFWARP_TEST_NAME in "${TEST_TAG}a" "${TEST_TAG}b"; do
        "$REAL_IP" link del "${CFWARP_TEST_NAME}h" >/dev/null 2>&1 || true
        "$REAL_IP" netns del "$CFWARP_TEST_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/netns/${CFWARP_TEST_NAME}/resolv.conf"
        rmdir "/etc/netns/${CFWARP_TEST_NAME}" 2>/dev/null || true
    done
    "$REAL_IP" link del "$HOST_TEST_IF" >/dev/null 2>&1 || true
    "$REAL_SYSCTL" -w "net.ipv4.ip_forward=$INITIAL_FORWARD" >/dev/null
    rm -rf "$TMP_DIR"
    exit "$CFWARP_TEST_STATUS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$TMP_DIR/bin/wg-quick" <<'STUB'
#!/bin/sh
printf '%s|%s\n' "$1" "$2" >> "$TMP_DIR/wg.log"
STUB
cat > "$TMP_DIR/bin/ip" <<'STUB'
#!/bin/sh
if [ "$1 ${2:-}" = 'link add' ]; then
    case "${CFWARP_FAIL_STEP:-}" in
        veth) exit 44 ;;
        signal) kill -TERM "$PPID" ;;
    esac
fi
exec "$REAL_IP" "$@"
STUB
cat > "$TMP_DIR/bin/iptables" <<'STUB'
#!/bin/sh
if [ "${CFWARP_FAIL_IPTABLES_CHECK:-0}" = 1 ]; then
    for CFWARP_TEST_ARGUMENT in "$@"; do
        if [ "$CFWARP_TEST_ARGUMENT" = '-C' ]; then exit 4; fi
    done
fi
exec "$REAL_IPTABLES" "$@"
STUB
cat > "$TMP_DIR/bin/sysctl" <<'STUB'
#!/bin/sh
if [ "$1" = '-w' ]; then
    # A separately opened descriptor must not acquire the lock while the kernel
    # value changes. This catches the former unlock-before-sysctl regression.
    if flock -n "$TMP_DIR/global/ip_forward.flock" true; then
        echo 'FAIL: ip_forward changed without holding the state lock' >&2
        touch "$TMP_DIR/unlocked-kernel-write"
        exit 97
    fi
fi
exec "$REAL_SYSCTL" "$@"
STUB
chmod +x "$TMP_DIR/bin/"*
"$REAL_SYSCTL" -w net.ipv4.ip_forward=0 >/dev/null

# Missing state must never grant ownership over a pre-existing namespace.
"$REAL_IP" netns add "${TEST_TAG}a"
CFWARP_FOREIGN_INODE=$(stat -Lc '%i' "/run/netns/${TEST_TAG}a")
if run_netns a up > "$TMP_DIR/collision.log" 2>&1; then exit 1; fi
run_netns a down
[ "$(stat -Lc '%i' "/run/netns/${TEST_TAG}a")" = "$CFWARP_FOREIGN_INODE" ]
"$REAL_IP" netns del "${TEST_TAG}a"
"$REAL_IP" link add "${TEST_TAG}ah" type dummy
if run_netns a up > "$TMP_DIR/collision.log" 2>&1; then exit 1; fi
run_netns a down
"$REAL_IP" link show "${TEST_TAG}ah" >/dev/null
"$REAL_IP" link del "${TEST_TAG}ah"
echo 'PASS: unowned namespace and link collisions are preserved'

# Failure and signals after namespace/DNS creation must roll back just those
# owned resources, including the veth created by the interrupted command.
for CFWARP_FAIL_STEP in veth signal; do
    export CFWARP_FAIL_STEP
    if run_netns a up > "$TMP_DIR/partial.log" 2>&1; then exit 1; fi
    [ ! -e "/run/netns/${TEST_TAG}a" ]
    [ ! -e "/etc/netns/${TEST_TAG}a" ]
    [ ! -e "$TMP_DIR/state/${TEST_TAG}a.env" ]
    [ ! -e "$TMP_DIR/global/ip_forward.refs" ]
    if "$REAL_IP" link show "${TEST_TAG}ah" >/dev/null 2>&1; then exit 1; fi
done
unset CFWARP_FAIL_STEP
echo 'PASS: partial setup failure and TERM roll back owned resources'

run_netns a up
[ "$(cat "$TMP_DIR/global/ip_forward.refs")" = 1 ]
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 1 ]
printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > "$TMP_DIR/expected-dns"
cmp "$TMP_DIR/expected-dns" "/etc/netns/${TEST_TAG}a/resolv.conf"
# Inode checks reject stale state, and absent state performs no cleanup at all.
cp "$TMP_DIR/state/${TEST_TAG}a.env" "$TMP_DIR/state.backup"
sed -i 's/^NS_INODE=.*/NS_INODE=1/' "$TMP_DIR/state/${TEST_TAG}a.env"
if run_netns a down > "$TMP_DIR/stale.log" 2>&1; then exit 1; fi
[ -e "/run/netns/${TEST_TAG}a" ]
rm "$TMP_DIR/state/${TEST_TAG}a.env"
run_netns a down
[ -e "/run/netns/${TEST_TAG}a" ]
cp "$TMP_DIR/state.backup" "$TMP_DIR/state/${TEST_TAG}a.env"
run_netns a down
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 0 ]
echo 'PASS: state identity, missing-state safety, public DNS, and forwarding restore'

NETNS_DNS_SERVERS=9.9.9.9
export NETNS_DNS_SERVERS
run_netns a up
[ "$(cat "/etc/netns/${TEST_TAG}a/resolv.conf")" = 'nameserver 9.9.9.9' ]
unset NETNS_DNS_SERVERS
run_netns b up
[ "$(cat "$TMP_DIR/global/ip_forward.refs")" = 2 ]
run_netns a down
[ "$(cat "$TMP_DIR/global/ip_forward.refs")" = 1 ]
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 1 ]
run_netns b down
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 0 ]
# Exercise concurrent last-release/new-acquire in both possible lock orders.
CFWARP_TEST_ROUND=0
while [ "$CFWARP_TEST_ROUND" -lt 3 ]; do
    run_netns a up
    run_netns a down &
    CFWARP_TEST_DOWN_PID=$!
    run_netns b up &
    CFWARP_TEST_UP_PID=$!
    wait "$CFWARP_TEST_DOWN_PID"
    wait "$CFWARP_TEST_UP_PID"
    [ "$(cat "$TMP_DIR/global/ip_forward.refs")" = 1 ]
    [ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 1 ]
    run_netns b down
    [ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 0 ]
    CFWARP_TEST_ROUND=$((CFWARP_TEST_ROUND + 1))
done
[ ! -e "$TMP_DIR/unlocked-kernel-write" ]
echo 'PASS: custom DNS, two-instance refs, concurrent acquire/release, locked sysctl'

# Backend/lock errors are not equivalent to an absent iptables rule. Persist
# cleanup state and keep forwarding refs until a successful retry removes rules.
run_netns a up
CFWARP_FAIL_IPTABLES_CHECK=1
export CFWARP_FAIL_IPTABLES_CHECK
if run_netns a down > "$TMP_DIR/iptables-failure.log" 2>&1; then exit 1; fi
[ -e "$TMP_DIR/state/${TEST_TAG}a.env" ]
[ "$(cat "$TMP_DIR/global/ip_forward.refs")" = 1 ]
unset CFWARP_FAIL_IPTABLES_CHECK
run_netns a down
[ ! -e "$TMP_DIR/state/${TEST_TAG}a.env" ]
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 0 ]
echo 'PASS: iptables backend errors preserve cleanup state and retry safely'

# Both namespace and host-global teardown must use the actual custom config.
[ "$(sort -u "$TMP_DIR/wg.log")" = "down|$TMP_DIR/wgtest.conf" ]
env CFWARP_ENV_LOADED=1 CFWARP_MODE=host-global WG_INTERFACE=wgtest \
    WG_CONF="$TMP_DIR/wgtest.conf" sh "$ROOT_DIR/cfwarp-stop.sh"
[ "$(tail -n 1 "$TMP_DIR/wg.log")" = "down|$TMP_DIR/wgtest.conf" ]
echo 'PASS: namespace and host-global wg-quick receive the full config path'
# host-global may only replace interfaces for which it has matching ownership
# evidence. Use actual WireGuard devices but no addresses, routes or peer traffic.
wg genkey > "$TMP_DIR/host.key"
wg genkey > "$TMP_DIR/foreign.key"
{
    printf '[Interface]\nPrivateKey = '
    cat "$TMP_DIR/host.key"
} > "$TMP_DIR/${HOST_TEST_IF}.conf"
cat > "$TMP_DIR/bin/host-wg-quick" <<'STUB'
#!/bin/sh
[ "${CFWARP_HOST_TEST_FAIL_DOWN:-0}" = 0 ] || exit 32
printf '%s|%s\n' "$1" "$2" >> "$TMP_DIR/host-wg.log"
exec "$REAL_IP" link del "$(basename "$2" .conf)"
STUB
chmod +x "$TMP_DIR/bin/host-wg-quick"
cat > "$TMP_DIR/host-test.sh" <<'STUB'
#!/bin/sh
set -eu
# shellcheck disable=SC1090
. "$CFWARP_TEST_COMMON_FILE"
case "$1" in
    prepare) cfwarp_host_guard_prepare ;;
    down) cfwarp_host_guard_cleanup ;;
    up)
        cfwarp_host_guard_prepare
        ip link add "$WG_INTERFACE" type wireguard
        wg set "$WG_INTERFACE" private-key "$TMP_DIR/host.key"
        cfwarp_host_guard_record
        ;;
    interrupt)
        cfwarp_host_guard_prepare
        trap cfwarp_host_guard_cleanup EXIT
        trap 'exit 143' TERM
        ip link add "$WG_INTERFACE" type wireguard
        kill -TERM "$$"
        ;;
esac
STUB
run_host() {
    env CFWARP_ENV_LOADED=1 CFWARP_MODE=host-global WG_INTERFACE="$HOST_TEST_IF" \
        WG_CONF="$TMP_DIR/${HOST_TEST_IF}.conf" WG_QUICK_BIN="$TMP_DIR/bin/host-wg-quick" \
        CFWARP_HOST_STATE_DIR="$TMP_DIR/host-state" \
        CFWARP_TEST_COMMON_FILE="$ROOT_DIR/lib/cfwarp-common.sh" \
        sh "$TMP_DIR/host-test.sh" "$1"
}
"$REAL_IP" link add "$HOST_TEST_IF" type wireguard
wg set "$HOST_TEST_IF" private-key "$TMP_DIR/host.key"
if run_host prepare > "$TMP_DIR/host-collision.log" 2>&1; then exit 1; fi
if run_host down > "$TMP_DIR/host-collision.log" 2>&1; then exit 1; fi
cp "$TMP_DIR/${HOST_TEST_IF}.conf" "$TMP_DIR/foreign-conf.backup"
for CFWARP_HOST_ENTRY in entrypoint.sh cfwarp-start.sh cfwarp-stop.sh; do
    if env CFWARP_ENV_LOADED=1 CFWARP_MODE=host-global WG_INTERFACE="$HOST_TEST_IF" \
        CFWARP_DATA_DIR="$TMP_DIR/host-data" WG_CONF="$TMP_DIR/${HOST_TEST_IF}.conf" \
        WG_QUICK_BIN="$TMP_DIR/bin/host-wg-quick" CFWARP_HOST_STATE_DIR="$TMP_DIR/host-state" \
        sh "$ROOT_DIR/$CFWARP_HOST_ENTRY" > "$TMP_DIR/$CFWARP_HOST_ENTRY.foreign.log" 2>&1; then exit 1; fi
    cmp "$TMP_DIR/foreign-conf.backup" "$TMP_DIR/${HOST_TEST_IF}.conf"
    "$REAL_IP" link show "$HOST_TEST_IF" >/dev/null
done
"$REAL_IP" link show "$HOST_TEST_IF" >/dev/null
[ ! -e "$TMP_DIR/host-wg.log" ]
"$REAL_IP" link del "$HOST_TEST_IF"
run_host up
cp "$TMP_DIR/host-state/${HOST_TEST_IF}.env" "$TMP_DIR/host-state.backup"
sed -i 's/^IF_INDEX=.*/IF_INDEX="1"/' "$TMP_DIR/host-state/${HOST_TEST_IF}.env"
if run_host down > "$TMP_DIR/host-stale.log" 2>&1; then exit 1; fi
cp "$TMP_DIR/host-state.backup" "$TMP_DIR/host-state/${HOST_TEST_IF}.env"
wg set "$HOST_TEST_IF" private-key "$TMP_DIR/foreign.key"
if run_host down > "$TMP_DIR/host-key.log" 2>&1; then exit 1; fi
wg set "$HOST_TEST_IF" private-key "$TMP_DIR/host.key"
CFWARP_HOST_TEST_FAIL_DOWN=1
export CFWARP_HOST_TEST_FAIL_DOWN
if run_host down > "$TMP_DIR/host-down-failed.log" 2>&1; then exit 1; fi
[ -e "$TMP_DIR/host-state/${HOST_TEST_IF}.env" ]
"$REAL_IP" link show "$HOST_TEST_IF" >/dev/null
unset CFWARP_HOST_TEST_FAIL_DOWN
run_host down
[ ! -e "$TMP_DIR/host-state/${HOST_TEST_IF}.env" ]
if "$REAL_IP" link show "$HOST_TEST_IF" >/dev/null 2>&1; then exit 1; fi
[ "$(tail -n 1 "$TMP_DIR/host-wg.log")" = "down|$TMP_DIR/${HOST_TEST_IF}.conf" ]
if run_host interrupt > "$TMP_DIR/host-interrupt.log" 2>&1; then exit 1; fi
if "$REAL_IP" link show "$HOST_TEST_IF" >/dev/null 2>&1; then exit 1; fi
[ ! -e "$TMP_DIR/host-state/${HOST_TEST_IF}.env" ]
echo 'PASS: host-global ownership, identity changes, failed-down retry and partial-up TERM'

# Exercise the service wrapper with real namespaces and a controllable child,
# proving that TERM reaches the child and teardown finishes before exit.
mkdir -p "$TMP_DIR/service/lib"
cp "$ROOT_DIR/cfwarp-start.sh" "$ROOT_DIR/cfwarp-netns.sh" "$TMP_DIR/service/"
cp "$ROOT_DIR/lib/cfwarp-common.sh" "$TMP_DIR/service/lib/"
cat > "$TMP_DIR/service/entrypoint.sh" <<'STUB'
#!/bin/sh
[ "${CFWARP_PREPARE_ONLY:-0}" != 1 ] || exit 0
sleep 60 &
SLEEP_PID=$!
finish() {
    kill -TERM "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
    touch "$TMP_DIR/entrypoint.stopped"
}
trap finish EXIT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$TMP_DIR/entrypoint.pid"
wait "$SLEEP_PID"
STUB
env CFWARP_ENV_LOADED=1 PATH="$TMP_DIR/bin:$PATH" \
    CFWARP_STATE_DIR="$TMP_DIR/state" CFWARP_GLOBAL_STATE_DIR="$TMP_DIR/global" \
    NETNS_NAME="${TEST_TAG}a" NETNS_HOST_IF="${TEST_TAG}ah" NETNS_NS_IF="${TEST_TAG}an" \
    NETNS_HOST_ADDR=169.254.231.1/30 NETNS_PEER_ADDR=169.254.231.2/30 \
    NETNS_CIDR=169.254.231.0/30 WG_INTERFACE=wgtest WG_CONF="$TMP_DIR/wgtest.conf" \
    sh "$TMP_DIR/service/cfwarp-start.sh" > "$TMP_DIR/start.log" 2>&1 &
CFWARP_TEST_START_PID=$!
CFWARP_TEST_WAIT=0
while [ ! -e "$TMP_DIR/entrypoint.pid" ] && [ "$CFWARP_TEST_WAIT" -lt 30 ]; do
    sleep 0.1
    CFWARP_TEST_WAIT=$((CFWARP_TEST_WAIT + 1))
done
[ -e "$TMP_DIR/entrypoint.pid" ]
CFWARP_TEST_ENTRYPOINT_PID=$(cat "$TMP_DIR/entrypoint.pid")
kill -TERM "$CFWARP_TEST_START_PID"
if wait "$CFWARP_TEST_START_PID"; then exit 1; fi
CFWARP_TEST_START_PID=
[ -e "$TMP_DIR/entrypoint.stopped" ]
if kill -0 "$CFWARP_TEST_ENTRYPOINT_PID" 2>/dev/null; then exit 1; fi
[ ! -e "/run/netns/${TEST_TAG}a" ]
[ ! -e "$TMP_DIR/global/ip_forward.refs" ]
[ "$($REAL_SYSCTL -n net.ipv4.ip_forward)" = 0 ]
echo 'PASS: service TERM stops its child and completes namespace cleanup'

# Mount sandbox properties must allow namespace bind mounts to propagate from
# service commands back to the host. Read the current templates so reverting
# ProtectHome/PrivateTmp to a mount sandbox fails this check.
if command -v systemd-run >/dev/null && [ -d /run/systemd/system ]; then
    for CFWARP_TEST_TEMPLATE in "$ROOT_DIR"/deploy/systemd/*.service.in; do
        CFWARP_TEST_UNIT="${TEST_TAG}-mnt"
        CFWARP_TEST_MOUNT_NS="${TEST_TAG}mnt"
        awk '/^(PrivateTmp|ProtectHome|ProtectSystem|PrivateMounts|ReadOnlyPaths|ReadWritePaths|InaccessiblePaths|BindPaths|BindReadOnlyPaths|TemporaryFileSystem)=/ {print}' \
            "$CFWARP_TEST_TEMPLATE" > "$TMP_DIR/mount.properties"
        set --
        while IFS= read -r CFWARP_TEST_PROPERTY; do
            set -- "$@" "--property=$CFWARP_TEST_PROPERTY"
        done < "$TMP_DIR/mount.properties"
        rm -f "$TMP_DIR/mount.ready"
        systemd-run --quiet --unit="$CFWARP_TEST_UNIT" "$@" \
            /bin/sh -c '"$1" netns add "$2" && touch "$3" && exec sleep 60' \
            cfw-test "$REAL_IP" "$CFWARP_TEST_MOUNT_NS" "$TMP_DIR/mount.ready"
        CFWARP_TEST_WAIT=0
        while [ ! -e "$TMP_DIR/mount.ready" ] && [ "$CFWARP_TEST_WAIT" -lt 30 ]; do
            sleep 0.1
            CFWARP_TEST_WAIT=$((CFWARP_TEST_WAIT + 1))
        done
        [ -e "$TMP_DIR/mount.ready" ]
        "$REAL_IP" netns exec "$CFWARP_TEST_MOUNT_NS" true
        systemctl stop "$CFWARP_TEST_UNIT"
        "$REAL_IP" netns del "$CFWARP_TEST_MOUNT_NS"
        CFWARP_TEST_UNIT=
        CFWARP_TEST_MOUNT_NS=
    done
    echo 'PASS: all service templates preserve host namespace mount visibility'
else
    echo 'SKIP: systemd mount visibility requires a running systemd instance'
fi
echo 'PASS: all available isolated Linux networking regressions' 
