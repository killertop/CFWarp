#!/bin/sh
# Unprivileged recovery fault tests. No real network or systemd commands run.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
fail() { echo "refresh recovery regression failed: $*" >&2; exit 1; }
REFRESH_UNDER_TEST=${CFWARP_REFRESH_UNDER_TEST:-$ROOT/cfwarp-refresh-endpoint.sh}
REAL_MV=$(command -v mv)
export REAL_MV
mkdir -p "$TMP/project/lib" "$TMP/bin"
cp "$ROOT/lib/cfwarp-common.sh" "$TMP/project/lib/cfwarp-common.sh"
cp "$ROOT/cfwarp-start.sh" "$TMP/project/cfwarp-start.sh"
# Only OS service detection is substituted; the complete production refresh
# and rollback implementation runs unchanged against the command fixtures.
sed 's@\[ -d /run/systemd/system \]@true@' "$REFRESH_UNDER_TEST" > "$TMP/project/cfwarp-refresh-endpoint.sh"
cat > "$TMP/project/cfwarp-netns.sh" <<'STUB'
#!/bin/sh
set -eu
case "$1" in
    up) touch "$CASE_ROOT/probe-kernel-live" ;;
    down)
        [ "$RECOVERY_SCENARIO" != probe_cleanup_failed ] || exit 1
        rm -f "$CASE_ROOT/probe-kernel-live"
        ;;
esac
exit 0
STUB
cat > "$TMP/project/entrypoint.sh" <<'STUB'
#!/bin/sh
set -eu
case "$ENDPOINT_IP" in
    192.0.2.10:2408) score=10 ;;
    192.0.2.20:2408) score=1 ;;
    *) echo 'Probe received an unresolved hostname.' >&2; exit 1 ;;
esac
printf '%s\n' "$ENDPOINT_IP" >> "$CASE_ROOT/probe-targets"
{
    printf 'SELECTED_ENDPOINT=%s\nRUNTIME_ENDPOINT=%s\nSCORE=%s\n' "$ENDPOINT_IP" "$ENDPOINT_IP" "$score"
} > "$CFWARP_PROBE_METRICS_FILE"
STUB
cat > "$TMP/project/cfwarp-healthcheck.sh" <<'STUB'
#!/bin/sh
set -eu
checks=$(cat "$CASE_ROOT/health-count")
checks=$((checks + 1))
printf '%s\n' "$checks" > "$CASE_ROOT/health-count"
printf 'health-%s\n' "$checks" >> "$CASE_ROOT/events"
case "$RECOVERY_SCENARIO" in
    success|success_hostname|stop_activating|stop_deactivating|stop_reloading) exit 0 ;;
    recovered) [ "$checks" -gt 1 ] && exit 0 ;;
esac
: > "$CASE_ROOT/restore-phase"
echo 'Synthetic health failure; no configuration content is logged.' >&2
exit 1
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
set -eu
case "$1" in
    show)
        [ "$RECOVERY_SCENARIO" != state_read_failed ] || exit 1
        cat "$CASE_ROOT/service-state"
        ;;
    is-active) [ "$(cat "$CASE_ROOT/service-state")" = active ] ;;
    stop)
        printf 'stop\n' >> "$CASE_ROOT/events"
        [ "$RECOVERY_SCENARIO" != initial_stop_failed ] || exit 1
        [ "$RECOVERY_SCENARIO" != stop_still_busy ] || exit 0
        if [ "$RECOVERY_SCENARIO" = stop_failed ] && [ -f "$CASE_ROOT/restore-phase" ]; then exit 1; fi
        printf 'inactive\n' > "$CASE_ROOT/service-state"
        ;;
    start)
        [ ! -e "$CASE_ROOT/probe-kernel-live" ] || { echo 'unsafe start with live probe' >&2; exit 98; }
        printf 'start\n' >> "$CASE_ROOT/events"
        starts=$(cat "$CASE_ROOT/start-count")
        printf '%s\n' "$((starts + 1))" > "$CASE_ROOT/start-count"
        printf 'active\n' > "$CASE_ROOT/service-state"
        if [ "$starts" = 0 ]; then cp "$CASE_ROOT/new-wg.conf" "$WG_CONF"; fi
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$TMP/bin/mv" <<'STUB'
#!/bin/sh
set -eu
for target in "$@"; do :; done
if [ -f "$CASE_ROOT/restore-phase" ]; then
    case "$RECOVERY_SCENARIO:$target" in
        env_write_failed:"$CFWARP_ENV_FILE"|wg_write_failed:"$WG_CONF")
            echo 'Synthetic atomic restore failure.' >&2
            exit 1
            ;;
    esac
