#!/bin/sh
# No root or Linux networking required: exercise function calls under if/||.
set -eu
umask 077
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
sed '/^case "$ACTION" in up|down/,$d' "$ROOT_DIR/cfwarp-netns.sh" > "$TEST_DIR/functions.sh"
cat > "$TEST_DIR/bin/flock" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$TEST_DIR/bin/sysctl" <<'STUB'
#!/bin/sh
touch "$CFWARP_LOCK_TEST_DIR/kernel-write"
exit 0
STUB
chmod +x "$TEST_DIR/bin/"*
env CFWARP_ENV_LOADED=1 CFWARP_STATE_DIR="$TEST_DIR" CFWARP_GLOBAL_STATE_DIR="$TEST_DIR" \
    CFWARP_LOCK_TEST_DIR="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" \
    sh -c '
        . "$1/functions.sh"
        if lock_ip_forward_state; then echo "FAIL: lock failure reported success" >&2; exit 1; fi
        [ "$CFWARP_FORWARD_LOCKED" = 0 ]
        if acquire_ip_forward_ref; then echo "FAIL: acquire ignored lock failure" >&2; exit 1; fi
        [ "$CFWARP_FORWARD_LOCKED" = 0 ]
        [ ! -e "$IP_FORWARD_REF_FILE" ]
        [ ! -e "$IP_FORWARD_PREV_FILE" ]
        printf "2\n" > "$IP_FORWARD_REF_FILE"
        printf "0\n" > "$IP_FORWARD_PREV_FILE"
        printf "preserved\n" > "$STATE_FILE"
        IP_FORWARD_REF_HELD=1
        if release_ip_forward_ref; then echo "FAIL: release ignored lock failure" >&2; exit 1; fi
        [ "$CFWARP_FORWARD_LOCKED" = 0 ]
        [ "$(cat "$IP_FORWARD_REF_FILE")" = 2 ]
        [ "$(cat "$IP_FORWARD_PREV_FILE")" = 0 ]
        [ "$(cat "$STATE_FILE")" = preserved ]
        [ ! -e "$1/kernel-write" ]
    ' "$ROOT_DIR/cfwarp-netns.sh" "$TEST_DIR"
printf '%s\n' 'PASS: failed flock in conditional calls preserves forwarding refs, state and kernel'
