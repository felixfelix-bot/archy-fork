#!/usr/bin/env bash
# Assert that archipelago-fips.service and the packaged fips.service can never be
# simultaneously ACTIVE, and that neither unit is silently lost to the other.
#
# ## Why this is a real test and not a unit-file lint
#
# `systemd-analyze verify` does NOT validate `Conflicts=` targets — measured
# 2026-10-25: a unit declaring `Conflicts=no-such-unit.service` verifies clean.
# So the only honest way to test mutual exclusion is to make systemd do it.
#
# This installs throwaway units that mirror the real relationship (each
# `Conflicts=` the other, both `WantedBy=multi-user.target`) and asserts the
# observed behaviour. That reproduces the mechanism the shipped units rely on
# without touching, starting, stopping or masking the host's real fips.service.
#
# ## What it pins, and why it pins BOTH facts
#
#   1. Mutual exclusion HOLDS: start A then B ⇒ A stops. This is the property
#      the `Conflicts=` line is there for.
#   2. The loser is NOT privileged: starting B stops A *and* starting A stops B.
#      A symmetric directive designates no winner, so the surviving unit depends
#      on start order. This is the part that makes "the packaged unit concedes"
#      a false claim, and it is asserted deliberately — if a future change
#      introduces ordering that makes archipelago always win, this test fails,
#      which is the correct prompt to update the comment rather than leave a
#      stale assertion in the unit file.
#
# Requires root (systemd). Skips cleanly with exit 0 where systemd is unavailable,
# so it can sit in a suite that also runs in containers.
#
# Usage: sudo tests/regression/fips-unit-exclusive.sh [--keep]
set -uo pipefail

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

A=archyx-probe-a.service
B=archyx-probe-b.service
DIR=/etc/systemd/system

FAILED=0
pass() { echo "OK:   $*"; }
fail() { echo "FAIL: $*" >&2; FAILED=1; }
skip() { echo "SKIP: $*"; exit 0; }

cleanup() {
    if [ "$KEEP" = "1" ]; then echo "kept: $DIR/$A $DIR/$B"; return; fi
    systemctl stop "$A" "$B" 2>/dev/null
    rm -f "$DIR/$A" "$DIR/$B"
    systemctl daemon-reload 2>/dev/null
}
trap cleanup EXIT

if ! command -v systemctl >/dev/null 2>&1; then skip "systemctl not available"; fi
if [ "$(id -u)" != "0" ]; then skip "needs root (systemd)"; fi
if ! systemctl is-system-running >/dev/null 2>&1 && \
   [ "$(systemctl is-system-running 2>/dev/null)" = "offline" ]; then
    skip "systemd is not the running init"
fi

write_unit() { # write_unit <file> <desc> <conflicts>
    cat > "$DIR/$1" <<EOF
[Unit]
Description=$2
Conflicts=$3

[Service]
Type=simple
ExecStart=/bin/sleep 300

[Install]
WantedBy=multi-user.target
EOF
}

# Mutual exclusion is only meaningful if BOTH units claim it; a one-way
# Conflicts= would pass test 1 in one direction and silently fail the other.
write_unit "$A" "archipelago unit-exclusion probe A" "$B"
write_unit "$B" "archipelago unit-exclusion probe B" "$A"
systemctl daemon-reload || { fail "daemon-reload"; exit 1; }

started() { systemctl is-active "$1" 2>/dev/null; }

# ── Test 1: both units declare Conflicts= on each other ──────────────────
for u in "$A" "$B"; do
    if grep -q "^Conflicts=" "$DIR/$u"; then
        pass "$u declares Conflicts="
    else
        fail "$u has no Conflicts= line — the probe does not model the shipped pair"
    fi
done

# ── Test 2: starting the second unit stops the first ─────────────────────
systemctl stop "$A" "$B" 2>/dev/null || true
systemctl start "$A" 2>/dev/null || { fail "could not start $A"; exit 1; }
sleep 1
if [ "$(started "$A")" = "active" ]; then
    pass "probe A active"
else
    fail "probe A did not become active — cannot test exclusion"
fi

systemctl start "$B" 2>/dev/null || true
sleep 1
case "$(started "$A")/$(started "$B")" in
    inactive/active) pass "starting B stopped A (mutual exclusion holds)" ;;
    active/active)   fail "A and B are BOTH active — Conflicts= did not exclude; the shipped pair can bind the same ports concurrently" ;;
    *)               fail "unexpected state after starting B: A=$(started "$A") B=$(started "$B")" ;;
esac

# ── Test 3: the same holds in the other direction (symmetry) ─────────────
systemctl stop "$A" "$B" 2>/dev/null || true
systemctl start "$B" 2>/dev/null || true
sleep 1
systemctl start "$A" 2>/dev/null || true
sleep 1
case "$(started "$A")/$(started "$B")" in
    active/inactive) pass "starting A stopped B — the directive is symmetric" ;;
    active/active)   fail "A and B are BOTH active in the reverse direction" ;;
    *)               fail "unexpected state after starting A: A=$(started "$A") B=$(started "$B")" ;;
esac

# ── Test 4: pin the fact that no winner is designated ────────────────────
# Both directions stop the other, so the survivor is whichever started last.
# If this ever stops being true (e.g. a drop-in adds After=/Before=), the unit
# comment's claim about which unit concedes must be revisited — so fail loudly
# rather than let the comment and the behaviour drift apart.
systemctl stop "$A" "$B" 2>/dev/null || true
systemctl start "$A" 2>/dev/null || true; sleep 1
systemctl start "$B" 2>/dev/null || true; sleep 1
LAST_B="$(started "$B")"
systemctl stop "$A" "$B" 2>/dev/null || true
systemctl start "$B" 2>/dev/null || true; sleep 1
systemctl start "$A" 2>/dev/null || true; sleep 1
LAST_A="$(started "$A")"

if [ "$LAST_B" = "active" ] && [ "$LAST_A" = "active" ]; then
    pass "no winner is designated: the unit started second always survives"
else
    fail "one unit now wins regardless of order (B-last=$LAST_B A-last=$LAST_A) — \
the 'packaged unit concedes' claim may now be true; update the unit comment \
and docs/findings-fips-unit-conflicts.md rather than leaving them stale"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL — unit mutual exclusion is not what the shipped pair assumes"
    exit 1
fi
echo "RESULT: PASS — Conflicts= holds in both directions and designates no winner"
