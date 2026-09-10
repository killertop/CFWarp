#!/bin/sh
# Transaction faults use real files and separate shell processes, with only
# kernel/lock commands replaced. No root or network changes are required.
set -eu
umask 077
ROOT_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'exit 143' HUP INT TERM
fail() { echo "forwarding refcount regression failed: $*" >&2; exit 1; }
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
export REAL_MV REAL_RM
mkdir "$TEST_DIR/bin"
sed '/^case "$ACTION" in up|down/,$d' "$ROOT_DIR/cfwarp-netns.sh" > "$TEST_DIR/functions.sh"

cat > "$TEST_DIR/bin/flock" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$TEST_DIR/bin/mv" <<'STUB'
#!/bin/sh
set -eu
for target in "$@"; do :; done
point=
case "$target" in
    "$CFWARP_GLOBAL_STATE_DIR/ip_forward.pending") point=journal ;;
    "$CFWARP_GLOBAL_STATE_DIR/ip_forward.prev") point=prev ;;
    "$CFWARP_GLOBAL_STATE_DIR/ip_forward.refs") point=refs ;;
    "$CFWARP_REF_FAULT_STATE") point=state ;;
esac
if [ -n "$point" ] && [ "$point" = "${CFWARP_REF_FAULT:-}" ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = before ]; then exit 91; fi
"$REAL_MV" "$@"
printf 'write %s\n' "$point" >> "$CFWARP_REF_TEST_ROOT/trace"
if [ -n "$point" ] && [ "$point" = "${CFWARP_REF_FAULT:-}" ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = after ]; then exit 92; fi
STUB
cat > "$TEST_DIR/bin/rm" <<'STUB'
#!/bin/sh
set -eu
if [ "${1:-}" != -f ]; then exec "$REAL_RM" "$@"; fi
shift
for target in "$@"; do
    point=
    case "$target" in
        "$CFWARP_GLOBAL_STATE_DIR/ip_forward.pending") point=remove-journal ;;
        "$CFWARP_GLOBAL_STATE_DIR/ip_forward.prev") point=remove-prev ;;
        "$CFWARP_GLOBAL_STATE_DIR/ip_forward.refs") point=remove-refs ;;
    esac
    if [ -n "$point" ] && [ "$point" = "${CFWARP_REF_FAULT:-}" ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = before ]; then exit 93; fi
    "$REAL_RM" -f "$target"
    printf 'remove %s\n' "$point" >> "$CFWARP_REF_TEST_ROOT/trace"
    if [ -n "$point" ] && [ "$point" = "${CFWARP_REF_FAULT:-}" ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = after ]; then exit 94; fi
done
STUB
cat > "$TEST_DIR/bin/sysctl" <<'STUB'
#!/bin/sh
set -eu
if [ "$1" = -n ]; then cat "$CFWARP_REF_TEST_ROOT/kernel"; exit; fi
[ "$1" = -w ] || exit 1
if [ "${CFWARP_REF_FAULT:-}" = kernel ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = before ]; then exit 95; fi
printf '%s\n' "${2##*=}" > "$CFWARP_REF_TEST_ROOT/kernel"
printf 'kernel %s\n' "${2##*=}" >> "$CFWARP_REF_TEST_ROOT/trace"
if [ "${CFWARP_REF_FAULT:-}" = kernel ] && [ "${CFWARP_REF_FAULT_MODE:-before}" = after ]; then exit 96; fi
STUB
chmod +x "$TEST_DIR/bin/"*

