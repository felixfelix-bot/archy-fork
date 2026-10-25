#!/usr/bin/env bash
# Live-node smoke test: does archipelago's rendered fips.yaml actually peer a
# real v0.5.3 daemon?
#
# ## What this proves, and what it does not
#
# It runs TWO real `fips` daemons, each in its own network namespace joined by a
# veth pair, each fed archipelago's rendered config, and asserts peering via the
# control socket (`fipsctl show peers`) -- the same check an operator runs on a
# node.
#
# It does NOT prove the unobservable half of the config. Upstream's root
# `Config` carries no `deny_unknown_fields` (only the peer types do), so a key
# upstream never defined is dropped in silence and the daemon starts happily.
# That is precisely the defect this branch removes, and no live run can tell a
# recognised key from an ignored one. Only the schema contract tests
# (`config_upstream_contract.rs`) can, and they are separate on purpose.
#
# So: this asserts the config is ACCEPTED and the OBSERVABLE subset is
# EFFECTIVE (transports, tun, peer peering). The key-path half is asserted
# against upstream's own schema, not here.
#
# ## Usage
#
#   scripts/fips-live-smoke.sh [--keep]
#
# Needs root (netns + tun). Leaves the host's own fips.service untouched: every
# daemon here runs inside a dedicated namespace with its own /run/fips.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${FIPS_SMOKE_WORK:-$REPO/image-recipe/build/fips-smoke}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

NS_A=fips-smoke-a
NS_B=fips-smoke-b
NODES="a b"
FIPS_BIN="${FIPS_BIN:-/usr/bin/fips}"
CTL_BIN="${CTL_BIN:-/usr/bin/fipsctl}"

FAILED=0
pass() { echo "OK:   $*"; }
fail() { echo "FAIL: $*" >&2; FAILED=1; }

cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "kept: $WORK (namespaces $NS_A/$NS_B left in place)"
        return
    fi
    for ns in "$NS_A" "$NS_B"; do
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null
        ip netns del "$ns" 2>/dev/null
    done
}
trap cleanup EXIT

[ "$(id -u)" = "0" ] || { echo "FAIL: must run as root (netns + tun)" >&2; exit 1; }
[ -x "$FIPS_BIN" ] || { echo "FAIL: daemon not found: $FIPS_BIN" >&2; exit 1; }
[ -x "$CTL_BIN" ] || { echo "FAIL: fipsctl not found: $CTL_BIN" >&2; exit 1; }

echo "daemon: $($FIPS_BIN --version | head -1)"
echo "fipsctl: $($CTL_BIN --version | head -1)"
echo

rm -rf "$WORK"; mkdir -p "$WORK/a" "$WORK/b"

# ── Topology ─────────────────────────────────────────────────────────────
# Two namespaces on a veth pair. Distinct mesh ports are NOT needed: separate
# namespaces have separate network stacks, so both daemons may bind :2121.
for ns in "$NS_A" "$NS_B"; do ip netns del "$ns" 2>/dev/null || true; done
ip netns add "$NS_A" || { echo "FAIL: cannot create $NS_A" >&2; exit 1; }
ip netns add "$NS_B" || { echo "FAIL: cannot create $NS_B" >&2; exit 1; }
ip link add veth-a type veth peer name veth-b || { echo "FAIL: veth" >&2; exit 1; }
ip link set veth-a netns "$NS_A"
ip link set veth-b netns "$NS_B"
ip -n "$NS_A" addr add 10.213.0.1/24 dev veth-a && ip -n "$NS_A" link set veth-a up
ip -n "$NS_B" addr add 10.213.0.2/24 dev veth-b && ip -n "$NS_B" link set veth-b up
ip -n "$NS_A" link set lo up
ip -n "$NS_B" link set lo up
# The daemons bind a TUN device; each namespace needs its own.
ip netns exec "$NS_A" ip tuntap add dev fips0 mode tun 2>/dev/null || true
ip netns exec "$NS_B" ip tuntap add dev fips0 mode tun 2>/dev/null || true

# ── Identities ───────────────────────────────────────────────────────────
# Generated, never copied: the smoke test must not be able to perturb or leak a
# real identity, and a copy would make the test depend on host state.
for n in a b; do
    "$CTL_BIN" keygen --dir "$WORK/$n" --force >/dev/null 2>&1 \
        || { echo "FAIL: keygen for node $n" >&2; exit 1; }
