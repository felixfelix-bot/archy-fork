//! FIPS (Free Internetworking Peering System) daemon integration.
//!
//! github.com/jmcorgan/fips — a spanning-tree mesh routing protocol that
//! uses Nostr secp256k1 keys as native node identity. Archipelago ships
//! the daemon as an apt package, feeds it the seed-derived key from
//! `/data/identity/fips_key`, and supervises it via
//! `archipelago-fips.service`.
//!
//! This module is the in-process bridge:
//!   - [`service`]: systemctl status / start / stop / restart / unmask.
//!   - [`config`]: materialise `/etc/fips/fips.yaml` + install the key.
//!   - [`update`]: query GitHub (tracking `main`) for a newer build,
//!     verify SHA256, install via dpkg, restart.
//!
//! Privileged operations shell out via `sudo systemctl …` and `sudo dpkg …`
//! (mirroring the vpn/update patterns already in the codebase); the
//! sudoers rule shipped in the ISO whitelists exactly those commands for
//! the `archipelago` service user.
//!
//! FIPS is dark on the wire until onboarding writes the key. Before that,
//! `FipsStatus::installed` reports the package state and `service_active`
//! returns false; the transport router keeps routing via Tor.

// Consumers land in the next phase (RPC endpoints + onboarding hookup);
// the module is deliberately API-ready ahead of those call-sites.
#![allow(dead_code)]

pub mod anchors;
pub mod app_ports;
pub mod config;
/// Contract tests asserting the generated `fips.yaml` against the verbatim
/// upstream example at the pinned tag. Test-only module — see the file header.
#[cfg(test)]
mod config_upstream_contract;
pub mod dial;
pub mod endpoints;
pub mod iface;
pub mod service;
pub mod ssh_mesh;
pub mod telemetry;
pub mod update;

use serde::{Deserialize, Serialize};

/// Auto-activate FIPS with no user interaction. Once seed onboarding has
/// materialised the fips key, install the daemon config + start the service if
/// it isn't already up. Idempotent and best-effort: FIPS is the preferred
/// transport and should come up on its own — the UI "Activate" button is now a
/// manual fallback, not a requirement. No-op pre-onboarding (no key yet) or
/// when the service is already active.
pub async fn ensure_activated(data_dir: &std::path::Path) {
    let identity_dir = identity_dir_from(data_dir);
    if !identity_dir.join("fips_key").exists() {
        return; // pre-onboarding: nothing to activate yet
    }
    if dial::is_service_active().await {
        return; // already up
    }
    tracing::info!("FIPS inactive — auto-activating (no user interaction needed)");
    if let Err(e) = config::install(&identity_dir).await {
        tracing::warn!("FIPS auto-activate: config install failed: {:#}", e);
        return;
    }
    let unit = service::activation_unit().await;
    if let Err(e) = service::activate(unit).await {
        tracing::warn!("FIPS auto-activate: service activate failed: {:#}", e);
        return;
    }
    tracing::info!("FIPS auto-activated");
}

