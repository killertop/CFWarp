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
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d /tmp/cfwarp-install-test.XXXXXX)
cleanup() {
    if [ -e "$TMP_DIR/runtime/lib/cfwarp-common.sh" ]; then run_install --clean-generated >/dev/null 2>&1 || true; fi
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
run_install --clean-generated > "$TMP_DIR/clean.log" 2>&1
test -f "$TMP_DIR/env/cfwarp.env"
test -d "$TMP_DIR/data"
test ! -e "$TMP_DIR/runtime/lib/cfwarp-common.sh"
test ! -e "$TMP_DIR/runtime/deploy/installation.env"
test ! -e "$TMP_DIR/bin/cfwarp"
test ! -e "$TMP_DIR/bin/wg-quick"
echo 'CFwarp installation regressions passed'