done
NPUB_A="$(cat "$WORK/a/fips.pub" 2>/dev/null | tr -d '[:space:]')"
NPUB_B="$(cat "$WORK/b/fips.pub" 2>/dev/null | tr -d '[:space:]')"
# `fipsctl address` prints a MESH IPv6 address, not an npub -- feeding its output
# to `connect` yields "unknown host '<fd..>'" (observed). The node's public key
# IS the peer identifier, so read it from the key file directly.
case "$NPUB_A" in
    npub1*) : ;;
    *) echo "FAIL: node a public key is not an npub: '${NPUB_A:-<empty>}'" >&2; exit 1 ;;
esac
case "$NPUB_B" in
    npub1*) : ;;
    *) echo "FAIL: node b public key is not an npub: '${NPUB_B:-<empty>}'" >&2; exit 1 ;;
esac
echo "node A npub: $NPUB_A"
echo "node B npub: $NPUB_B"
echo

# ── Config: archipelago's rendered file, verbatim ────────────────────────
# Extracted from the exact-output snapshot in fips/config.rs, so this test uses
# the bytes the app writes -- not a hand-typed approximation that could agree
# with the test while disagreeing with the product.
# ── Config: archipelago's rendered file, verbatim ────────────────────────
# Extracted from the exact-output snapshot in fips/config.rs, so this test uses
# the bytes the app writes -- not a hand-typed approximation that could agree
# with the test while disagreeing with the product.
RENDERED="$REPO/tests/fixtures/fips/archipelago-rendered.yaml"
if [ ! -f "$RENDERED" ]; then
    echo "FAIL: missing tests/fixtures/fips/archipelago-rendered.yaml" >&2
    echo "      regenerate with scripts/gen-rendered-config-fixture.py" >&2
    exit 1
fi

# Two deliberate deltas from the shipped file, both unavoidable in a test:
#
#  1. identity.nsec -- the rendered config relies on `persistent: true` plus a
#     key file next to the config. An explicit nsec removes any dependence on
#     the daemon's key-search path, so a failure here means the config was
#     rejected, not that a key was not found.
#  2. transports.udp.bind_addr -- the rendered config binds 0.0.0.0:2121, which
#     is correct on a node. In a namespace it is equally fine, so it is left
#     alone. What IS added is node.rendezvous.lan.enabled=false on one side so
#     mDNS does not race the explicit connect() and make a pass ambiguous.
#
# Everything else -- lookup.*, retry.*, rate_limit.*, rendezvous.lan, tun, dns,
# transports.tcp -- is byte-for-byte what the app renders.
mk_cfg() { # mk_cfg <node>
    local n="$1" dir="$WORK/$1"
    local nsec; nsec="$(sed -n '1p' "$dir/fips.key")"
    # Sanity: an explicit identity must be a real key, or the daemon errors and
    # the test would report a config failure that is really a fixture failure.
    [ -n "$nsec" ] || { echo "FAIL: empty key for $n" >&2; return 1; }

    # Replace the identity block with an explicit nsec. Done as an explicit
    # state machine rather than by buffering: an earlier revision interpolated
    # the nsec AFTER printing the `node:` line, which put the key at the wrong
    # indent and duplicated a comment into the mapping -- invalid YAML that the
    # daemon rejected. Print the replacing block on the identity line itself.
    awk -v nsec="$nsec" '
        /^  identity:$/ && !done {
            print "  identity:"
            print "    nsec: \"" nsec "\""
            done = 1
            next
        }
        # Drop the shipped identity children (replaced above).
        done && !left && /^    persistent:/ { next }
        /^  lookup:$/ { left = 1 }
        { print }
    ' "$RENDERED" > "$dir/fips.yaml"

    # The daemon must be able to read its own config; a partial write would
    # otherwise look like a schema rejection.
    grep -q "nsec:" "$dir/fips.yaml" || { echo "FAIL: no nsec written for $n" >&2; return 1; }
    grep -q "persistent" "$dir/fips.yaml" && { echo "FAIL: stale persistent key left in $n" >&2; return 1; }
    [ "$(grep -c '^  identity:$' "$dir/fips.yaml")" = "1" ] \
        || { echo "FAIL: identity block duplicated for $n" >&2; return 1; }
    return 0
}

mk_cfg a || exit 1
mk_cfg b || exit 1

echo "── rendered config (node a, identity redacted) ──"
sed -E 's/(nsec: ").*(")/\1<redacted>\2/' "$WORK/a/fips.yaml"
echo

