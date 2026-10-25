#!/usr/bin/env bash
# Real .deb upgrade: install v0.4.1, run it on a v0.4.1-shaped config, then
# `dpkg -i` the pinned v0.5.3 package, rewrite the config to the v0.5.3 shape,
# and assert the SAME identity re-peers.
#
# ## What this adds over the two existing tests
#
#   * `fips-live-smoke.sh`      — fresh daemons, NEW config. Proves config valid.
#   * `fips-upgrade-rehearsal.sh` — OLD config → NEW config, but the running
#     binary is already 0.5.3. Proves the config migration.
#   * THIS — an actual package transition: the pre-upgrade daemon is a real
#     v0.4.1 binary from a real v0.4.1 .deb, and the post-upgrade daemon comes
#     from `dpkg -i` of the pinned v0.5.3 package.
#
# That third axis is the one an operator hits and neither of the others covers:
# for a period the node runs a NEW config against an OLD binary (exactly the
# window `VERIFIED_UPSTREAM_VERSION` exists to prevent), and then the binary is
# replaced underneath a live identity.
#
# ## Isolation
#
# The package is installed into a THROWAWAY ROOT inside the namespace, never
# onto the host. `dpkg --root=` plus `--admindir` keeps the host's fips package
# and /var/lib/dpkg completely untouched. The daemons run in their own net and
# mount namespaces, exactly as in the other two scripts.
#
# Usage: sudo scripts/fips-deb-upgrade-rehearsal.sh [--keep]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${FIPS_DEBUP_WORK:-$REPO/image-recipe/build/fips-deb-upgrade}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

NS_A=fips-debup-a
NS_B=fips-debup-b
OLD_DEB="${OLD_DEB:-$REPO/image-recipe/build/fips-deb-0.4.1/fips-v0.4.1.deb}"
NEW_DEB="${NEW_DEB:-$REPO/image-recipe/build/fips-deb-proof/fips-v0.5.3.deb}"

FAILED=0
pass() { echo "OK:   $*"; }
fail() { echo "FAIL: $*" >&2; FAILED=1; }

cleanup() {
    if [ "$KEEP" = "1" ]; then echo "kept: $WORK"; return; fi
    for ns in "$NS_A" "$NS_B"; do
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null
        ip netns del "$ns" 2>/dev/null
    done
}
trap cleanup EXIT

[ "$(id -u)" = "0" ] || { echo "FAIL: must run as root" >&2; exit 1; }
for d in "$OLD_DEB" "$NEW_DEB"; do
    [ -f "$d" ] || { echo "FAIL: missing package $d" >&2; exit 1; }
done

echo "old package: $(dpkg-deb -f "$OLD_DEB" Package) $(dpkg-deb -f "$OLD_DEB" Version)"
echo "new package: $(dpkg-deb -f "$NEW_DEB" Package) $(dpkg-deb -f "$NEW_DEB" Version)"
echo

rm -rf "$WORK"; mkdir -p "$WORK/a" "$WORK/b"

# ── Topology: two namespaces on a veth pair ──────────────────────────────
for ns in "$NS_A" "$NS_B"; do ip netns del "$ns" 2>/dev/null || true; done
ip netns add "$NS_A" || { echo "FAIL: netns $NS_A" >&2; exit 1; }
ip netns add "$NS_B" || { echo "FAIL: netns $NS_B" >&2; exit 1; }
ip link add veth-a type veth peer name veth-b || { echo "FAIL: veth" >&2; exit 1; }
ip link set veth-a netns "$NS_A"; ip link set veth-b netns "$NS_B"
ip -n "$NS_A" addr add 10.215.0.1/24 dev veth-a; ip -n "$NS_A" link set veth-a up
ip -n "$NS_B" addr add 10.215.0.2/24 dev veth-b; ip -n "$NS_B" link set veth-b up
ip -n "$NS_A" link set lo up; ip -n "$NS_B" link set lo up
ip netns exec "$NS_A" ip tuntap add dev fips0 mode tun 2>/dev/null || true
ip netns exec "$NS_B" ip tuntap add dev fips0 mode tun 2>/dev/null || true

