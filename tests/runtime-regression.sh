#!/bin/sh
# Deterministic runtime regressions; all networking commands are local fakes.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
fail() { echo "runtime regression failed: $*" >&2; exit 1; }
mkdir -p "$TMP/project/lib" "$TMP/bin" "$TMP/data"
cp "$ROOT/lib/cfwarp-common.sh" "$TMP/project/lib/"
for script in entrypoint.sh cfwarp-healthcheck.sh cfwarp-doctor.sh cfwarp-refresh-endpoint.sh cfwarp-start.sh cfwarp-stop.sh cfwarp-watchdog.sh cfwarp-exec; do
    cp "$ROOT/$script" "$TMP/project/$script"
done
cat > "$TMP/project/cfwarp-netns.sh" <<'STUB'
#!/bin/sh
set -eu
case "$1" in
    up)
        [ ! -e "$FAKE_ROOT/netns-active" ] || { echo concurrent_probe >&2; exit 1; }
        touch "$FAKE_ROOT/netns-active"
        printf 'up\n' >> "$FAKE_ROOT/network-events"
        ;;
    down)
        if [ -e "$FAKE_ROOT/child-pid" ]; then
            status=$(ps -o stat= -p "$(cat "$FAKE_ROOT/child-pid")" 2>/dev/null || true)
            case "$status" in ''|*Z*) ;; *) echo live_child_at_teardown >> "$FAKE_ROOT/network-events"; exit 1 ;; esac
        fi
        rm -f "$FAKE_ROOT/netns-active"
        printf 'down\n' >> "$FAKE_ROOT/network-events"
        ;;
esac
STUB
cat > "$TMP/bin/wg-quick" <<'STUB'
#!/bin/sh
set -eu
printf '%s %s\n' "$1" "$2" >> "$FAKE_ROOT/wg-quick.log"
case "$1" in
    up)
        [ "${FAKE_WG_UP_FAIL:-0}" = 0 ] || exit 1
        if grep -F stale.invalid "$2" >/dev/null; then exit 1; fi
        if [ "${FAKE_WRONG_ENDPOINT:-0}" = 1 ]; then
            printf '192.0.2.10:2408\n' > "$FAKE_ROOT/active-endpoint"
        else
            awk '/^Endpoint[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$2" > "$FAKE_ROOT/active-endpoint"
        fi
        ;;
    down) rm -f "$FAKE_ROOT/active-endpoint" ;;
esac
STUB
cat > "$TMP/bin/wg" <<'STUB'
#!/bin/sh
set -eu
if [ "$1" = set ]; then
    [ "${FAKE_WRONG_ENDPOINT:-0}" = 0 ] || exit 0
    printf '%s\n' "$6" > "$FAKE_ROOT/active-endpoint"
elif [ "$1" = show ]; then
    case "$3" in
        peers) printf 'test-public-key\n' ;;
        endpoints) [ ! -f "$FAKE_ROOT/active-endpoint" ] || printf 'test-public-key\t%s\n' "$(cat "$FAKE_ROOT/active-endpoint")" ;;
        latest-handshakes) printf 'test-public-key\t1\n' ;;
    esac
fi
STUB
cat > "$TMP/bin/ip" <<'STUB'
#!/bin/sh
set -eu
if [ "${1:-}" = netns ] && [ "${2:-}" = exec ]; then shift 3; exec "$@"; fi
if [ "${1:-}" = netns ] && [ "${2:-}" = list ]; then printf 'cfwarp\n'; fi
STUB
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/sh
set -eu
printf 'attempt\n' >> "$FAKE_ROOT/curl-attempts"
if [ "${FAKE_SLEEP:-0}" = 1 ]; then
    sleep 120 &
    printf '%s\n' "$!" > "$FAKE_ROOT/child-pid"
    wait "$!"
