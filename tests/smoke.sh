#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() {
    echo "smoke test failed: $*" >&2
    exit 1
}

SCRIPTS="
    entrypoint.sh
    cfwarp-start.sh
    cfwarp-stop.sh
    cfwarp-netns.sh
    cfwarp-refresh-endpoint.sh
    cfwarp-healthcheck.sh
    cfwarp-watchdog.sh
    cfwarp-doctor.sh
    cfwarp-exec
    install.sh
    lib/cfwarp-common.sh
"

for relative in $SCRIPTS; do
    [ -f "$ROOT/$relative" ] || fail "missing file: $relative"
    sh -n "$ROOT/$relative" || fail "syntax error: $relative"
done

CFWARP_TEST_MODE=1 sh "$ROOT/entrypoint.sh"
CFWARP_TEST_MODE=1 sh "$ROOT/cfwarp-start.sh"
sh "$ROOT/install.sh" --help >/dev/null
sh "$ROOT/cfwarp-healthcheck.sh" --help >/dev/null
sh "$ROOT/cfwarp-doctor.sh" --help >/dev/null

# Exercise the shared validators and an atomic env-file update without using
# any production path or credential.
# shellcheck disable=SC1090
. "$ROOT/lib/cfwarp-common.sh"
cfwarp_validate_endpoint '198.51.100.10:2408' || fail 'valid endpoint rejected'
cfwarp_validate_endpoint '[2001:db8::10]:2408' || fail 'valid IPv6 endpoint rejected'
if cfwarp_validate_endpoint '198.51.100.10'; then
    fail 'endpoint without port accepted'
fi
if cfwarp_validate_port 0 test-port 2>/dev/null; then
    fail 'port zero accepted'
fi

cp "$ROOT/deploy/cfwarp.env.example" "$TMP_DIR/env"
chmod 0600 "$TMP_DIR/env"
cfwarp_set_env_key CFWARP_DATA_DIR /tmp/cfwarp-smoke-data "$TMP_DIR/env"
grep -Fx 'CFWARP_DATA_DIR=/tmp/cfwarp-smoke-data' "$TMP_DIR/env" >/dev/null

if git -C "$ROOT" diff --check; then
    :
else
    fail 'whitespace errors found'
fi

PRIVATE_WORD=hack
PRIVATE_WORD="${PRIVATE_WORD}ertop"
PRIVATE_IP='134.195'
PRIVATE_IP="${PRIVATE_IP}.209.158"
PRIVATE_KEY_PREFIX=BEGIN
PRIVATE_KEY_PREFIX="${PRIVATE_KEY_PREFIX} (RSA|OPENSSH|EC|DSA) PRIVATE KEY"
PRIVATE_FEATURE=CFWARP_
PRIVATE_FEATURE="${PRIVATE_FEATURE}OPENAI"
PRIVATE_PATH=/opt
PRIVATE_PATH="${PRIVATE_PATH}/web/CFwarp"
if rg -n --hidden --glob '!.git/**' \
    -e "$PRIVATE_WORD" \
    -e "$PRIVATE_IP" \
    -e "$PRIVATE_KEY_PREFIX" \
    -e "$PRIVATE_FEATURE" \
    -e "$PRIVATE_PATH" \
    "$ROOT" >/dev/null 2>&1; then
    fail 'private or server-specific material found'
fi

echo 'CFwarp smoke tests passed'