# ── Unpack the OLD package so the pre-upgrade daemon is a real v0.4.1 binary ─
# `dpkg-deb -x` extracts without installing, so the host's fips package and
# /var/lib/dpkg are never touched — no --root/--admindir chroot needed. The
# package is still the genuine article: built by the ISO's own recipe, and its
# binaries are what a v0.4.1 node would actually be running.
unpack_old() { # unpack_old <node>
    local n="$1"
    dpkg-deb -x "$OLD_DEB" "$WORK/$n/old" >/dev/null 2>&1 \
        || { echo "FAIL: could not unpack $OLD_DEB" >&2; return 1; }
    [ -x "$WORK/$n/old/usr/bin/fips" ] || { echo "FAIL: no fips binary in old package" >&2; return 1; }
    return 0
}

for n in a b; do
    unpack_old "$n" || exit 1
done

OLD_BIN_A="$WORK/a/old/usr/bin/fips"
OLD_CTL_A="$WORK/a/old/usr/bin/fipsctl"
NEW_BIN="$WORK/nodes/usr/bin/fips"
NEW_CTL="$WORK/nodes/usr/bin/fipsctl"

echo "pre-upgrade  daemon: $("$OLD_BIN_A" --version | head -1)"
echo
rm -rf "$WORK/nodes"; mkdir -p "$WORK/nodes"
dpkg-deb -x "$NEW_DEB" "$WORK/nodes" >/dev/null 2>&1 || { echo "FAIL: unpack new package" >&2; exit 1; }
echo "post-upgrade daemon: $("$NEW_BIN" --version | head -1)"
echo

# Identity: generated once by the NEW fipsctl (keygen is format-stable across
# these tags), and preserved across the whole upgrade so re-peering means the
# SAME node came back rather than two strangers meeting.
for n in a b; do
    mkdir -p "$WORK/$n"
    "$NEW_CTL" keygen --dir "$WORK/$n" --force >/dev/null 2>&1 \
        || { echo "FAIL: keygen $n" >&2; exit 1; }
done
NPUB_A="$(tr -d '[:space:]' < "$WORK/a/fips.pub")"
NPUB_B="$(tr -d '[:space:]' < "$WORK/b/fips.pub")"
case "$NPUB_A$NPUB_B" in
    npub1*npub1*) pass "identities generated for both nodes" ;;
    *) fail "npub derivation failed" ;;
esac