/// Spawn the FIPS supervisor: every 25s it (1) auto-activates FIPS if onboarding
/// is done but the service is down — so it comes up with zero user interaction,
/// and (2) keeps hole-punched paths to known federation peers warm, so on-demand
/// dials land on FIPS instead of falling back to Tor. Warms peers concurrently
/// so one slow/offline peer doesn't delay the rest.
///
/// The interval MUST be shorter than the NAT/hole-punch cold window
/// (`warm_path` docs it at ~30-60s). The previous 45s sat at the edge of that
/// window: a path that went cold at ~30s stayed cold until the next 45s tick,
/// so real peer dials in that gap hit a cold path and fell back to Tor (~18s
/// onion latency instead of FIPS's ~2-3s). 25s keeps every path refreshed
/// inside the minimum cold window, which is what actually makes FIPS — not Tor —
/// the transport peer requests land on. Measured: warm FIPS browse ~2.6s vs a
/// cold-path fallback browse ~18-22s over Tor to the same peer.
pub fn spawn_fips_supervisor(data_dir: std::path::PathBuf) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(25));
        // Connectivity watcher state: re-apply seed anchors the moment the
        // anchor link drops (edge) or the data path degrades (dials keep
        // failing with zero successes), instead of waiting for the 300s
        // anchor tick. Bounded: at most one re-apply per RE_APPLY_BACKOFF.
        const RE_APPLY_BACKOFF: std::time::Duration = std::time::Duration::from_secs(60);
        let mut prev_connected: Option<bool> = None;
        let mut prev_totals = telemetry::totals();
        let mut last_apply: Option<std::time::Instant> = None;
        loop {
            tick.tick().await;
            // Bring FIPS up on its own once onboarding has materialised the key.
            ensure_activated(&data_dir).await;
            if !dial::is_service_active().await {
                prev_connected = None; // daemon restart = fresh edge detection
                continue;
            }

            // ── Warm the union of federation peers + configured seed
            // anchors. Warming only federation npubs left the direct
            // anchors (vps2, LAN peers) to go cold between 300s ticks.
            let nodes = crate::federation::load_nodes(&data_dir)
                .await
                .unwrap_or_default();
            let seed = anchors::load(&data_dir).await.unwrap_or_default();
            let mut warm_npubs: std::collections::BTreeSet<String> =
                nodes.iter().filter_map(|n| n.fips_npub.clone()).collect();
            warm_npubs.extend(seed.iter().map(|a| a.npub.clone()));
            let mut handles = Vec::new();
            for npub in warm_npubs {
                // Service-active was checked once above for the whole batch.
                handles.push(tokio::spawn(async move {
                    dial::warm_path_unchecked(&npub).await
                }));
            }
            for h in handles {
                let _ = h.await;
            }

            // ── Connectivity watcher: detect anchor-link loss AND silent
            // data-path death (daemon reports "connected" but every dial
            // connect-fails — observed live on .198, 2026-07-27, where the
            // 300s tick never healed it).
            let mut anchor_npubs = vec![service::PUBLIC_ANCHOR_NPUB.to_string()];
            anchor_npubs.extend(seed.iter().map(|a| a.npub.clone()));
            let (_, connected) = service::peer_connectivity_summary(&anchor_npubs).await;
            let totals = telemetry::totals();
            let link_dropped = prev_connected == Some(true) && !connected;
            let never_connected = prev_connected.is_none() && !connected;
            let data_path_dead =
                totals.1.saturating_sub(prev_totals.1) >= 5 && totals.0 == prev_totals.0;
            prev_connected = Some(connected);
            prev_totals = totals;

            let backoff_ok = last_apply.is_none_or(|t| t.elapsed() >= RE_APPLY_BACKOFF);
            if (link_dropped || never_connected || data_path_dead) && backoff_ok && !seed.is_empty()
            {
                tracing::info!(
                    link_dropped,
                    never_connected,
                    data_path_dead,
                    "FIPS connectivity degraded — re-applying seed anchors now"
                );
                last_apply = Some(std::time::Instant::now());
                let _ = anchors::apply(&seed).await;
            }
        }
    });
}
use std::path::{Path, PathBuf};

/// Systemd unit name supervised by archipelago.
pub const SERVICE_UNIT: &str = "archipelago-fips.service";

/// Path the FIPS daemon reads its config from (Debian package default).
pub const DAEMON_CONFIG_PATH: &str = "/etc/fips/fips.yaml";

/// Path the FIPS daemon reads its private key from.
pub const DAEMON_KEY_PATH: &str = "/etc/fips/fips.key";

/// Path the FIPS daemon reads its public key from.
pub const DAEMON_PUB_PATH: &str = "/etc/fips/fips.pub";

/// Upstream repository the updater tracks.
pub const UPSTREAM_REPO: &str = "jmcorgan/fips";