fi
[ "${FAKE_CURL_FAIL:-0}" = 0 ] || exit 22
active=$(cat "$FAKE_ROOT/active-endpoint" 2>/dev/null || true)
[ -z "${FAKE_FAIL_ENDPOINT:-}" ] || [ "$active" != "$FAKE_FAIL_ENDPOINT" ] || exit 22
output=
write_time=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output=$2; shift 2 ;;
        -w) write_time=1; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "${FAKE_WGCF_BINARY:-}" ] && [ "${output##*/}" = wgcf ]; then
    cp "$FAKE_WGCF_BINARY" "$output"
    exit 0
fi
if [ -n "$output" ]; then
    cat "$FAKE_ROOT/trace" > "$output"
else
    cat "$FAKE_ROOT/trace"
fi
[ "$write_time" = 0 ] || printf '0.125\n'
STUB
cat > "$TMP/bin/microsocks" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$TMP/bin/"* "$TMP/project/"*.sh "$TMP/project/cfwarp-exec"
export PATH="$TMP/bin:$PATH" FAKE_ROOT="$TMP"
export CFWARP_ENV_FILE="$TMP/runtime.env"
export CFWARP_DATA_DIR="$TMP/data" WG_INTERFACE=wg0 WG_CONF="$TMP/data/wg0.conf"
export WGCF_PROFILE="$TMP/data/wgcf-profile.conf" WG_QUICK_BIN="$TMP/bin/wg-quick"
export MICROSOCKS_BIN="$TMP/bin/microsocks" CFWARP_MODE=netns-proxy
export WARP_READY_ATTEMPTS=1 WARP_READY_DELAY_SECONDS=0 CFWARP_HEALTH_RETRY_DELAY_SECONDS=0
printf 'CFWARP_HEALTH_RETRIES=1\n' > "$CFWARP_ENV_FILE"
printf 'ip=198.51.100.42\ncolo=LOS\nwarp=on\n' > "$TMP/trace"
cat > "$WG_CONF" <<'CONF'
[Interface]
PrivateKey = test-private-key
Address = 172.16.0.2/32
# preserve-user-configuration
[Peer]
PublicKey = test-public-key
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.10:2408
CONF
sed 's/192.0.2.10/192.0.2.99/' "$WG_CONF" > "$WGCF_PROFILE"

# Network data can contain shell syntax without being interpreted.
printf "ip=198.51.100.42';touch %s/injected;#\ncolo=LOS\nwarp=on\n" "$TMP" > "$TMP/trace"
sh "$TMP/project/cfwarp-healthcheck.sh" --format env > "$TMP/health.out"
[ ! -e "$TMP/injected" ] || fail 'trace was executed as shell code'
grep -Fx 'CFWARP_EXIT_IP=unknown' "$TMP/health.out" >/dev/null || fail 'invalid IP was exported'
printf 'ip=198.51.100.42\ncolo=LOS\nwarp=on\n' > "$TMP/trace"

# Per-invocation retry settings override the saved environment.
: > "$TMP/curl-attempts"
if CFWARP_HEALTH_RETRIES=3 FAKE_CURL_FAIL=1 sh "$TMP/project/cfwarp-healthcheck.sh" > "$TMP/retry.out" 2>&1; then fail 'unhealthy request passed'; fi
[ "$(wc -l < "$TMP/curl-attempts" | tr -d ' ')" = 3 ] || fail 'caller retries were overwritten'

# A requested probe only measures its candidate; saved user configuration survives.
CFWARP_PROBE_MODE=1 ENDPOINT_IP=192.0.2.20:2408 CFWARP_PROBE_METRICS_FILE="$TMP/metrics" \
    sh "$TMP/project/entrypoint.sh" > "$TMP/probe.out" 2>&1 || { cat "$TMP/probe.out" >&2; fail 'explicit probe failed'; }