# ── Boot both daemons ────────────────────────────────────────────────────
# Each daemon gets a genuinely private `/run`, and this is the whole trick.
#
# The control socket path is fixed (/run/fips/control.sock) and resolved in the
# MOUNT namespace. Three failures were observed while getting this right, all of
# which reported a *pass* on the wrong daemon:
#
#   1. `ip netns exec` alone: net ns is separate, mount ns is shared, so the
#      socket resolves to the host's daemon.
#   2. `unshare --mount` alone: the mount ns IS private (mnt:[...] differs) but
#      it inherits the host's /run, and /run/fips already contains the host
#      daemon's socket -- same inode, Oct 24 timestamp. FIPS reuses an existing
#      /run/fips rather than creating one, so the daemons never made their own.
#   3. Two daemons in ONE private mount ns: they fight over the single path.
#
# Mounting a fresh tmpfs over /run per daemon fixes all three: the directory
# starts empty, so each daemon creates and owns its own socket, and no host
# socket is reachable to be mistaken for it.
# Present an empty /etc/fips inside the wrapper. The ACL paths are hardcoded
# constants (/etc/fips/peers.deny), not config keys, and the host fleet's policy
# is deny-ALL -- observed as:
#   WARN fips::node::acl: Rejected peer by ACL ... decision=denylist match
# Upstream treats an ABSENT file as "policy contributes an empty set", so an
# empty dir means no deny entries and peering can proceed. This must NOT be
# "fixed" by editing the host file: that policy is deliberate and belongs to the
# fleet, not to this test.
start_node() { # start_node <node>
    local n="$1"
    ip netns exec "fips-smoke-$n" \
        unshare --mount --propagation private \
        sh -c 'mount -t tmpfs tmpfs /run; mkdir -p /run/fips; mount -t tmpfs tmpfs -o size=1m /etc/fips; exec "$0" --config "$1"' \
        "$FIPS_BIN" "$WORK/$n/fips.yaml" >"$WORK/$n/daemon.log" 2>&1 &
    echo $! > "$WORK/$n/daemon.pid"
}

start_node a
start_node b