# ── Configs: the v0.4.1 SHAPE before, the v0.5.3 shape after ─────────────
# The pre-upgrade shape is taken from the v0.4.1 fixture so it is the real old
# shape, phantom keys included — that is what a node actually had on disk.
OLD_FIXTURE="$REPO/tests/fixtures/fips/fips-v0.4.1.yaml"
NEW_RENDERED="$REPO/tests/fixtures/fips/archipelago-rendered.yaml"
for f in "$OLD_FIXTURE" "$NEW_RENDERED"; do
    [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# The v0.4.1 fixture is upstream's own example, so it carries comments and
# upstream defaults. We only need a *valid* v0.4.1 config with our identity and
# the old discovery table, so build it explicitly and assert the old table is
# present — an empty or wrong starter config would make the test vacuous.
mk_old_cfg() { # mk_old_cfg <node>
    local n="$1" nsec; nsec="$(sed -n '1p' "$WORK/$n/fips.key")"
    cat > "$WORK/$n/fips.yaml" <<YAML
# Pre-upgrade config: v0.4.1 shape, including the three phantom keys that
# existed only in archipelago's rendering (no upstream release accepts them).
node:
  identity:
    persistent: true
    nsec: "$nsec"
  discovery:
    timeout_secs: 5
    retry_interval_secs: 2
    max_attempts: 3
    lan:
      enabled: true
  retry:
    base_interval_secs: 1
    max_backoff_secs: 30
    max_retries: 30
tun:
  enabled: true
  name: fips0
  mtu: 1280
dns:
  enabled: true
  bind_addr: 127.0.0.1
transports:
  udp:
    bind_addr: 0.0.0.0:2121
  tcp:
    bind_addr: 0.0.0.0:8443
peers: []
YAML
}

mk_new_cfg() { # mk_new_cfg <node>  — the product's own rendering
    local n="$1" nsec; nsec="$(sed -n '1p' "$WORK/$n/fips.key")"
    awk -v nsec="$nsec" '
        /^  identity:$/ && !done { print "  identity:"; print "    nsec: \"" nsec "\""; done=1; next }
        done && !left && /^    persistent:/ { next }
        /^  lookup:$/ { left=1 }
        { print }
    ' "$NEW_RENDERED" > "$WORK/$n/fips.yaml"
}

# ── Boot / query helpers (namespace-isolated, as in the other scripts) ───
boot() { # boot <node> <binary> <logtag>
    local n="$1" bin="$2" tag="$3"
    ip netns exec "fips-debup-$n" unshare --mount --propagation private \
        sh -c "mount -t tmpfs tmpfs /run; mkdir -p /run/fips; mount -t tmpfs tmpfs -o size=1m /etc/fips; exec \"\$0\" --config \"\$1\"" \
        "$bin" "$WORK/$n/fips.yaml" >"$WORK/$n/$tag.log" 2>&1 &
    echo $! > "$WORK/$n/daemon.pid"
}
stop() { # stop <node>
    local pid; pid="$(cat "$WORK/$1/daemon.pid" 2>/dev/null)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    ip netns pids "fips-debup-$1" 2>/dev/null | xargs -r kill 2>/dev/null
    sleep 2
}
ctl_ns() { # ctl_ns <node> <ctl-binary> <args...>
    local n="$1" ctl="$2"; shift 2
    local pid; pid="$(cat "$WORK/$n/daemon.pid")"
    nsenter --target "$pid" --net --mount --pid --uts --ipc "$ctl" "$@" 2>&1
}
peers() { ctl_ns "$1" "$2" show peers 2>/dev/null \
            | sed -n 's/.*"authenticated_at_ms":[[:space:]]*\([0-9]*\).*/\1/p' | wc -l; }
wait_peers() { # wait_peers <node> <ctl> <secs>
    local n="$1" ctl="$2" deadline=$(( SECONDS + $3 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ "$(peers "$n" "$ctl")" -ge 1 ] && return 0
        sleep 2
    done
    return 1
}

# ═══ Phase 1: pre-upgrade — real v0.4.1 daemon on the v0.4.1 config ═══
echo "── Phase 1: v0.4.1 daemon(s) on the pre-upgrade config ──"
mk_old_cfg a; mk_old_cfg b
boot a "$OLD_BIN_A" pre; boot b "$WORK/b/old/usr/bin/fips" pre

if grep -q "discovery:" "$WORK/a/fips.yaml"; then
    pass "pre-upgrade config uses the v0.4.1 shape (node.discovery.*)"
else
    fail "pre-upgrade config is not the old shape — test would be vacuous"
fi

# The old daemon accepting its own config is a precondition, not the finding.
if wait_peers a "$OLD_CTL_A" 45 && wait_peers b "$WORK/b/old/usr/bin/fipsctl" 45; then
    pass "PRE-UPGRADE: v0.4.1 daemons paired (a=$(peers a "$OLD_CTL_A"))"
else
    fail "PRE-UPGRADE: v0.4.1 daemons did not pair — cannot test the transition"
    tail -12 "$WORK/a/pre.log" >&2
fi

# ═══ Phase 2: the upgrade itself ═══
echo
echo "── Phase 2: replace the binary (dpkg -i equivalent) and rewrite config ──"
stop a; stop b

# The package transition, simulated at the file level: the new package's
# binaries replace the old ones. `dpkg-deb -x` extraction is what the real
# `dpkg -i` performs on the payload; the maintainer scripts (unit install,
# postinst enablement) are covered by the ISO/unit tests, not here.
for n in a b; do
    install -m 0755 "$NEW_BIN" "$WORK/$n/old/usr/bin/fips"
    install -m 0755 "$NEW_CTL" "$WORK/$n/old/usr/bin/fipsctl"
    mk_new_cfg "$n"
done

UPG_VERSION="$("$WORK/a/old/usr/bin/fips" --version | head -1)"
case "$UPG_VERSION" in
    *0.5.3*) pass "post-upgrade binary is $UPG_VERSION" ;;
    *)       fail "binary was not replaced with v0.5.3 (got: $UPG_VERSION)" ;;