prepare_case() {
    CASE_DIR="$TEST_DIR/$1"
    mkdir -p "$CASE_DIR/global" "$CASE_DIR/state a" "$CASE_DIR/state b" "$CASE_DIR/state c"
    CFWARP_REF_TEST_ROOT=$CASE_DIR
    CFWARP_GLOBAL_STATE_DIR="$CASE_DIR/global"
    CFWARP_REF_FAULT_STATE="$CASE_DIR/state a/a.env"
    export CFWARP_REF_TEST_ROOT CFWARP_GLOBAL_STATE_DIR CFWARP_REF_FAULT_STATE
    for instance in a b c; do
        case "$instance" in a) inode=101 ;; b) inode=202 ;; c) inode=303 ;; esac
        printf 'NS_INODE=%s\nDNS_CREATED=1\nIP_FORWARD_REF_HELD=0\n' "$inode" > "$CASE_DIR/state $instance/$instance.env"
    done
    printf '%s\n' "$2" > "$CASE_DIR/kernel"
    : > "$CASE_DIR/trace"
    unset CFWARP_REF_FAULT CFWARP_REF_FAULT_MODE
}
set_held() {
    sed "s/^IP_FORWARD_REF_HELD=.*/IP_FORWARD_REF_HELD=$2/" "$CASE_DIR/state $1/$1.env" > "$CASE_DIR/state.new"
    mv "$CASE_DIR/state.new" "$CASE_DIR/state $1/$1.env"
}
held() { awk -F= '$1=="IP_FORWARD_REF_HELD" {print $2}' "$CASE_DIR/state $1/$1.env"; }
refs() { if [ -e "$CASE_DIR/global/ip_forward.refs" ]; then cat "$CASE_DIR/global/ip_forward.refs"; else printf 'absent\n'; fi; }
run_operation() {
    env CFWARP_ENV_LOADED=1 CFWARP_STATE_DIR="$CASE_DIR/state $1" NETNS_NAME="$1" \
        CFWARP_TEST_FUNCTIONS="$TEST_DIR/functions.sh" CFWARP_TEST_OPERATION="$2" \
        PATH="$TEST_DIR/bin:$PATH" \
        sh -c '
            . "$CFWARP_TEST_FUNCTIONS"
            CFWARP_NS_INODE=$(state_value NS_INODE)
            IP_FORWARD_REF_HELD=$(forward_state_held "$STATE_FILE")
            case "$CFWARP_TEST_OPERATION" in
                acquire-exit|teardown-test)
                    # Exercise the production EXIT/teardown functions, while
                    # every network call and inode lookup remains a fixture.
                    WG_QUICK_BIN=/usr/bin/true
                    RESOLV_DIR="$CFWARP_REF_TEST_ROOT/dns"
                    namespace_inode() { [ ! -e "$CFWARP_REF_TEST_ROOT/namespace" ] || printf "101\n"; }
                    link_index() { :; }
                    delete_rule_all() { :; }
                    stat() { printf "404\n"; }
                    ip() {
                        if [ "${1:-} ${2:-}" = "netns del" ]; then rm -f "$CFWARP_REF_TEST_ROOT/namespace"; fi
                        return 0
                    }
                    ;;
            esac
            case "$CFWARP_TEST_OPERATION" in
                acquire) acquire_ip_forward_ref ;;
                release) release_ip_forward_ref ;;
                acquire-exit)
                    fault=$CFWARP_REF_FAULT
                    unset CFWARP_REF_FAULT
                    CFWARP_DNS_CREATED=1
                    CFWARP_DNS_INODE=404
                    CFWARP_RULES_STARTED=1
                    write_state_file
                    CFWARP_REF_FAULT=$fault
                    export CFWARP_REF_FAULT
                    CFWARP_SETUP_ACTIVE=1
                    trap cleanup_exit EXIT
                    acquire_ip_forward_ref
                    ;;
                teardown-test) teardown ;;
                release-then-write)
                    if release_ip_forward_ref; then exit 88; fi
                    unset CFWARP_REF_FAULT
                    CFWARP_DNS_CREATED=0
                    CFWARP_RULES_STARTED=0
                    write_state_file
                    ;;
                stale-write)
                    IP_FORWARD_REF_HELD=1
                    CFWARP_DNS_CREATED=0
                    write_state_file
                    ;;
            esac
        ' "$ROOT_DIR/cfwarp-netns.sh" > "$CASE_DIR/output" 2>&1
}

# Original failure: a shared count reaches one but the releasing owner's HELD
# write fails. Neither its retry nor another STATE_DIR may bypass the journal.
prepare_case repeated-release 1
printf '2\n' > "$CASE_DIR/global/ip_forward.refs"
printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
set_held a 1
set_held b 1
CFWARP_REF_FAULT=state
export CFWARP_REF_FAULT
if run_operation a release; then fail 'state failure reported success'; fi
[ "$(refs)" = 1 ] && [ "$(held a)" = 1 ] || fail 'first failure was not reproduced'
if run_operation a release; then fail 'persistent failure was ignored'; fi
if run_operation c acquire; then fail 'another STATE_DIR bypassed the pending transaction'; fi
[ "$(refs)" = 1 ] && [ "$(held b)" = 1 ] && [ "$(held c)" = 0 ] || fail 'blocked retries changed membership'
[ "$(cat "$CASE_DIR/kernel")" = 1 ] || fail 'retry disabled another owner forwarding'
unset CFWARP_REF_FAULT
run_operation a release || { cat "$CASE_DIR/output" >&2; fail 'release retry did not recover'; }
[ "$(refs)" = 1 ] && [ "$(held a)" = 0 ] && [ "$(held b)" = 1 ] || fail 'release retried its decrement'
run_operation b release || fail 'last owner could not release'
[ "$(cat "$CASE_DIR/kernel")" = 0 ] && [ "$(refs)" = absent ] || fail 'last release did not restore the original kernel setting'

