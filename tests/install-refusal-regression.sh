#!/bin/sh
# Exercise the real cleanup function with isolated state and command stubs.
# No root privileges, systemd instance, or network changes are needed.
set -eu
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
fail() { echo "installation refusal regression failed: $*" >&2; exit 1; }

# Read the production function rather than maintaining a duplicate cleanup.
awk '
    /^cleanup_read_unit_state\(\)/ { capture=1; found=1 }
    /^reload_and_enable\(\)/ { capture=0 }
    capture { print }
    END { if (!found) exit 1 }
' "$ROOT_DIR/install.sh" > "$TMP_DIR/cleanup-function.sh"
cat > "$TMP_DIR/harness.sh" <<'HARNESS'
#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$TEST_ROOT/cleanup-function.sh"
require_root() { :; }
systemd_available() { return 0; }
acquire_install_lock() {
    printf 'lock\n' >> "$TEST_CASE/mutations"
    if [ "${TEST_ACTIVATE_ON_LOCK:-0}" = 1 ]; then
        # Simulate an earlier lock owner starting the main service before the
        # cleanup process acquires the lock. This is not a cleanup mutation.
        printf 'active\n' > "$TEST_CASE/state/cfwarp.service"
    fi
}
systemctl() {
    command=$1
    shift
    case "$command" in
        show)
            [ "$1" = --property=ActiveState ] && [ "$2" = --value ] || return 1
            cat "$TEST_CASE/state/$3"
            ;;
        is-active)
            [ "${1:-}" != --quiet ] || shift
            [ "$(cat "$TEST_CASE/state/$1")" = active ]
            ;;
        stop)
            for unit in "$@"; do
                printf 'stop %s\n' "$unit" >> "$TEST_CASE/mutations"
                # A cancelled refresh may restore the main service.
                if [ "$unit" = cfwarp-endpoint-refresh.service ] &&
                    [ "$(cat "$TEST_CASE/state/$unit")" != inactive ] &&
                    [ "${TEST_RESTORE_ON_REFRESH_STOP:-0}" = 1 ]; then
                    printf 'active\n' > "$TEST_CASE/state/cfwarp.service"
                fi
                printf 'inactive\n' > "$TEST_CASE/state/$unit"
            done
            ;;
        disable)
            disable_now=0
            [ "${1:-}" != --now ] || { disable_now=1; shift; }
            for unit in "$@"; do
                printf 'disable %s\n' "$unit" >> "$TEST_CASE/mutations"
                printf 'disabled\n' > "$TEST_CASE/state/$unit.enabled"
                [ "$disable_now" = 0 ] || printf 'inactive\n' > "$TEST_CASE/state/$unit"
            done
            ;;
        daemon-reload) printf 'daemon-reload\n' >> "$TEST_CASE/mutations" ;;
        *) echo "unexpected systemctl command: $command" >&2; return 1 ;;
    esac
}
INSTALL_PREFIX="$TEST_CASE/runtime"
BIN_DIR="$INSTALL_PREFIX/bin"
SYSTEMD_UNIT="$TEST_CASE/units/cfwarp.service"
REFRESH_UNIT="$TEST_CASE/units/cfwarp-endpoint-refresh.service"
REFRESH_TIMER="$TEST_CASE/units/cfwarp-endpoint-refresh.timer"
WATCHDOG_UNIT="$TEST_CASE/units/cfwarp-watchdog.service"
WATCHDOG_TIMER="$TEST_CASE/units/cfwarp-watchdog.timer"
clean_generated
HARNESS

UNITS='cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer'
prepare_case() {
    TEST_CASE="$TMP_DIR/$1"
    export TEST_CASE
    mkdir -p "$TEST_CASE/state" "$TEST_CASE/units" "$TEST_CASE/runtime/lib" "$TEST_CASE/runtime/bin" "$TEST_CASE/runtime/deploy"
    for unit in $UNITS; do
        printf 'inactive\n' > "$TEST_CASE/state/$unit"
        printf 'enabled\n' > "$TEST_CASE/state/$unit.enabled"
        printf 'fixture unit\n' > "$TEST_CASE/units/$unit"
    done
    printf 'active\n' > "$TEST_CASE/state/cfwarp-watchdog.timer"
    printf 'active\n' > "$TEST_CASE/state/cfwarp-endpoint-refresh.timer"
    for file in lib/cfwarp-common.sh deploy/installation.env entrypoint.sh cfwarp cfwarp-exec bin/cfwarp bin/cfwarp-exec bin/wg-quick bin/microsocks; do
        printf 'fixture runtime file\n' > "$TEST_CASE/runtime/$file"
    done
    : > "$TEST_CASE/mutations"
}
run_cleanup() {
    TEST_ROOT="$TMP_DIR" FORCE_CLEAN="$1" sh "$TMP_DIR/harness.sh" > "$TEST_CASE/output" 2>&1
}
assert_refusal_preserved_state() {
    cp -R "$TEST_CASE/state" "$TEST_CASE/state-before"
    cp -R "$TEST_CASE/units" "$TEST_CASE/units-before"
    cp -R "$TEST_CASE/runtime" "$TEST_CASE/runtime-before"
    if run_cleanup 0; then fail 'active service cleanup was accepted without --force'; fi
    [ ! -s "$TEST_CASE/mutations" ] || { cat "$TEST_CASE/mutations" >&2; fail 'refusal changed services or acquired a write lock'; }
    diff -r "$TEST_CASE/state-before" "$TEST_CASE/state" >/dev/null || fail 'refusal changed activity or enablement'
    diff -r "$TEST_CASE/units-before" "$TEST_CASE/units" >/dev/null || fail 'refusal changed unit files'
    diff -r "$TEST_CASE/runtime-before" "$TEST_CASE/runtime" >/dev/null || fail 'refusal changed runtime files'
}