fi
exec "$REAL_MV" "$@"
STUB
cat > "$TMP/bin/ip" <<'STUB'
#!/bin/sh
set -eu
[ "$1" = netns ] && [ "$2" = exec ] || exit 1
shift 3
exec "$@"
STUB
cat > "$TMP/bin/flock" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TMP/bin/setsid" <<'STUB'
#!/bin/sh
exec "$@"
STUB
cat > "$TMP/bin/timeout" <<'STUB'
#!/bin/sh
case "$1" in --kill-after=*) shift ;; esac
shift
exec "$@"
STUB
cat > "$TMP/bin/getent" <<'STUB'
#!/bin/sh
[ "$1" = ahostsv4 ] && [ "$2" = relay.example ] || exit 1
printf '192.0.2.20 STREAM relay.example\n'
STUB
chmod +x "$TMP/project/"*.sh "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

run_case() {
    RECOVERY_SCENARIO=$1
    CASE_ROOT="$TMP/case-$1"
    export RECOVERY_SCENARIO CASE_ROOT
    mkdir -p "$CASE_ROOT/data" "$CASE_ROOT/tmp"
    CFWARP_DATA_DIR="$CASE_ROOT/data"
    CFWARP_ENV_FILE="$CASE_ROOT/cfwarp.env"
    WG_CONF="$CFWARP_DATA_DIR/wg0.conf"
    export CFWARP_DATA_DIR CFWARP_ENV_FILE WG_CONF
    printf 'ENDPOINT_IP=192.0.2.10:2408\nSOCKS_PASS="recovery-secret-sentinel"\n' > "$CFWARP_ENV_FILE"
    printf '[Interface]\nPrivateKey = recovery-private-key-sentinel\n[Peer]\nEndpoint = 192.0.2.10:2408\n' > "$WG_CONF"
    cp "$CFWARP_ENV_FILE" "$CASE_ROOT/expected.env"
    cp "$WG_CONF" "$CASE_ROOT/expected-wg.conf"
    sed 's/192.0.2.10/192.0.2.20/' "$WG_CONF" > "$CASE_ROOT/new-wg.conf"
    printf 'active\n' > "$CASE_ROOT/service-state"
    active_mode=stop-and-probe
    case "$RECOVERY_SCENARIO" in
        skip_*|stop_activating|stop_deactivating|stop_reloading)
            printf '%s\n' "${RECOVERY_SCENARIO#*_}" > "$CASE_ROOT/service-state"
            case "$RECOVERY_SCENARIO" in skip_*) active_mode=skip ;; esac
            ;;
        state_unknown) printf 'unknown\n' > "$CASE_ROOT/service-state" ;;
    esac
    printf '0\n' > "$CASE_ROOT/start-count"
    printf '0\n' > "$CASE_ROOT/health-count"
    : > "$CASE_ROOT/events"
    test_candidates=192.0.2.20:2408
    [ "$RECOVERY_SCENARIO" != success_hostname ] || test_candidates=relay.example:2408
    run_status=0
    TMPDIR="$CASE_ROOT/tmp" CFWARP_ENV_LOADED=1 CFWARP_MODE=netns-proxy \
        CFWARP_ENDPOINT_REFRESH_STATE_ROOT="$CASE_ROOT/run" \
        CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE="$active_mode" \
        ENDPOINT_IP=192.0.2.10:2408 ENDPOINT_CANDIDATES="$test_candidates" \
        sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$CASE_ROOT/output" 2>&1 || run_status=$?
    case "$RECOVERY_SCENARIO" in
        skip_*|state_read_failed|state_unknown|initial_stop_failed|stop_still_busy)
            case "$RECOVERY_SCENARIO" in skip_*) [ "$run_status" = 0 ] || fail 'busy skip failed' ;; *) [ "$run_status" != 0 ] || fail 'unsafe state accepted' ;; esac
            [ ! -e "$CASE_ROOT/probe-targets" ] || fail 'probe reached before confirmed stop'
            [ "$(cat "$CASE_ROOT/start-count")" = 0 ] || fail 'unsafe state caused a start'
            cmp "$CFWARP_ENV_FILE" "$CASE_ROOT/expected.env" || fail 'refusal changed configuration'
            return 0
            ;;
        stop_activating|stop_deactivating|stop_reloading)
            [ "$run_status" = 0 ] || { cat "$CASE_ROOT/output"; fail 'transitional stop/probe failed'; }
            [ "$(head -n 1 "$CASE_ROOT/events")" = stop ] || fail 'probe was not preceded by stop'
            [ "$(cat "$CASE_ROOT/start-count")" = 1 ] || fail 'transitional service was not restored'
            return 0
            ;;
    esac
    if [ "$RECOVERY_SCENARIO" = success ] || [ "$RECOVERY_SCENARIO" = success_hostname ]; then
        [ "$run_status" -eq 0 ] || { cat "$CASE_ROOT/output" >&2; fail 'successful deployment failed'; }
        [ -z "$(find "$CFWARP_DATA_DIR/recovery" -name original.env -print 2>/dev/null)" ] || fail 'successful run retained its backup'
        if [ "$RECOVERY_SCENARIO" = success_hostname ]; then
            grep -Fx 'ENDPOINT_IP="relay.example:2408"' "$CFWARP_ENV_FILE" >/dev/null || fail 'hostname candidate identity was not preserved'
            grep -Fx '192.0.2.20:2408' "$CASE_ROOT/probe-targets" >/dev/null || fail 'candidate was not resolved before probing'
        fi
        return 0
    fi
    [ "$run_status" -ne 0 ] || fail "$RECOVERY_SCENARIO reported success"
    RECOVERY_ENV=$(find "$CFWARP_DATA_DIR/recovery" -name original.env -print 2>/dev/null || true)
    [ -n "$RECOVERY_ENV" ] || fail "$RECOVERY_SCENARIO lost the original environment backup"
    RECOVERY_DIR=$(dirname "$RECOVERY_ENV")
    cmp "$RECOVERY_ENV" "$CASE_ROOT/expected.env" || fail "$RECOVERY_SCENARIO damaged original env"
    cmp "$RECOVERY_DIR/original-wg.conf" "$CASE_ROOT/expected-wg.conf" || fail "$RECOVERY_SCENARIO damaged original WG config"
    [ -s "$RECOVERY_DIR/RECOVERY.txt" ] || fail 'manual recovery instructions missing'
    [ -s "$RECOVERY_DIR/recovery.log" ] || fail 'recovery log missing'
    grep -F "$RECOVERY_DIR" "$CASE_ROOT/output" >/dev/null || fail 'operator was not given recovery path'
    if grep -F -e recovery-secret-sentinel -e recovery-private-key-sentinel "$CASE_ROOT/output" "$RECOVERY_DIR/recovery.log" "$RECOVERY_DIR/RECOVERY.txt" >/dev/null; then fail 'secret configuration content leaked into diagnostics'; fi
    permissions=$(stat -c '%a' "$RECOVERY_DIR" 2>/dev/null || stat -f '%Lp' "$RECOVERY_DIR")
    [ "$permissions" = 700 ] || fail 'recovery directory is not private'
    for protected in original.env original-wg.conf RECOVERY.txt recovery.log; do
        permissions=$(stat -c '%a' "$RECOVERY_DIR/$protected" 2>/dev/null || stat -f '%Lp' "$RECOVERY_DIR/$protected")
        [ "$permissions" = 600 ] || fail "recovery file permissions are unsafe: $protected"
    done
    case "$RECOVERY_SCENARIO" in
        probe_cleanup_failed)
            [ "$(cat "$CASE_ROOT/start-count")" = 0 ] || fail 'failed cleanup restarted main'
            [ -e "$CFWARP_DATA_DIR/.refresh-pending" ] || fail 'failed cleanup lost startup block'
            if CFWARP_ENV_LOADED=1 sh "$TMP/project/cfwarp-start.sh" > "$CASE_ROOT/blocked-start" 2>&1; then fail 'pending cleanup allowed a later startup'; fi
            grep -F '.refresh-pending' "$CASE_ROOT/blocked-start" >/dev/null || { cat "$CASE_ROOT/blocked-start" >&2; fail 'startup did not explain pending recovery'; }
            rm -f "$CASE_ROOT/probe-kernel-live"
            ;;
        env_write_failed|wg_write_failed|stop_failed)
            [ "$(cat "$CASE_ROOT/start-count")" = 1 ] || fail 'partially restored service was started'
            ;;
        verify_failed|recovered)
            cmp "$CFWARP_ENV_FILE" "$CASE_ROOT/expected.env" || fail 'original env was not restored'
            cmp "$WG_CONF" "$CASE_ROOT/expected-wg.conf" || fail 'original WG config was not restored'
            [ "$(cat "$CASE_ROOT/start-count")" = 2 ] || fail 'recovered service was not checked'
            ;;
    esac
    # Later successful refreshes may clean only their own run directory.
    SAVED_RECOVERY_DIR=$RECOVERY_DIR
    RECOVERY_SCENARIO=success
    export RECOVERY_SCENARIO
    rm -f "$CASE_ROOT/restore-phase"
    # Model an operator completing recovery before permitting another refresh.
    cp "$CASE_ROOT/expected.env" "$CFWARP_ENV_FILE"
    cp "$CASE_ROOT/expected-wg.conf" "$WG_CONF"
    rm -f "$CFWARP_DATA_DIR/.refresh-pending"
    printf 'active\n' > "$CASE_ROOT/service-state"
    TMPDIR="$CASE_ROOT/tmp" CFWARP_ENV_LOADED=1 CFWARP_MODE=netns-proxy \
        CFWARP_ENDPOINT_REFRESH_STATE_ROOT="$CASE_ROOT/run" \
        CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe \
        ENDPOINT_IP=192.0.2.10:2408 ENDPOINT_CANDIDATES=192.0.2.20:2408 \
        sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$CASE_ROOT/rerun-output" 2>&1 || { cat "$CASE_ROOT/rerun-output" >&2; fail 'later successful refresh failed'; }
    cmp "$SAVED_RECOVERY_DIR/original.env" "$CASE_ROOT/expected.env" || fail 'later refresh removed previous recovery evidence'
    cmp "$SAVED_RECOVERY_DIR/original-wg.conf" "$CASE_ROOT/expected-wg.conf" || fail 'later refresh changed previous recovery evidence'
}

for scenario in env_write_failed wg_write_failed verify_failed recovered stop_failed success success_hostname \
    skip_activating skip_deactivating skip_reloading stop_activating stop_deactivating stop_reloading \
    state_read_failed state_unknown initial_stop_failed stop_still_busy probe_cleanup_failed; do
    run_case "$scenario"
done
echo 'CFWarp refresh recovery regression tests passed'
