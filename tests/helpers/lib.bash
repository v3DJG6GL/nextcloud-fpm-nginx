# Generic assertion helpers + utilities. Sourced by bats files via `load`.
#
# bats sets these env vars per-test: $BATS_TEST_NAME, $BATS_TEST_FILENAME,
# $BATS_TMPDIR (per-suite temp dir).

# --- Logging --------------------------------------------------------------
# bats normally hides stdout/stderr unless a test fails. `log` writes to FD 3
# which bats reserves for diagnostic output that survives even on pass.
log() {
    printf '# %s\n' "$*" >&3
}

# --- Assertions -----------------------------------------------------------
# All assertions exit the test with code != 0 on failure. bats captures.

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-assertion failed}"
    if [ "$actual" != "$expected" ]; then
        log "$msg"
        log "  expected: $expected"
        log "  actual:   $actual"
        return 1
    fi
}

assert_match() {
    local haystack="$1" pattern="$2" msg="${3:-pattern not found}"
    if ! printf '%s' "$haystack" | grep -qE "$pattern"; then
        log "$msg"
        log "  pattern: $pattern"
        log "  in:      $haystack"
        return 1
    fi
}

assert_not_match() {
    local haystack="$1" pattern="$2" msg="${3:-pattern found unexpectedly}"
    if printf '%s' "$haystack" | grep -qE "$pattern"; then
        log "$msg"
        log "  pattern: $pattern"
        log "  in:      $haystack"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-substring not found}"
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *)
            log "$msg"
            log "  needle: $needle"
            log "  in:     $haystack"
            return 1
            ;;
    esac
}

assert_status_zero() {
    local status="$1" msg="${2:-expected exit 0}"
    if [ "$status" -ne 0 ]; then
        log "$msg (got $status)"
        return 1
    fi
}

assert_status_nonzero() {
    local status="$1" msg="${2:-expected non-zero exit}"
    if [ "$status" -eq 0 ]; then
        log "$msg"
        return 1
    fi
}

# --- Polling --------------------------------------------------------------
# wait_until <timeout-s> <interval-s> <command...>
# Re-runs the command until it exits 0 or the timeout elapses.
wait_until() {
    local timeout="$1" interval="$2"; shift 2
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done
    log "timeout (${timeout}s) waiting for: $*"
    return 1
}