# The original bug stopped both timers before detecting the active main unit.
prepare_case active-main
printf 'active\n' > "$TEST_CASE/state/cfwarp.service"
assert_refusal_preserved_state

# An in-flight refresh can have stopped the main unit temporarily. Refusing
# before stopping helpers avoids accidentally restoring it during cleanup.
for helper in cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
    for state in active activating deactivating; do
        prepare_case "$state-$helper"
        printf '%s\n' "$state" > "$TEST_CASE/state/$helper"
        assert_refusal_preserved_state
    done
done

# State can change after the initial preflight while another installer owns the
# lock. The second preflight must preserve that newly started main service.
prepare_case service-started-before-lock
cp -R "$TEST_CASE/units" "$TEST_CASE/units-before"
cp -R "$TEST_CASE/runtime" "$TEST_CASE/runtime-before"
TEST_ACTIVATE_ON_LOCK=1
export TEST_ACTIVATE_ON_LOCK
if run_cleanup 0; then fail 'cleanup accepted a main service started before lock acquisition'; fi
unset TEST_ACTIVATE_ON_LOCK
[ "$(cat "$TEST_CASE/mutations")" = lock ] || fail 'lock-time refusal stopped or disabled a unit'
for unit in cfwarp.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer; do
    [ "$(cat "$TEST_CASE/state/$unit")" = active ] || fail 'lock-time refusal stopped a live unit'
done
for unit in $UNITS; do
    [ "$(cat "$TEST_CASE/state/$unit.enabled")" = enabled ] || fail 'lock-time refusal disabled a unit'
done
diff -r "$TEST_CASE/units-before" "$TEST_CASE/units" >/dev/null || fail 'lock-time refusal changed unit files'
diff -r "$TEST_CASE/runtime-before" "$TEST_CASE/runtime" >/dev/null || fail 'lock-time refusal changed runtime files'

# Timers alone do not block an otherwise idle installation's removal.
prepare_case idle-main-active-timers
run_cleanup 0 || { cat "$TEST_CASE/output" >&2; fail 'idle cleanup was refused'; }
for unit in $UNITS; do
    [ "$(cat "$TEST_CASE/state/$unit")" = inactive ] || fail 'idle cleanup left an active unit'
    [ "$(cat "$TEST_CASE/state/$unit.enabled")" = disabled ] || fail 'idle cleanup left an enabled unit'
done
[ ! -e "$TEST_CASE/runtime/lib/cfwarp-common.sh" ] || fail 'idle cleanup retained generated library'

# --force explicitly permits stopping live services, including a main service
# restored by refresh cancellation, before deleting the runtime.
prepare_case forced-live-services
for unit in $UNITS; do printf 'active\n' > "$TEST_CASE/state/$unit"; done
printf 'activating\n' > "$TEST_CASE/state/cfwarp-endpoint-refresh.service"
printf 'deactivating\n' > "$TEST_CASE/state/cfwarp-watchdog.service"
TEST_RESTORE_ON_REFRESH_STOP=1
export TEST_RESTORE_ON_REFRESH_STOP
run_cleanup 1 || { cat "$TEST_CASE/output" >&2; fail 'forced cleanup failed'; }
for unit in $UNITS; do
    [ "$(cat "$TEST_CASE/state/$unit")" = inactive ] || fail 'forced cleanup left an active unit'
    [ "$(cat "$TEST_CASE/state/$unit.enabled")" = disabled ] || fail 'forced cleanup left an enabled unit'
done
[ ! -e "$TEST_CASE/runtime/lib/cfwarp-common.sh" ] || fail 'forced cleanup retained generated library'
echo 'CFwarp installation refusal regressions passed'
