#!/bin/sh
# Only use in a disposable Linux VM/runner, never an existing CFwarp host.
set -eu
if [ "${1:-}" != --live ]; then
    echo 'SKIP: installation regression requires --live in an isolated Linux VM.'
    exit 0
fi
[ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || exit 1
if systemctl cat cfwarp.service >/dev/null 2>&1; then
    echo 'Refusing installation test on a host with an existing cfwarp.service.' >&2
    exit 1
fi
# A removed test unit may still have a failed tombstone in the manager.
systemctl reset-failed cfwarp.service >/dev/null 2>&1 || true
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d /tmp/cfwarp-install-test.XXXXXX)
cleanup() {
    if [ -e "$TMP_DIR/runtime/lib/cfwarp-common.sh" ]; then run_install --clean-generated --force >/dev/null 2>&1 || true; fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/env" "$TMP_DIR/data"
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/bin/microsocks"
chmod 0755 "$TMP_DIR/bin/microsocks"
printf "CFWARP_DATA_DIR='%s'\nCFWARP_MODE=netns-proxy\n" "$TMP_DIR/data" > "$TMP_DIR/env/cfwarp.env"
run_install() {
    sh "$ROOT_DIR/install.sh" --prefix "$TMP_DIR/runtime" --env-dir "$TMP_DIR/env" \
        --bin-dir "$TMP_DIR/bin" --systemd-dir "$TMP_DIR/systemd" \
        --skip-deps --skip-build --no-enable --no-watchdog-timer --no-refresh-timer "$@"
}
run_install > "$TMP_DIR/install.log" 2>&1 || { cat "$TMP_DIR/install.log"; exit 1; }
test -x "$TMP_DIR/bin/wg-quick"
cmp /usr/bin/wg-quick "$TMP_DIR/bin/wg-quick"
test -L "$TMP_DIR/bin/cfwarp"
test -L "$TMP_DIR/bin/cfwarp-exec"
test "$("$TMP_DIR/bin/cfwarp" env)" = "$TMP_DIR/env/cfwarp.env"
"$TMP_DIR/bin/cfwarp" doctor > "$TMP_DIR/doctor.log" 2>&1 || { cat "$TMP_DIR/doctor.log"; exit 1; }
# shellcheck source=lib/cfwarp-common.sh
. "$ROOT_DIR/lib/cfwarp-common.sh"
test "$(cfwarp_read_env_key CFWARP_DATA_DIR "$TMP_DIR/env/cfwarp.env")" = "$TMP_DIR/data"
grep -Fx "Environment=CFWARP_ENV_FILE=$TMP_DIR/env/cfwarp.env" "$TMP_DIR/systemd/cfwarp.service" >/dev/null
test "$(cfwarp_read_env_key WG_QUICK_BIN "$TMP_DIR/runtime/deploy/installation.env")" = "$TMP_DIR/bin/wg-quick"
systemd-analyze verify "$TMP_DIR/systemd/"*.service "$TMP_DIR/systemd/"*.timer
if run_install --data-dir "$TMP_DIR/space path" > "$TMP_DIR/invalid.log" 2>&1; then
    echo 'installer accepted an unsupported path' >&2; exit 1
fi

# Use harmless live units to check that a rejected cleanup does not stop the
# watchdog, refresh, timers, or main service. No WARP/network setup is involved.
for unit in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
    case "$unit" in cfwarp.service) unit_type=simple ;; *) unit_type=oneshot ;; esac
    cat > "$TMP_DIR/systemd/$unit" <<EOF_SERVICE
[Unit]
Description=CFwarp installation refusal test fixture
[Service]
Type=$unit_type
ExecStart=/bin/sleep infinity
TimeoutStartSec=0
TimeoutStopSec=5
[Install]
WantedBy=multi-user.target
EOF_SERVICE
done
for timer in cfwarp-watchdog cfwarp-endpoint-refresh; do
    cat > "$TMP_DIR/systemd/$timer.timer" <<EOF_TIMER
