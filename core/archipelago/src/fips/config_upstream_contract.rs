//! Contract tests asserting the generated `fips.yaml` against the **upstream**
//! FIPS schema at the pinned tag.
//!
//! ## Why this module exists
//!
//! A previous revision of `config.rs` claimed its typed schema was "verified
//! field-by-field against jmcorgan/fips v0.4.1" while emitting
//! `node.discovery.{timeout_secs, retry_interval_secs, max_attempts}` — three
//! keys that exist in **no** upstream release. Upstream's `DiscoveryConfig`
//! carries no `deny_unknown_fields`, so the daemon ignored them silently and
//! the "fail fast lookup" tuning they were meant to apply never took effect on
//! any node. A comment cannot fail a build; these tests can.
//!
//! ## What is asserted, and against what
//!
//! Two independent fixtures, because neither alone is sufficient:
//!
//! 1. `fips-<tag>.yaml` — a **verbatim copy** of upstream's
//!    `packaging/common/fips.yaml`. Proves the pinned tag is real and that we
//!    read the artefact we claim to. It documents only a fraction of the
//!    schema: `node.retry.*` and `node.rate_limit.*`, which archipelago sets,
//!    appear nowhere in it.
//! 2. `fips-<tag>-schema.txt` — the full set of valid key paths, extracted from
//!    upstream's `#[derive(Deserialize)]` structs by
//!    `scripts/gen-fips-schema.py`. This is the authority for "does upstream
//!    accept this key".
//!
//! `scripts/verify-fips-fixtures.sh` re-downloads (1) and fails on drift;
//! regenerating (2) is part of the version-bump checklist.
//!
//! ## Scope
//!
//! Only the subset of the upstream schema that archipelago owns is asserted.
//! We deliberately do NOT deserialize the whole upstream file into a mirror
//! struct — that would be a second, hand-maintained copy of upstream drifting
//! in parallel with `FipsConfig`.

use serde_yaml::Value;
use std::collections::BTreeSet;

/// The upstream tag `render_config_yaml()` is written against. Bumping
/// `FIPS_VERSION` in the ISO builder MUST bump this and both fixtures together.
const PINNED_UPSTREAM_TAG: &str = "v0.5.3";

/// Verbatim `packaging/common/fips.yaml` from upstream at `PINNED_UPSTREAM_TAG`.
const UPSTREAM_EXAMPLE: &str = include_str!("../../../../tests/fixtures/fips/fips-v0.5.3.yaml");

/// Full valid key-path set, extracted from upstream source at the same tag.
const UPSTREAM_SCHEMA: &str =
    include_str!("../../../../tests/fixtures/fips/fips-v0.5.3-schema.txt");

fn upstream_example() -> Value {
    serde_yaml::from_str(UPSTREAM_EXAMPLE).expect("upstream fixture parses as YAML")
}

fn rendered() -> Value {
    serde_yaml::from_str(&crate::fips::config::render_config_yaml())
        .expect("rendered config parses as YAML")
}