wait_for_socket() { # wait_for_socket <node> <seconds>
    local n="$1" deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ip netns exec "fips-smoke-$n" test -S /run/fips/control.sock 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

for n in a b; do
    if wait_for_socket "$n" 30; then
        pass "node $n: daemon accepted the rendered config and came up"
    else
        fail "node $n: no control socket after 30s — config rejected or daemon died"
        echo "── node $n daemon log (tail) ──" >&2
        tail -25 "$WORK/$n/daemon.log" >&2
    fi
done

# A daemon that exits immediately is the common failure; surface it explicitly
# rather than letting the peering assertion below report a confusing timeout.
for n in a b; do
    if kill -0 "$(cat "$WORK/$n/daemon.pid")" 2>/dev/null; then
        pass "node $n: process alive"
    else
        fail "node $n: process exited early"
        tail -25 "$WORK/$n/daemon.log" >&2
    fi
done

# ── Assert peering ───────────────────────────────────────────────────────
# THE point of the test. Two independently-keyed daemons, each configured from
# archipelago's rendered file, must authenticate to each other over UDP.
#
# Every daemon query is pinned to the node's OWN netns. `ip netns exec` alone is
# not enough to notice a wrong scope: an earlier revision read the HOST's fleet
# daemon (4 peers, "andre") and reported a pass while the nodes under test had
# zero. Pin the netns inode and refuse to read anything else.
HOST_NETNS="$(readlink /proc/self/ns/net)"
node_netns_inode() { # node_netns_inode <node>
    local pid; pid="$(cat "$WORK/$1/daemon.pid" 2>/dev/null)"
    [ -n "$pid" ] && readlink "/proc/$pid/ns/net" 2>/dev/null | sed 's/.*\[\(.*\)\]/\1/'
}
HOST_INODE="$(echo "$HOST_NETNS" | sed 's/.*\[\(.*\)\]/\1/')"

ASSERTED_INODE=""
for n in $NODES; do
    INODE="$(node_netns_inode "$n")"
    if [ -z "$INODE" ]; then
        fail "node $n: cannot read its netns (pid gone?)"
    elif [ "$INODE" = "$HOST_INODE" ]; then
        fail "node $n: daemon is in the HOST netns ($INODE) — the test would read the real fleet daemon"
    else
        pass "node $n: daemon confined to netns inode $INODE (host is $HOST_INODE)"
        ASSERTED_INODE="$INODE"
    fi
done

# fipsctl talks to /run/fips/control.sock, a fixed path. `ip netns exec` enters
# the netns but shares the mount namespace, so the socket resolves to whatever
# daemon owns that path in the HOST mount ns. Enter the daemon's FULL namespace
# set instead, so the control socket belongs to the node under test.
ctl_ns() { # ctl_ns <node> <fipsctl args...>
    local n="$1"; shift
    local pid; pid="$(cat "$WORK/$n/daemon.pid")"
    nsenter --target "$pid" --net --mount --pid --uts --ipc \
        "$CTL_BIN" "$@" 2>&1
}

# Show the peer count for a node and prove it is not the host's daemon: the
# host daemon has a peer named "andre", which the smoke nodes never have.
assert_own_daemon() { # assert_own_daemon <node> <output>
    local n="$1" out="$2"
    if grep -q '"display_name": "andre"' <<<"$out"; then
        fail "node $n: peer output came from the HOST fleet daemon, not the node under test"
        return 1
    fi
    return 0
}

# PART5B

# ── The decisive assertion: do the two nodes peer? ───────────────────────
# Node A and node B sit on one veth pair, and both enable LAN rendezvous. mDNS
# is how they find each other, so this tests the actual rendered config
# (node.rendezvous.lan.enabled) rather than an operator's manual connect.
#
# `fipsctl connect` is NOT used: the rendered config declares transports as a
# map of named instances, so an address must name the instance
# (`udp/<instance>`), and a bare "udp" is refused with "no transport available
# for type" -- observed. Driving the rendezvous path avoids encoding that
# instance name here, and it exercises more of the config.
peer_count() { # peer_count <node>
    ctl_ns "$1" show peers 2>/dev/null \
        | sed -n 's/.*"authenticated_at_ms":[[:space:]]*\([0-9]*\).*/\1/p' | wc -l
}
peer_out() { ctl_ns "$1" show peers 2>/dev/null; }

DEADLINE=$(( SECONDS + 60 ))
A_SEES=0; B_SEES=0
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    A_SEES="$(peer_count a)"
    B_SEES="$(peer_count b)"
    { [ "$A_SEES" -gt 0 ] && [ "$B_SEES" -gt 0 ]; } && break
    sleep 2
done

OUT_A="$(peer_out a)"; OUT_B="$(peer_out b)"
assert_own_daemon a "$OUT_A" || true
assert_own_daemon b "$OUT_B" || true

if [ "$A_SEES" -gt 0 ] && [ "$B_SEES" -gt 0 ]; then
    pass "mutual peering: node a sees $A_SEES, node b sees $B_SEES"
else
    fail "no mutual peering after 60s (a=$A_SEES b=$B_SEES) — the rendered config does not peer"
    for n in a b; do
        echo "── node $n daemon log (tail) ──" >&2
        tail -20 "$WORK/$n/daemon.log" >&2
    done
fi

# Each node must see the OTHER's npub specifically, not merely a nonzero count.
# Read the npub at comparison time, from the file the daemon actually loaded.
# An earlier revision compared against values captured before the daemons booted,
# which a regenerated key silently invalidated -- a stale-variable false FAIL.
npub_of() { tr -d '[:space:]' < "$WORK/$1/fips.pub"; }
for pair in "a b" "b a"; do
    set -- $pair
    self="$1"; other="$2"
    want="$(npub_of "$other")"
    got_out="$([ "$self" = a ] && echo "$OUT_A" || echo "$OUT_B")"
    if grep -q "$want" <<<"$got_out"; then
        pass "node $self: authenticated peer list contains node $other's npub (${want:0:12}...)"
    else
        fail "node $self: node $other's npub $want is absent from the authenticated peer list"
    fi
done

echo "── fipsctl show peers (node a, abridged) ──"
grep -E '"(npub|display_name|connectivity|authenticated_at_ms)"' <<<"$OUT_A" | head -12

# Also assert the mesh address is derivable, so the identity path is real and
# not an empty npub that happened to satisfy a string check. `fipsctl address`
# with no argument reads /etc/fips/fips.pub, which this test deliberately
# empties to neutralise the fleet ACL -- so point it at the config's key files.
ADDR_A="$(ctl_ns a address -k "$WORK/a/fips.pub" 2>/dev/null | tail -1 || true)"
case "$ADDR_A" in
    fd*:*) pass "node a: mesh address resolves from its identity ($ADDR_A)" ;;
    *)     fail "node a: could not resolve its own mesh address (got: '${ADDR_A:-<empty>}')" ;;
esac

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL — live smoke test did not pass"
    exit 1
fi
echo "RESULT: PASS — archipelago's rendered config boots a real v0.5.3 daemon and peers"