grep -Fx 'SELECTED_ENDPOINT=192.0.2.20:2408' "$TMP/metrics" >/dev/null || fail 'wrong candidate selected'
grep -Fx 'RUNTIME_ENDPOINT=192.0.2.20:2408' "$TMP/metrics" >/dev/null || fail 'runtime endpoint was not recorded'
grep -Fx 'Endpoint = 192.0.2.10:2408' "$WG_CONF" >/dev/null || fail 'probe persisted endpoint'
grep -Fx '# preserve-user-configuration' "$WG_CONF" >/dev/null || fail 'profile replaced user configuration'
if grep -Fx 'down wg0' "$TMP/wg-quick.log" >/dev/null; then fail 'wg-quick down used interface instead of full config path'; fi
rm -f "$TMP/metrics"
if CFWARP_PROBE_MODE=1 ENDPOINT_IP=192.0.2.20:2408 FAKE_FAIL_ENDPOINT=192.0.2.20:2408 \
    CFWARP_PROBE_METRICS_FILE="$TMP/metrics" sh "$TMP/project/entrypoint.sh" > "$TMP/fail-probe.out" 2>&1; then fail 'probe fell back to a different endpoint'; fi
[ ! -e "$TMP/metrics" ] || fail 'failed probe wrote metrics'
if CFWARP_PROBE_MODE=1 ENDPOINT_IP=192.0.2.20:2408 FAKE_WRONG_ENDPOINT=1 \
    sh "$TMP/project/entrypoint.sh" > "$TMP/wrong-probe.out" 2>&1; then fail 'runtime endpoint mismatch was accepted'; fi

# An old unresolvable hostname must never be passed to wg-quick when a new
# endpoint was explicitly selected. Both probe and startup failure restore bytes.
cp "$WG_CONF" "$TMP/base.conf"
sed 's/192.0.2.10/stale.invalid/' "$TMP/base.conf" > "$WG_CONF"
cp "$WG_CONF" "$TMP/stale-original.conf"
CFWARP_PROBE_MODE=1 ENDPOINT_IP=192.0.2.20:2408 CFWARP_PROBE_METRICS_FILE="$TMP/stale-metrics" \
    sh "$TMP/project/entrypoint.sh" > "$TMP/stale-probe.out" 2>&1 || { cat "$TMP/stale-probe.out" >&2; fail 'stale profile DNS blocked explicit endpoint'; }
cmp "$WG_CONF" "$TMP/stale-original.conf" || fail 'probe changed original config bytes'
if FAKE_WG_UP_FAIL=1 ENDPOINT_IP=192.0.2.20:2408 sh "$TMP/project/entrypoint.sh" > "$TMP/up-failure.out" 2>&1; then fail 'wg-quick failure passed'; fi
cmp "$WG_CONF" "$TMP/stale-original.conf" || fail 'wg-quick failure lost original config'
cp "$TMP/base.conf" "$WG_CONF"

# Watchdog owns its retry policy; inherited ordinary health options never
# override WATCHDOG settings. A single run can override WATCHDOG_* directly.
if [ -d /run/systemd/system ]; then
    cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
[ "$1" = is-active ]
STUB
    printf 'CFWARP_HEALTH_RETRIES=1\nCFWARP_WATCHDOG_RETRIES=4\nCFWARP_WATCHDOG_RETRY_DELAY_SECONDS=0\n' > "$CFWARP_ENV_FILE"
    : > "$TMP/curl-attempts"
    CFWARP_HEALTH_RETRIES=2 FAKE_CURL_FAIL=1 CFWARP_WATCHDOG_STATE_FILE="$TMP/watchdog-count" \
        sh "$TMP/project/cfwarp-watchdog.sh" > "$TMP/watchdog.out" 2>&1 || fail 'watchdog first observation failed'
    [ "$(wc -l < "$TMP/curl-attempts" | tr -d ' ')" = 4 ] || fail 'watchdog inherited ordinary health retries'
    rm -f "$TMP/watchdog-count"
    : > "$TMP/curl-attempts"
    CFWARP_HEALTH_RETRIES=2 CFWARP_WATCHDOG_RETRIES=5 FAKE_CURL_FAIL=1 CFWARP_WATCHDOG_STATE_FILE="$TMP/watchdog-count" \
        sh "$TMP/project/cfwarp-watchdog.sh" > "$TMP/watchdog-override.out" 2>&1 || fail 'watchdog override observation failed'
    [ "$(wc -l < "$TMP/curl-attempts" | tr -d ' ')" = 5 ] || fail 'watchdog explicit override ignored'
    cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
