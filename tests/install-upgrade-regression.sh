#!/bin/sh
# Production installer functions with private paths and fake systemctl/builds.
# No root privileges, package installs, network, or real /run/lock changes.
set -eu
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
fail() { echo "installation upgrade regression failed: $*" >&2; exit 1; }
awk '
    /^CFWARP_BUILD_TMP=/ { capture=1 }
    /^install_private_wg_quick\(\)/ { capture=0 }
    /^cleanup_read_unit_state\(\)/ { capture=1 }
    /^cleanup_preflight\(\)/ { capture=0 }
    /^stop_upgrade_unit\(\)/ { capture=1 }
    /^acquire_install_lock\(\)/ { capture=0 }
    capture { print }
' "$ROOT_DIR/install.sh" > "$TMP_DIR/upgrade-functions.sh"
cat > "$TMP_DIR/upgrade-harness.sh" <<'HARNESS'
#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$TEST_ROOT/upgrade-functions.sh"
systemd_available() { return 0; }
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
            unit=$1
            printf 'stop %s\n' "$unit" >> "$TEST_CASE/events"
            [ "${TEST_FAIL_STOP:-}" != "$unit" ] || return 1
            if [ "$unit" = cfwarp-endpoint-refresh.service ] && [ "${TEST_REFRESH_RESTORES_MAIN:-0}" = 1 ]; then
                printf 'activating\n' > "$TEST_CASE/state/cfwarp.service"
            fi
            if [ "$unit" = cfwarp.service ]; then
                # Another manager may claim the old interface name after stop.
                touch "$TEST_CASE/foreign-wg0"
            fi
            if [ "${TEST_REMAIN_BUSY:-}" != "$unit" ]; then
                printf 'inactive\n' > "$TEST_CASE/state/$unit"
            fi
            ;;
        *) echo "unexpected systemctl command: $command" >&2; return 1 ;;
    esac
}
# Any name-only cleanup would hit this foreign interface in the fixture.
wg() { [ -e "$TEST_CASE/foreign-wg0" ]; }
cfwarp_validate_link_name() { return 0; }
cfwarp_read_env_key() {
    case "$1" in
        CFWARP_MODE) printf 'host-global\n' ;;
        WG_INTERFACE) printf 'wg0\n' ;;
        WG_CONF) printf '%s\n' "$TEST_CASE/owned/wg0.conf" ;;
        *) return 1 ;;
    esac
}
git() {
    case "$1" in
        clone)
            mkdir -p "$3"
            printf '#!/bin/sh\nprintf "new-binary\\n"\n' > "$3/microsocks"
            ;;
        checkout) : ;;
        rev-parse) printf '%s\n' "$MICROSOCKS_COMMIT" ;;
        *) return 1 ;;
    esac
}
make() { :; }
BIN_DIR="$TEST_CASE/bin"
ENV_FILE="$TEST_CASE/env"
DATA_DIR="$TEST_CASE/data"
SKIP_BUILD=0
MICROSOCKS_REPO=fixture
MICROSOCKS_COMMIT=1111111111111111111111111111111111111111
MICROSOCKS_CFLAGS=-O2
trap cleanup_install_temporary_files EXIT
trap 'exit 143' HUP INT TERM
build_microsocks
cmp "$BIN_DIR/microsocks" "$TEST_CASE/old-binary" || { echo 'Build replaced live binary before stop.' >&2; exit 1; }
[ -f "$CFWARP_MICROSOCKS_STAGED" ] || exit 1
stop_for_upgrade
publish_microsocks
printf 'publish\n' >> "$TEST_CASE/events"
printf '%s\n' "$SERVICE_WAS_ACTIVE" > "$TEST_CASE/restore-main"
HARNESS
chmod +x "$TMP_DIR/upgrade-harness.sh"
UNITS='cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer'
prepare_case() {
    TEST_CASE="$TMP_DIR/$1"
    export TEST_CASE
    mkdir -p "$TEST_CASE/state" "$TEST_CASE/bin" "$TEST_CASE/data"
    for unit in $UNITS; do printf 'inactive\n' > "$TEST_CASE/state/$unit"; done
    printf 'old-binary\n' > "$TEST_CASE/bin/microsocks"
    cp "$TEST_CASE/bin/microsocks" "$TEST_CASE/old-binary"
    printf 'private config fixture\n' > "$TEST_CASE/env"
    cat > "$TEST_CASE/bin/wg-quick" <<'STUB'
#!/bin/sh
printf 'unsafe-name-only-down\n' >> "$TEST_CASE/events"
exit 1
STUB
    chmod +x "$TEST_CASE/bin/wg-quick"
    : > "$TEST_CASE/events"
}
run_upgrade() { TEST_ROOT="$TMP_DIR" sh "$TMP_DIR/upgrade-harness.sh" > "$TEST_CASE/output" 2>&1; }