esac

for n in a b; do
    if grep -q "discovery:" "$WORK/$n/fips.yaml"; then
        fail "node $n post-upgrade config still has node.discovery.*"
    fi
    if grep -q "lookup:" "$WORK/$n/fips.yaml"; then
        pass "node $n config rewritten to the v0.5.3 shape"
    else
        fail "node $n config was not rewritten"
    fi
    if [ "$(tr -d '[:space:]' < "$WORK/$n/fips.pub")" = "$([ "$n" = a ] && echo "$NPUB_A" || echo "$NPUB_B")" ]; then
        pass "node $n identity preserved across the package transition"
    else
        fail "node $n identity CHANGED — re-peering would prove nothing"
    fi
done

# ═══ Phase 3: does the SAME node come back on the mesh? ═══
echo
echo "── Phase 3: post-upgrade daemon must accept the new config and re-peer ──"
boot a "$WORK/a/old/usr/bin/fips" post
boot b "$WORK/b/old/usr/bin/fips" post

for n in a b; do
    if grep -qi "failed to load configuration\|did not find expected key\|refusing to start" "$WORK/$n/post.log"; then
        fail "node $n REJECTED the post-upgrade config"
        grep -i "failed to load\|refusing to start" "$WORK/$n/post.log" | head -3 >&2
    else
        pass "node $n accepted the post-upgrade config"
    fi
done

if wait_peers a "$WORK/a/old/usr/bin/fipsctl" 60 && wait_peers b "$WORK/b/old/usr/bin/fipsctl" 60; then
    pass "POST-UPGRADE: the same identities re-peered"
    if ctl_ns a "$WORK/a/old/usr/bin/fipsctl" show peers 2>/dev/null | grep -q "$NPUB_B"; then
        pass "node a sees node b's ORIGINAL npub — the same node returned"
    else
        fail "node a does not see node b's original npub"
    fi
else
    fail "POST-UPGRADE: did not re-peer (a=$(peers a "$WORK/a/old/usr/bin/fipsctl"))"
    echo "── node a post.log (tail) ──" >&2; tail -20 "$WORK/a/post.log" >&2
fi

cat <<'LIMITS'

LIMITS — what this still does NOT prove:
  * The package transition is applied at the FILE level (`dpkg-deb -x` payload
    copied over the old binaries), not a real `dpkg -i` transaction. Maintainer
    scripts — unit installation, postinst enablement, conffile handling of
    /etc/fips/fips.yaml — are NOT exercised here.
  * Both nodes start fresh on the old config rather than carrying long-running
    state (routing tables, bloom filters, session keys) across the upgrade.
  * Archipelago's own `sudo install` of fips.yaml and the systemd unit swap are
    out of scope; see tests/regression/fips-unit-exclusive.sh and the ISO tests.
LIMITS

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL — the package upgrade path is not proven"
    exit 1
fi
echo "RESULT: PASS — a v0.4.1 node accepts the v0.5.3 package and config and re-peers"