exit 1
STUB
fi
printf 'CFWARP_HEALTH_RETRIES=1\n' > "$CFWARP_ENV_FILE"

ENDPOINT_IP=192.0.2.20:2408 sh "$TMP/project/entrypoint.sh" > "$TMP/start.out" 2>&1 || fail 'normal startup failed'
ENDPOINT_IP='' sh "$TMP/project/entrypoint.sh" > "$TMP/restart.out" 2>&1 || fail 'restart failed'
grep -Fx 'Endpoint = 192.0.2.20:2408' "$WG_CONF" >/dev/null || fail 'restart discarded selected endpoint'

# A contender that times out on the host lock must not restore a pre-lock
# snapshot over a configuration update made by the live owner.
if command -v flock >/dev/null 2>&1; then
    mkdir -p "$TMP/host-lock-state" "$TMP/lock-bin"
    REAL_FLOCK=$(command -v flock)
    export REAL_FLOCK
    cat > "$TMP/lock-bin/flock" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" != -w ] || touch "$FAKE_ROOT/contender-locking"
exec "$REAL_FLOCK" "$@"
STUB
    chmod +x "$TMP/lock-bin/flock"
    cp "$WG_CONF" "$TMP/before-lock-test.conf"
    sed 's/192.0.2.20/192.0.2.10/' "$TMP/before-lock-test.conf" > "$WG_CONF"
    (
        exec 7> "$TMP/host-lock-state/wg0.flock"
        flock 7
        touch "$TMP/owner-locked"
        while [ ! -e "$TMP/contender-locking" ]; do sleep 0.1; done
        sed 's/192.0.2.10/192.0.2.20/' "$WG_CONF" > "$WG_CONF.owner"
        mv "$WG_CONF.owner" "$WG_CONF"
        cp "$WG_CONF" "$TMP/owner-updated.conf"
        sleep 2
    ) &
    owner_pid=$!
    while [ ! -e "$TMP/owner-locked" ]; do sleep 0.1; done
    if PATH="$TMP/lock-bin:$PATH" CFWARP_MODE=host-global CFWARP_HOST_STATE_DIR="$TMP/host-lock-state" CFWARP_HOST_LOCK_WAIT_SECONDS=1 \
        sh "$TMP/project/entrypoint.sh" > "$TMP/lock-timeout.out" 2>&1; then fail 'host lock contender unexpectedly started'; fi
    wait "$owner_pid"
    cmp "$WG_CONF" "$TMP/owner-updated.conf" || fail 'lock timeout overwrote owner configuration'
    cp "$TMP/before-lock-test.conf" "$WG_CONF"
fi

# Missing generated configs reuse an existing WARP account without registering
# or replacing it. This fixture is synthetic and never reads a real account.
if [ "$(uname -s)" = Linux ]; then
    mkdir -p "$TMP/rebuild-data"
    printf 'synthetic-existing-account\n' > "$TMP/rebuild-data/wgcf-account.toml"
    cp "$TMP/rebuild-data/wgcf-account.toml" "$TMP/account-original"
    cat > "$TMP/wgcf-fixture" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$1" >> "$FAKE_ROOT/wgcf-events"
case "$1" in
    register) printf 'replacement-account\n' > wgcf-account.toml ;;
    generate)
        cmp wgcf-account.toml "$FAKE_ROOT/account-original"
        [ "${FAKE_WGCF_FAIL_GENERATE:-0}" = 0 ] || exit 1
        cp "$FAKE_ROOT/base.conf" wgcf-profile.conf
        ;;