/// Highest upstream release whose config schema and key paths
/// `fips::config::render_config_yaml()` has been verified against.
///
/// The ISO pins exactly this tag (`ARG FIPS_VERSION` in
/// `image-recipe/_archived/build-auto-installer-iso.sh`), and the contract
/// tests in `fips::config_upstream_contract` assert the generated config
/// against the verbatim upstream artefacts at it.
///
/// The runtime updater previously floated to whatever `/releases/latest`
/// returned, with no ceiling. That made the "verified against <tag>" claim in
/// `config.rs` and this module false the moment an operator pressed Update:
/// a node would run a daemon whose schema nobody had checked, against a config
/// written for an older one. Upstream has since split `node.discovery.*` into
/// `node.lookup.*` + `node.rendezvous.*` (v0.5.0) and tightened config
/// validation (v0.5.3 refuses to start on a config that configures nothing),
/// so "latest is probably fine" is not a safe assumption to ship on.
///
/// Bumping this constant is the LAST step of a version bump, after the config
/// module, the fixtures and the contract tests all move together.
pub const VERIFIED_UPSTREAM_VERSION: &str = "0.5.3";

/// Default UDP port the daemon listens on.
pub const DEFAULT_UDP_PORT: u16 = 8668;

/// UDP port archipelago actually publishes/binds for the daemon. The
/// container publishes `2121:2121/udp` (see `package/config.rs`) and every
/// peer roster in the fleet dials `<host>:2121`, but the rendered daemon
/// config used to bind upstream's 8668 — leaving inbound UDP dead on
/// bridged-network installs and everything silently riding TCP 8443. The
/// bind now uses this port so the published mapping, the fleet rosters,
/// and the pairing QR all agree.
pub const PUBLISHED_UDP_PORT: u16 = 2121;

/// Default TCP port the daemon listens on. Used as a fallback when a
/// peer can't be reached over UDP — common on networks that block UDP
/// (corporate/guest wifi) and the path the public fips.v0l.io anchor
/// currently accepts. Upstream factory default enables both transports
/// and archipelago intentionally matches that baseline so fresh nodes
/// can reach the broader FIPS mesh without operator config.
pub const DEFAULT_TCP_PORT: u16 = 8443;

/// Upstream systemd unit shipped by the `fips` debian package. Archipelago
/// prefers its own supervision (`archipelago-fips.service`) but respects an
/// already-running upstream unit so legacy/dev nodes — where no seed-derived
/// key exists — still report FIPS as active in the UI.
pub const UPSTREAM_SERVICE_UNIT: &str = "fips.service";

/// Aggregated runtime status of the FIPS subsystem, surfaced to the dashboard.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FipsStatus {
    /// Whether the `fips` debian package is installed on the host.
    pub installed: bool,
    /// Installed daemon version string reported by `fipsctl --version`,
    /// or None if not installed / not queryable.
    pub version: Option<String>,
    /// `systemctl is-active archipelago-fips.service` result: "active",
    /// "inactive", "failed", "masked", "unknown".
    pub service_state: String,
    /// State of the upstream `fips.service` (shipped by the debian package).
    pub upstream_service_state: String,
    /// True if either the archipelago-managed or upstream unit is active.
    pub service_active: bool,
    /// Whether the seed-derived FIPS key has been materialised on disk.
    /// The archipelago-managed service cannot start meaningfully until
    /// this is true; legacy nodes may still report FIPS active via the
    /// upstream unit without this file.
    pub key_present: bool,
    /// Local FIPS npub (bech32). Prefers the seed-derived key when
    /// present; falls back to the upstream daemon's own key on legacy
    /// nodes where `/etc/fips/fips.pub` is readable.
    pub npub: Option<String>,
    /// Number of currently authenticated FIPS peers, per
    /// `fipsctl show peers`. 0 → isolated / anchor unreachable;
    /// >0 → DHT routing is viable.
    #[serde(default)]
    pub authenticated_peer_count: u32,
    /// True when at least one peer in the identity cache is a known
    /// public anchor (currently `fips.v0l.io`). Anchors bootstrap DHT
    /// routing for general-case deployments, so a red anchor status is
    /// the top UX indicator of "FIPS traffic will probably degrade to
    /// Tor until the anchor is reachable."
    #[serde(default)]
    pub anchor_connected: bool,
}