# Failed acquisition must be reconciled and released once during setup cleanup.
prepare_case acquire-cleanup 1
printf '1\n' > "$CASE_DIR/global/ip_forward.refs"
printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
set_held b 1
CFWARP_REF_FAULT=state
export CFWARP_REF_FAULT
if run_operation a acquire; then fail 'acquire state fault passed'; fi
[ "$(refs)" = 2 ] && [ "$(held a)" = 0 ] || fail 'acquire state fault was not reached'
unset CFWARP_REF_FAULT
run_operation a release || fail 'failed acquisition could not be cleaned up'
[ "$(refs)" = 1 ] && [ "$(held a)" = 0 ] && [ "$(held b)" = 1 ] || fail 'acquire cleanup leaked or double-released a reference'
[ "$(cat "$CASE_DIR/kernel")" = 1 ] || fail 'acquire cleanup disabled another owner'

# Setup's actual EXIT cleanup first removes its network resources, then hits
# the same pending acquisition. A later teardown finishes it without leaking
# the reference or touching another STATE_DIR's forwarding membership.
prepare_case acquire-exit-cleanup 1
printf '1\n' > "$CASE_DIR/global/ip_forward.refs"
printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
set_held b 1
mkdir "$CASE_DIR/dns"
printf 'fixture\n' > "$CASE_DIR/dns/resolv.conf"
touch "$CASE_DIR/namespace"
CFWARP_REF_FAULT=state
export CFWARP_REF_FAULT
if run_operation a acquire-exit; then fail 'failed acquisition EXIT reported success'; fi
[ ! -e "$CASE_DIR/namespace" ] && [ ! -e "$CASE_DIR/dns" ] || fail 'EXIT teardown did not remove its fixture resources'
[ -e "$CASE_DIR/global/ip_forward.pending" ] && [ "$(refs)" = 2 ] || fail 'EXIT lost the pending acquisition'
unset CFWARP_REF_FAULT
run_operation a teardown-test || { cat "$CASE_DIR/output" >&2; fail 'teardown retry could not finish failed setup'; }
[ ! -e "$CASE_DIR/state a/a.env" ] && [ "$(refs)" = 1 ] && [ "$(held b)" = 1 ] || fail 'EXIT/retry leaked or double-released membership'
[ "$(cat "$CASE_DIR/kernel")" = 1 ] || fail 'EXIT retry disabled the remaining instance'

prepare_case release-ownership-save 1
printf '2\n' > "$CASE_DIR/global/ip_forward.refs"
printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
set_held a 1; set_held b 1
CFWARP_REF_FAULT=state
export CFWARP_REF_FAULT
run_operation a release-then-write || { cat "$CASE_DIR/output" >&2; fail 'ownership save could not reconcile failed release'; }
unset CFWARP_REF_FAULT
[ "$(held a)" = 0 ] && [ "$(refs)" = 1 ] || fail 'ownership save replayed the release'
grep -Fx 'DNS_CREATED=0' "$CASE_DIR/state a/a.env" >/dev/null || fail 'release recovery lost the DNS cleanup flag'
grep -Fx 'RULES_STARTED=0' "$CASE_DIR/state a/a.env" >/dev/null || fail 'release recovery lost the firewall cleanup flag'