esac
STUB
    fixture_hash=$(sha256sum "$TMP/wgcf-fixture" | awk '{print $1}')
    CFWARP_DATA_DIR="$TMP/rebuild-data" WG_CONF="$TMP/rebuild-data/wg0.conf" \
        WGCF_PROFILE="$TMP/rebuild-data/wgcf-profile.conf" WGCF_ACCOUNT="$TMP/rebuild-data/wgcf-account.toml" \
        WGCF_SHA256="$fixture_hash" FAKE_WGCF_BINARY="$TMP/wgcf-fixture" ENDPOINT_IP=192.0.2.20:2408 \
        LEGACY_SYSTEM_WG_CONF="$TMP/no-legacy.conf" sh "$TMP/project/entrypoint.sh" > "$TMP/rebuild.out" 2>&1 || { cat "$TMP/rebuild.out" >&2; fail 'account regeneration failed'; }
    cmp "$TMP/rebuild-data/wgcf-account.toml" "$TMP/account-original" || fail 'account was overwritten during generation'
    [ "$(cat "$TMP/wgcf-events")" = generate ] || fail 'existing account was registered again'
    rm -f "$TMP/rebuild-data/wg0.conf" "$TMP/rebuild-data/wgcf-profile.conf"
    if CFWARP_DATA_DIR="$TMP/rebuild-data" WG_CONF="$TMP/rebuild-data/wg0.conf" \
        WGCF_PROFILE="$TMP/rebuild-data/wgcf-profile.conf" WGCF_ACCOUNT="$TMP/rebuild-data/wgcf-account.toml" \
        WGCF_SHA256="$fixture_hash" FAKE_WGCF_BINARY="$TMP/wgcf-fixture" FAKE_WGCF_FAIL_GENERATE=1 \
        LEGACY_SYSTEM_WG_CONF="$TMP/no-legacy.conf" sh "$TMP/project/entrypoint.sh" > "$TMP/rebuild-failure.out" 2>&1; then fail 'failed generation passed'; fi
    cmp "$TMP/rebuild-data/wgcf-account.toml" "$TMP/account-original" || fail 'failed generation changed account'
    [ "$(cat "$TMP/wgcf-events")" = "$(printf 'generate\ngenerate')" ] || fail 'failed recovery registered an account'
fi

# An installed runtime intentionally has no installer script.
CFWARP_ENV_FILE="$TMP/not-installed.env" CFWARP_SERVICE_NAME=cfwarp-regression-uninstalled.service sh "$TMP/project/cfwarp-doctor.sh" > "$TMP/doctor.out" 2>&1 || { cat "$TMP/doctor.out" >&2; fail 'doctor rejected installed runtime manifest'; }

# Process-group tests require the same Linux utilities as production refresh.
if command -v setsid >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && command -v flock >/dev/null 2>&1; then
    export CFWARP_ENDPOINT_REFRESH_STATE_ROOT="$TMP/refresh-state"
    export CFWARP_ENDPOINT_CANDIDATE_TIMEOUT_SECONDS=5
    CFWARP_MODE=netns-proxy ENDPOINT_IP=192.0.2.20:2408 ENDPOINT_CANDIDATES=192.0.2.30:2408 \
        FAKE_FAIL_ENDPOINT=192.0.2.20:2408 sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$TMP/refresh.out" 2>&1 || { cat "$TMP/refresh.out" >&2; fail 'refresh failed to replace unhealthy current endpoint'; }
    # shellcheck disable=SC1090
    . "$ROOT/lib/cfwarp-common.sh"
    [ "$(cfwarp_read_env_key ENDPOINT_IP "$CFWARP_ENV_FILE")" = 192.0.2.30:2408 ] || fail 'unhealthy current endpoint retained'
    [ "$(cat "$TMP/network-events")" = "$(printf 'up\ndown\nup\ndown')" ] || fail 'probe namespaces overlapped'
    if CFWARP_MODE=netns-proxy ENDPOINT_IP=192.0.2.20:2408 ENDPOINT_CANDIDATES='' FAKE_SLEEP=1 \
        sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$TMP/timeout.out" 2>&1; then fail 'timed out candidates passed refresh'; fi
    [ ! -e "$TMP/netns-active" ] || fail 'timeout leaked namespace'
    if grep -F live_child_at_teardown "$TMP/network-events" >/dev/null; then fail 'namespace deleted before probe children exited'; fi
    rm -f "$TMP/child-pid"
    CFWARP_MODE=netns-proxy ENDPOINT_IP=192.0.2.20:2408 ENDPOINT_CANDIDATES='' FAKE_SLEEP=1 \
        sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$TMP/signal.out" 2>&1 &
    refresh_pid=$!
    tries=0
    while [ ! -e "$TMP/child-pid" ] && [ "$tries" -lt 10 ]; do sleep 1; tries=$((tries + 1)); done
    [ -e "$TMP/child-pid" ] || fail 'probe worker did not start'
    kill -TERM "$refresh_pid"
    if wait "$refresh_pid"; then fail 'interrupted refresh reported success'; fi
    [ ! -e "$TMP/netns-active" ] || fail 'signal leaked namespace'
    if grep -F live_child_at_teardown "$TMP/network-events" >/dev/null; then fail 'signal left live probe child'; fi
    # systemctl accepting a start is insufficient: failed health rolls back both
    # files, restarts the old service, and verifies recovery before returning.
    if [ -d /run/systemd/system ]; then
        cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