impl FipsStatus {
    /// Snapshot the current state across package, key, and service.
    ///
    /// `data_dir` is the archipelago data-dir (used to load the
    /// operator-configured seed-anchor list so "anchor_connected" means
    /// "at least one authenticated peer matches a public or configured
    /// seed anchor", not just "fips.v0l.io specifically").
    pub async fn query(data_dir: &Path) -> Self {
        let identity_dir = identity_dir_from(data_dir);
        let installed = service::package_installed().await;
        let version = if installed {
            service::daemon_version().await.ok()
        } else {
            None
        };
        let service_state = service::unit_state(SERVICE_UNIT).await;
        let upstream_service_state = service::unit_state(UPSTREAM_SERVICE_UNIT).await;
        let service_active = service_state == "active" || upstream_service_state == "active";
        let key_present = crate::identity::fips_key_exists(&identity_dir);

        // Prefer the seed-derived npub; otherwise read the daemon's own
        // key file at /etc/fips/fips.pub (world-readable per debian pkg).
        let npub = match crate::identity::fips_npub(&identity_dir).await {
            Ok(Some(n)) => Some(n),
            _ => service::read_upstream_npub().await.ok().flatten(),
        };

        let (authenticated_peer_count, anchor_connected) = if service_active {
            // Build the anchor-candidate list: hardcoded public anchor
            // plus every entry in the operator's seed-anchors.json.
            // The card lights up if any of them is authenticated.
            let mut anchor_npubs = vec![service::PUBLIC_ANCHOR_NPUB.to_string()];
            if let Ok(seed) = anchors::load(data_dir).await {
                anchor_npubs.extend(seed.into_iter().map(|a| a.npub));
            }
            service::peer_connectivity_summary(&anchor_npubs).await
        } else {
            (0, false)
        };

        Self {
            installed,
            version,
            service_state,
            upstream_service_state,
            service_active,
            key_present,
            npub,
            authenticated_peer_count,
            anchor_connected,
        }
    }
}

/// Compose a data-dir–relative identity directory path.
/// Mirrors the convention used elsewhere in the codebase so callers don't
/// have to repeat the `.join("identity")` each time.
pub fn identity_dir_from(data_dir: &Path) -> PathBuf {
    data_dir.join("identity")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_status_reports_no_key_pre_onboarding() {
        let dir = tempfile::tempdir().unwrap();
        // query() now takes a data_dir (parent) rather than identity_dir,
        // since it also reads seed-anchors.json for the anchor check.
        // No identity/ subdir → no key; no seed-anchors.json → public
        // anchor is the only candidate.
        let status = FipsStatus::query(dir.path()).await;
        assert!(!status.key_present, "no key before onboarding");
        // `npub` falls back to whatever an already-running local fips
        // daemon advertises, so on a dev machine or node with fips
        // installed this field can be Some(...) even when the test
        // data_dir is empty. We only assert that key_present is false.
        // `installed`, `service_state`, `version` depend on the host and are
        // not asserted here — query() must return cleanly regardless.
    }

    #[test]
    fn test_identity_dir_from() {
        let data = Path::new("/var/lib/archipelago");
        assert_eq!(
            identity_dir_from(data),
            Path::new("/var/lib/archipelago/identity")
        );
    }

    #[test]
    fn test_constants_have_expected_shape() {
        assert!(SERVICE_UNIT.ends_with(".service"));
        assert!(DAEMON_CONFIG_PATH.starts_with('/'));
        assert!(DAEMON_KEY_PATH.starts_with('/'));
        assert_eq!(UPSTREAM_REPO, "jmcorgan/fips");
    }
}