/// Valid upstream key paths, comments stripped.
fn upstream_paths() -> BTreeSet<String> {
    UPSTREAM_SCHEMA
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

/// Walk a YAML value, invoking `f` with the dotted path of every mapping key.
fn walk<F: FnMut(&str)>(value: &Value, prefix: String, f: &mut F) {
    if let Value::Mapping(map) = value {
        for (k, v) in map {
            let Some(key) = k.as_str() else { continue };
            let path = if prefix.is_empty() {
                key.to_string()
            } else {
                format!("{prefix}.{key}")
            };
            f(&path);
            walk(v, path, f);
        }
    }
}

/// Every dotted path the generated config emits.
fn emitted_paths() -> BTreeSet<String> {
    let tree = rendered();
    let mut out = BTreeSet::new();
    walk(&tree, String::new(), &mut |p| {
        out.insert(p.to_string());
    });
    out
}

/// The set of paths archipelago deliberately OWNS — the tuning it must apply.
///
/// This is the third of three sets, and the one that was previously unchecked:
///
///   * `owned`  ⊆ `emitted`  ← this module's new assertion
///   * `emitted` ⊆ `schema`  ← `every_path_we_emit_is_valid_upstream`
///   * `schema` is genuine   ← `fixture_is_a_real_upstream_config`
///
/// Without the first direction, nothing failed if a future edit dropped
/// `node.retry.*` or `node.rate_limit.*` from the renderer. `emitted ⊆ schema`
/// stays vacuously true as `emitted` shrinks, and the exact-output snapshot in
/// `config.rs` can simply be updated to match a wrong config — so the file
/// that is supposed to catch a lost setting would have blessed its absence.
fn owned_paths() -> BTreeSet<String> {
    [
        // The mesh-lookup scalars this project tunes (formerly node.discovery.*).
        "node.lookup.backoff_base_secs",
        "node.lookup.backoff_max_secs",
        // mDNS LAN rendezvous — on by default for co-located nodes.
        "node.rendezvous.lan.enabled",
        // Fast-reconnect profile: upstream's 5s→300s default left a node
        // off-mesh for ~90s after a recycled anchor.
        "node.retry.base_interval_secs",
        "node.retry.max_backoff_secs",
        "node.retry.max_retries",
        // Handshake resend pacing during the connect window.
        "node.rate_limit.handshake_resend_interval_ms",
        "node.rate_limit.handshake_resend_backoff",
        "node.rate_limit.handshake_max_resends",
        // Identity + interfaces + transports the app depends on.
        "node.identity.persistent",
        "tun.enabled",
        "tun.name",
        "tun.mtu",
        "dns.enabled",
        "dns.bind_addr",
        "transports.udp.bind_addr",
        "transports.tcp.bind_addr",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

// ─────────────────────────── fixture integrity ───────────────────────────

#[test]
fn fixture_is_a_real_upstream_config() {
    // A truncated or empty fixture would make every assertion below vacuous.
    let tree = upstream_example();
    assert!(tree["node"].is_mapping(), "fixture has no node: section");
    assert!(
        tree["transports"].is_mapping(),
        "fixture has no transports:"
    );
    assert!(
        UPSTREAM_EXAMPLE.len() > 2000,
        "fixture is implausibly small ({} bytes)",
        UPSTREAM_EXAMPLE.len()
    );
    assert_eq!(PINNED_UPSTREAM_TAG, "v0.5.3");
}

#[test]
fn schema_fixture_covers_the_paths_we_own() {
    // If the extractor regressed and emitted a truncated set, the
    // "every emitted path exists upstream" test would pass vacuously.
    let paths = upstream_paths();
    assert!(
        paths.len() > 100,
        "schema fixture has only {} paths — extraction likely broke",
        paths.len()
    );
    for p in [
        "node.retry.base_interval_secs",
        "node.retry.max_backoff_secs",
        "node.retry.max_retries",
        "node.rate_limit.handshake_resend_interval_ms",
        "node.rate_limit.handshake_resend_backoff",
        "node.rate_limit.handshake_max_resends",
        "node.lookup.backoff_base_secs",
        "node.lookup.backoff_max_secs",
        "node.rendezvous.lan.enabled",
        "node.identity.persistent",
        "tun.enabled",
        "tun.name",
        "tun.mtu",
        "dns.enabled",
        "dns.bind_addr",
        "transports.udp.bind_addr",
        "transports.tcp.bind_addr",
        "peers",
    ] {
        assert!(paths.contains(p), "schema fixture is missing `{p}`");
    }
}

// ───────────────────────── the actual contract ─────────────────────────

/// The missing direction: everything we OWN must actually be emitted.
///
/// Without this, `emitted ⊆ schema` stays true while `emitted` quietly shrinks,
/// and a renderer edit that dropped `node.retry.*` would ship a node with
/// upstream's 5s→300s reconnect behaviour while every test passed. The other
/// tests cannot catch it: the exact snapshot in `config.rs` would simply be
/// updated to match, and `emitted ⊆ schema` is monotone in shrinking `emitted`.
#[test]
fn everything_we_own_is_actually_emitted() {
    let emitted = emitted_paths();
    let missing: Vec<String> = owned_paths()
        .into_iter()
        .filter(|p| !emitted.contains(p))
        .collect();
    assert!(
        missing.is_empty(),
        "the generated fips.yaml no longer emits paths this project owns: {missing:?}\n\
         A dropped tuning key is silent upstream (no deny_unknown_fields on the \
         root Config), so nothing else would catch it: the config would simply \
         lose that setting on every node."
    );
}

/// The owned set must itself be real: every owned path must exist upstream, or
/// this module would enshrine a key upstream never defined — the exact defect
/// (`node.discovery.{timeout_secs,…}`) the bump removed.
#[test]
fn every_owned_path_exists_upstream() {
    let schema = upstream_paths();
    let bogus: Vec<String> = owned_paths()
        .into_iter()
        .filter(|p| !schema.contains(p))
        .collect();
    assert!(
        bogus.is_empty(),
        "owned_paths() lists paths upstream {PINNED_UPSTREAM_TAG} does not accept: {bogus:?}\n\
         An owned key that upstream does not define is ignored silently — this is \
         the phantom-key defect re-entering through the allowlist itself."
    );
}

#[test]
fn every_path_we_emit_is_valid_upstream() {
    let paths = upstream_paths();
    let mut invalid: Vec<String> = Vec::new();
    for p in emitted_paths() {
        // `peers` is a sequence; `walk` descends into the (empty) list, and its
        // element shape is asserted separately by `peer_list_shape_is_not_silently_wrong`.
        if p == "peers" || p.starts_with("peers.") {
            continue;
        }
        if !paths.contains(&p) {
            invalid.push(p);
        }
    }
    assert!(
        invalid.is_empty(),
        "generated fips.yaml emits paths upstream {PINNED_UPSTREAM_TAG} does not accept: {invalid:?}\n\
         Upstream drops unknown keys silently for several structs, so this is \
         exactly how a setting gets quietly ignored — the failure mode this \
         module exists to prevent."
    );
}

#[test]
fn we_no_longer_emit_the_deprecated_discovery_table() {
    // v0.5.0 split `node.discovery.*` into `node.lookup.*` + `node.rendezvous.*`.
    // Upstream keeps an all-Option compat shim that folds the legacy block and
    // logs a deprecation warning on every start, so emitting it is not fatal —
    // but it is dead weight and the warning is noise an operator cannot clear.
    let emitted = emitted_paths();
    assert!(
        !emitted.contains("node.discovery"),
        "generated config still emits the deprecated `node.discovery:` table"
    );
    // And the split targets are present, not merely the old table absent.
    assert!(emitted.contains("node.lookup.backoff_base_secs"));
    assert!(emitted.contains("node.rendezvous.lan.enabled"));
}

#[test]
fn the_three_phantom_keys_stay_deleted() {
    // These were emitted for months and silently ignored by every daemon.
    // A regression here is invisible in the field, so it is asserted directly.
    let emitted = emitted_paths();
    for phantom in [
        "node.discovery.timeout_secs",
        "node.discovery.retry_interval_secs",
        "node.discovery.max_attempts",
        "node.lookup.timeout_secs",
        "node.lookup.retry_interval_secs",
        "node.lookup.max_attempts",
    ] {
        assert!(
            !emitted.contains(phantom),
            "`{phantom}` is not a valid upstream key and must not be emitted"
        );
    }
}

#[test]
fn upstream_example_documents_the_new_split_tables() {
    // If upstream reverts the lookup/rendezvous split, the migration above is
    // dead code and this module's premise is wrong — fail loudly.
    assert!(
        UPSTREAM_EXAMPLE.contains("lookup:"),
        "upstream {PINNED_UPSTREAM_TAG} no longer documents `node.lookup:`"
    );
    assert!(
        UPSTREAM_EXAMPLE.contains("rendezvous:"),
        "upstream {PINNED_UPSTREAM_TAG} no longer documents `node.rendezvous:`"
    );
}

#[test]
fn tun_dns_and_transports_match_upstream_shape() {
    let tree = rendered();
    assert_eq!(tree["tun"]["name"], Value::String("fips0".into()));
    assert_eq!(tree["tun"]["mtu"], Value::Number(1280.into()));
    assert_eq!(tree["tun"]["enabled"], Value::Bool(true));
    // dns.bind_addr stays 127.0.0.1 — a loopback responder, not a mesh-exposed one.
    assert_eq!(tree["dns"]["bind_addr"], Value::String("127.0.0.1".into()));
    assert!(tree["transports"]["udp"]["bind_addr"].is_string());
    assert!(tree["transports"]["tcp"]["bind_addr"].is_string());
    assert!(tree["peers"].is_sequence());
}

#[test]
fn peer_list_shape_is_not_silently_wrong() {
    // `peers[].{npub, address, transport}` is NOT a valid upstream `PeerConfig`
    // (upstream takes `addresses: [{transport, addr, priority?}]`). The list is
    // always empty today, so this documents the gap rather than shipping a
    // wrong shape: if `peers` is ever populated, it must be rebuilt first.
    let tree = rendered();
    let peers = tree["peers"].as_sequence().expect("peers is a sequence");
    assert!(
        peers.is_empty(),
        "peers is populated but PeerEntry is not an upstream PeerConfig shape — \
         rewrite it as {{npub, alias?, addresses: [{{transport, addr, priority?}}]}} first"
    );
}