# A refresh is activating while its oneshot is running. Its stop can restore
# the temporarily inactive main service, which must then stop before publish.
prepare_case refresh-restores-main
printf 'active\n' > "$TEST_CASE/state/cfwarp-watchdog.timer"
printf 'activating\n' > "$TEST_CASE/state/cfwarp-endpoint-refresh.timer"
printf 'deactivating\n' > "$TEST_CASE/state/cfwarp-watchdog.service"
printf 'activating\n' > "$TEST_CASE/state/cfwarp-endpoint-refresh.service"
TEST_REFRESH_RESTORES_MAIN=1
export TEST_REFRESH_RESTORES_MAIN
run_upgrade || { cat "$TEST_CASE/output" >&2; fail 'upgrade did not quiesce transitional helpers'; }
unset TEST_REFRESH_RESTORES_MAIN
[ "$(cat "$TEST_CASE/events")" = "$(printf 'stop cfwarp-watchdog.timer\nstop cfwarp-endpoint-refresh.timer\nstop cfwarp-watchdog.service\nstop cfwarp-endpoint-refresh.service\nstop cfwarp.service\npublish')" ] || fail 'runtime published before all units stopped'
[ "$(cat "$TEST_CASE/restore-main")" = 1 ] || fail 'refresh-restored main service lost its restart intent'
for unit in $UNITS; do [ "$(cat "$TEST_CASE/state/$unit")" = inactive ] || fail 'upgrade left a busy unit'; done
[ -f "$TEST_CASE/foreign-wg0" ] || fail 'foreign interface fixture was removed'
if grep -F unsafe-name-only-down "$TEST_CASE/events" >/dev/null; then fail 'upgrade removed a foreign same-name interface'; fi

for state in active activating deactivating reloading; do
    prepare_case "main-$state"
    printf '%s\n' "$state" > "$TEST_CASE/state/cfwarp.service"
    run_upgrade || { cat "$TEST_CASE/output" >&2; fail "main $state was not stopped"; }
    [ "$(cat "$TEST_CASE/events")" = "$(printf 'stop cfwarp.service\npublish')" ] || fail 'busy main service was not stopped before publish'
    [ "$(cat "$TEST_CASE/restore-main")" = 1 ] || fail 'busy main service lost restart intent'
done

for failing_unit in cfwarp-watchdog.timer cfwarp-endpoint-refresh.service cfwarp.service; do
    prepare_case "stop-fails-$failing_unit"
    printf 'activating\n' > "$TEST_CASE/state/$failing_unit"
    TEST_FAIL_STOP=$failing_unit
    export TEST_FAIL_STOP
    if run_upgrade; then fail 'failed stop was ignored'; fi
    unset TEST_FAIL_STOP
    cmp "$TEST_CASE/bin/microsocks" "$TEST_CASE/old-binary" || fail 'failed stop replaced live binary'
    [ -z "$(find "$TEST_CASE/bin" -name '.microsocks.new.*' -print)" ] || fail 'failed upgrade left a staged binary'
    if grep -Fx publish "$TEST_CASE/events" >/dev/null; then fail 'failed stop permitted publication'; fi