# Faults immediately before/after every durable step model interrupted commit
# prefixes. A fresh process retries the original operation without recalculating
# a previously committed increment/decrement, including journal removal failure.
for operation in first-acquire shared-acquire shared-release last-release; do
    points='journal prev refs state kernel remove-journal'
    [ "$operation" != last-release ] || points="$points remove-refs remove-prev"
    for point in $points; do
        for mode in before after; do
            prepare_case "$operation-$point-$mode" 0
            case "$operation" in
                first-acquire) action=acquire; expected_refs=1; expected_held=1; expected_kernel=1 ;;
                shared-acquire)
                    action=acquire; expected_refs=2; expected_held=1; expected_kernel=1
                    printf '1\n' > "$CASE_DIR/global/ip_forward.refs"
                    printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
                    printf '1\n' > "$CASE_DIR/kernel"
                    set_held b 1
                    ;;
                shared-release)
                    action=release; expected_refs=1; expected_held=0; expected_kernel=1
                    printf '2\n' > "$CASE_DIR/global/ip_forward.refs"
                    printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
                    printf '1\n' > "$CASE_DIR/kernel"
                    set_held a 1; set_held b 1
                    ;;
                last-release)
                    action=release; expected_refs=absent; expected_held=0; expected_kernel=0
                    printf '1\n' > "$CASE_DIR/global/ip_forward.refs"
                    printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
                    printf '1\n' > "$CASE_DIR/kernel"
                    set_held a 1
                    ;;
            esac
            CFWARP_REF_FAULT=$point
            CFWARP_REF_FAULT_MODE=$mode
            export CFWARP_REF_FAULT CFWARP_REF_FAULT_MODE
            if run_operation a "$action"; then fail "$operation $point $mode fault was not reached"; fi
            unset CFWARP_REF_FAULT CFWARP_REF_FAULT_MODE
            run_operation a "$action" || { cat "$CASE_DIR/output" >&2; fail "$operation $point $mode retry failed"; }
            [ "$(refs)" = "$expected_refs" ] || fail "$operation $point $mode changed count twice"
            [ "$(held a)" = "$expected_held" ] || fail "$operation $point $mode left wrong membership"
            [ "$(cat "$CASE_DIR/kernel")" = "$expected_kernel" ] || fail "$operation $point $mode left wrong kernel setting"
            [ ! -e "$CASE_DIR/global/ip_forward.pending" ] || fail 'committed journal was not removed'
        done
    done
done

# An unrelated ownership-state save must keep a HELD transition reconciled by
# another controller; stale cached HELD=1 cannot resurrect a released reference.
prepare_case stale-writer 1
printf '2\n' > "$CASE_DIR/global/ip_forward.refs"
printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
set_held a 1; set_held b 1
CFWARP_REF_FAULT=kernel
export CFWARP_REF_FAULT
if run_operation a release; then fail 'pending release fixture did not fail'; fi
unset CFWARP_REF_FAULT
run_operation c acquire || fail 'other STATE_DIR could not reconcile and acquire'
run_operation a stale-write || fail 'ownership state save failed'
[ "$(held a)" = 0 ] && [ "$(refs)" = 2 ] || fail 'stale ownership writer resurrected HELD'
grep -Fx 'DNS_CREATED=0' "$CASE_DIR/state a/a.env" >/dev/null || fail 'ownership save lost its non-refcount changes'

# Corrupt/obsolete journals block all mutations instead of changing a new owner.
for corruption in relative-path replaced-owner; do
    prepare_case "$corruption" 1
    printf '2\n' > "$CASE_DIR/global/ip_forward.refs"
    printf '0\n' > "$CASE_DIR/global/ip_forward.prev"
    set_held a 1; set_held b 1
    CFWARP_REF_FAULT=state
    export CFWARP_REF_FAULT
    if run_operation a release; then fail 'invalid journal fixture did not fail'; fi
    unset CFWARP_REF_FAULT
    case "$corruption" in
        relative-path)
            sed 's@^STATE_FILE=.*@STATE_FILE=relative.env@' "$CASE_DIR/global/ip_forward.pending" > "$CASE_DIR/replace"
            mv "$CASE_DIR/replace" "$CASE_DIR/global/ip_forward.pending"
            ;;
        replaced-owner)
            sed 's/^NS_INODE=.*/NS_INODE=999/' "$CASE_DIR/state a/a.env" > "$CASE_DIR/replace"
            mv "$CASE_DIR/replace" "$CASE_DIR/state a/a.env"
            ;;
    esac
    cp "$CASE_DIR/trace" "$CASE_DIR/trace.before"
    if run_operation c acquire; then fail 'obsolete journal was accepted'; fi
    cmp "$CASE_DIR/trace.before" "$CASE_DIR/trace" || fail 'invalid journal mutated state or kernel'
    [ "$(held a)" = 1 ] && [ "$(held c)" = 0 ] || fail 'invalid journal changed ownership'
done

prepare_case originally-enabled 1
run_operation a acquire || fail 'initially enabled acquire failed'
run_operation a release || fail 'initially enabled release failed'
[ "$(cat "$CASE_DIR/kernel")" = 1 ] || fail 'pre-existing forwarding was disabled'
[ "$(refs)" = absent ] && [ ! -e "$CASE_DIR/global/ip_forward.prev" ] || fail 'last release left accounting files'
echo 'PASS: forwarding journal retries, shared state directories, ownership, and commit fault boundaries'