set -eu
case "$1" in
    is-active) [ "$(cat "$FAKE_ROOT/service-state")" = active ] ;;
    stop)
        printf 'stop\n' >> "$FAKE_ROOT/service-events"
        printf 'stopped\n' > "$FAKE_ROOT/service-state"
        ;;
    start)
        printf 'start\n' >> "$FAKE_ROOT/service-events"
        starts=$(cat "$FAKE_ROOT/service-starts")
        printf '%s\n' "$((starts + 1))" > "$FAKE_ROOT/service-starts"
        printf 'active\n' > "$FAKE_ROOT/service-state"
        if [ "$starts" = 0 ]; then
            sed 's/192.0.2.20/192.0.2.30/' "$WG_CONF" > "$WG_CONF.changed"
            mv "$WG_CONF.changed" "$WG_CONF"
        fi
        ;;
    *) exit 1 ;;
esac
STUB
        cat > "$TMP/project/cfwarp-healthcheck.sh" <<'STUB'
#!/bin/sh
set -eu
if [ "$(cat "$FAKE_ROOT/service-starts")" -le 1 ]; then
    printf 'health-failed\n' >> "$FAKE_ROOT/service-events"
    exit 1
fi
printf 'health-ok\n' >> "$FAKE_ROOT/service-events"
STUB
        rm -f "$TMP/child-pid"
        printf 'active\n' > "$TMP/service-state"
        printf '0\n' > "$TMP/service-starts"
        printf 'ENDPOINT_IP=192.0.2.20:2408\n' > "$CFWARP_ENV_FILE"
        cp "$CFWARP_ENV_FILE" "$TMP/rollback-original.env"
        cp "$WG_CONF" "$TMP/rollback-original.conf"
        if CFWARP_MODE=netns-proxy CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe \
            ENDPOINT_IP=192.0.2.20:2408 ENDPOINT_CANDIDATES=192.0.2.30:2408 FAKE_FAIL_ENDPOINT=192.0.2.20:2408 \
            sh "$TMP/project/cfwarp-refresh-endpoint.sh" > "$TMP/rollback.out" 2>&1; then fail 'failed deployed health was reported successful'; fi
        cmp "$CFWARP_ENV_FILE" "$TMP/rollback-original.env" || fail 'rollback lost original env'
        cmp "$WG_CONF" "$TMP/rollback-original.conf" || fail 'rollback lost original WireGuard config'
        [ "$(cat "$TMP/service-events")" = "$(printf 'stop\nstart\nhealth-failed\nstop\nstart\nhealth-ok')" ] || { cat "$TMP/rollback.out" >&2; fail 'rollback did not verify recovery'; }
    fi
else
    echo 'SKIP Linux refresh process-group checks (setsid/timeout/flock unavailable)'
fi
echo 'CFwarp runtime regression tests passed'