done
prepare_case successful-stop-still-busy
printf 'activating\n' > "$TEST_CASE/state/cfwarp-endpoint-refresh.service"
TEST_REMAIN_BUSY=cfwarp-endpoint-refresh.service
export TEST_REMAIN_BUSY
if run_upgrade; then fail 'successful stop reply concealed a still-busy helper'; fi
unset TEST_REMAIN_BUSY
cmp "$TEST_CASE/bin/microsocks" "$TEST_CASE/old-binary" || fail 'busy helper allowed binary replacement'

# Test the real lock function against a private stand-in for /run.
# Substituting the system path keeps tests from changing real system paths.
TEST_RUN_ROOT="$TMP_DIR/run"
TEST_LOCK_PARENT="$TEST_RUN_ROOT/lock"
export TEST_RUN_ROOT
mkdir -p "$TEST_LOCK_PARENT"
chmod 1777 "$TEST_LOCK_PARENT"
awk '
    /^acquire_install_lock\(\)/ { capture=1 }
    /^print_summary\(\)/ { capture=0 }
    capture { gsub("/run", ENVIRON["TEST_RUN_ROOT"]); print }
' "$ROOT_DIR/install.sh" > "$TMP_DIR/lock-function.sh"
mkdir -p "$TMP_DIR/lock-bin"
cat > "$TMP_DIR/lock-bin/flock" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMP_DIR/lock-bin/flock"
run_lock() {
    PATH="$TMP_DIR/lock-bin:$PATH" sh -c '. "$1"; acquire_install_lock' lock-test "$TMP_DIR/lock-function.sh" > "$TMP_DIR/lock-output" 2>&1
}
run_lock || { cat "$TMP_DIR/lock-output" >&2; fail 'private installation lock failed'; }
mode_of() {
    if mode=$(stat -c '%a' "$1" 2>/dev/null); then
        printf '%s\n' "$mode"
    else
        raw_mode=$(stat -f '%Op' "$1")
        printf '%o\n' "$((0$raw_mode & 07777))"
    fi
}
mode=$(mode_of "$TEST_LOCK_PARENT")
[ "$mode" = 1777 ] || fail 'installer changed public lock directory permissions'
mode=$(mode_of "$TEST_RUN_ROOT/cfwarp-install")
[ "$mode" = 700 ] || fail 'installation lock directory is not private'
mode=$(mode_of "$TEST_RUN_ROOT/cfwarp-install/install.lock")
[ "$mode" = 600 ] || fail 'installation lock file is not private'
printf 'do-not-touch\n' > "$TMP_DIR/protected-target"
rm "$TEST_RUN_ROOT/cfwarp-install/install.lock"
ln -s "$TMP_DIR/protected-target" "$TEST_RUN_ROOT/cfwarp-install/install.lock"
if run_lock; then fail 'symlink lock file was accepted'; fi
[ "$(cat "$TMP_DIR/protected-target")" = do-not-touch ] || fail 'lock open damaged symlink target'
rm "$TEST_RUN_ROOT/cfwarp-install/install.lock"
rmdir "$TEST_RUN_ROOT/cfwarp-install"
ln -s "$TMP_DIR" "$TEST_RUN_ROOT/cfwarp-install"
if run_lock; then fail 'symlink lock directory was accepted'; fi
rm "$TEST_RUN_ROOT/cfwarp-install"
mkdir "$TEST_RUN_ROOT/cfwarp-install"
chmod 0777 "$TEST_RUN_ROOT/cfwarp-install"
if run_lock; then fail 'writable installation lock directory was accepted'; fi
mode=$(mode_of "$TEST_RUN_ROOT/cfwarp-install")
[ "$mode" = 777 ] || fail 'unsafe directory was silently chmodded instead of refused'
echo 'CFWarp installation upgrade regressions passed'