[Unit]
Description=CFwarp installation refusal timer fixture
[Timer]
OnActiveSec=1h
Unit=$timer.service
[Install]
WantedBy=timers.target
EOF_TIMER
done
systemctl daemon-reload
systemctl start --no-block cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service
systemctl enable --now cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer
for unit in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service; do
    case "$unit" in cfwarp.service) expected_state=active ;; *) expected_state=activating ;; esac
    tries=0
    while [ "$(systemctl show --property=ActiveState --value "$unit")" != "$expected_state" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    test "$(systemctl show --property=ActiveState --value "$unit")" = "$expected_state"
done
assert_live_cleanup_refused() {
    for unit in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer; do
        systemctl show --property=ActiveState --property=UnitFileState "$unit" > "$TMP_DIR/$unit.before"
    done
    if run_install --clean-generated > "$TMP_DIR/refusal.log" 2>&1; then
        echo 'installer accepted cleanup of a running service without --force' >&2; exit 1
    fi
    for unit in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer; do
        systemctl show --property=ActiveState --property=UnitFileState "$unit" > "$TMP_DIR/$unit.after"
        cmp "$TMP_DIR/$unit.before" "$TMP_DIR/$unit.after"
    done
}
assert_live_cleanup_refused
# Refresh is a live oneshot (activating), even though is-active returns false
# and the main service is stopped while an endpoint refresh runs.
systemctl stop cfwarp.service cfwarp-watchdog.service
test "$(systemctl show --property=ActiveState --value cfwarp-endpoint-refresh.service)" = activating
assert_live_cleanup_refused
test -x "$TMP_DIR/bin/cfwarp"
test -e "$TMP_DIR/runtime/lib/cfwarp-common.sh"
systemctl stop cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service

# Exercise upgrade shutdown against real systemd transitions. The cancelled
# oneshot's cleanup restores main, as an interrupted endpoint refresh does.
# These are harmless sleep fixtures; no WARP API, interfaces, or routes run.
mkdir "$TMP_DIR/upgrade-bin"
printf 'old-binary\n' > "$TMP_DIR/upgrade-bin/microsocks"
cp "$TMP_DIR/upgrade-bin/microsocks" "$TMP_DIR/old-binary"
printf 'new-binary\n' > "$TMP_DIR/upgrade-bin/staged"
: > "$TMP_DIR/upgrade-events"
cat > "$TMP_DIR/refresh-cancelled.sh" <<EOF_REFRESH
#!/bin/sh
set -eu
cmp '$TMP_DIR/upgrade-bin/microsocks' '$TMP_DIR/old-binary'
systemctl start cfwarp.service
printf 'restore-main\n' >> '$TMP_DIR/upgrade-events'
EOF_REFRESH
cat > "$TMP_DIR/main-stopped.sh" <<EOF_STOP
#!/bin/sh
set -eu
cmp '$TMP_DIR/upgrade-bin/microsocks' '$TMP_DIR/old-binary'
printf 'main-stopped\n' >> '$TMP_DIR/upgrade-events'
EOF_STOP
cat > "$TMP_DIR/systemd/cfwarp.service" <<EOF_MAIN
[Unit]
Description=CFwarp upgrade main fixture
[Service]
Type=simple
ExecStart=/bin/sleep infinity
ExecStopPost=/bin/sh $TMP_DIR/main-stopped.sh
TimeoutStopSec=10
EOF_MAIN
cat > "$TMP_DIR/systemd/cfwarp-endpoint-refresh.service" <<EOF_HELPER
[Unit]
Description=CFwarp upgrade cancelled refresh fixture
[Service]
Type=oneshot
ExecStart=/bin/sleep infinity
ExecStopPost=/bin/sh $TMP_DIR/refresh-cancelled.sh
TimeoutStartSec=0
TimeoutStopSec=10
EOF_HELPER
systemctl daemon-reload
systemctl start --no-block cfwarp-endpoint-refresh.service
tries=0
while [ "$(systemctl show --property=ActiveState --value cfwarp-endpoint-refresh.service)" != activating ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
done
test "$(systemctl show --property=ActiveState --value cfwarp-endpoint-refresh.service)" = activating
test "$(systemctl show --property=ActiveState --value cfwarp.service)" = inactive
awk '
    /^publish_microsocks\(\)/ { capture=1 }
    /^install_private_wg_quick\(\)/ { capture=0 }
    /^cleanup_read_unit_state\(\)/ { capture=1 }
    /^cleanup_preflight\(\)/ { capture=0 }
    /^stop_upgrade_unit\(\)/ { capture=1 }
    /^acquire_install_lock\(\)/ { capture=0 }
    capture { print }
' "$ROOT_DIR/install.sh" > "$TMP_DIR/live-upgrade-functions.sh"
(
    # shellcheck disable=SC1091
    . "$TMP_DIR/live-upgrade-functions.sh"
    systemd_available() { return 0; }
    # Used by publish_microsocks in the extracted installer functions.
    # shellcheck disable=SC2034
    BIN_DIR="$TMP_DIR/upgrade-bin"
    # shellcheck disable=SC2034
    CFWARP_MICROSOCKS_STAGED="$TMP_DIR/upgrade-bin/staged"
    stop_for_upgrade || exit 1
    test "$SERVICE_WAS_ACTIVE" = 1 || exit 1
    for unit in cfwarp.service cfwarp-watchdog.service cfwarp-endpoint-refresh.service cfwarp-watchdog.timer cfwarp-endpoint-refresh.timer; do
        case "$(systemctl show --property=ActiveState --value "$unit")" in inactive|failed) ;; *) exit 1 ;; esac
    done
    cmp "$TMP_DIR/upgrade-bin/microsocks" "$TMP_DIR/old-binary" || exit 1
    test "$(cat "$TMP_DIR/upgrade-events")" = "$(printf 'restore-main\nmain-stopped')" || exit 1
    publish_microsocks || exit 1
    test "$(cat "$TMP_DIR/upgrade-bin/microsocks")" = new-binary || exit 1
    test ! -e "$TMP_DIR/upgrade-bin/staged" || exit 1
) > "$TMP_DIR/upgrade.log" 2>&1 || { cat "$TMP_DIR/upgrade.log"; exit 1; }
run_install --clean-generated > "$TMP_DIR/clean.log" 2>&1
test -f "$TMP_DIR/env/cfwarp.env"
test -d "$TMP_DIR/data"
test ! -e "$TMP_DIR/runtime/lib/cfwarp-common.sh"
test ! -e "$TMP_DIR/runtime/deploy/installation.env"
test ! -e "$TMP_DIR/bin/cfwarp"
test ! -e "$TMP_DIR/bin/wg-quick"
echo 'CFwarp installation regressions passed'
