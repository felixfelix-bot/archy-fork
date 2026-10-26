//! Keep the paid bridge reachable to the TollGate API on `:2121`.
//!
//! ## The defect this exists for
//!
//! `tollgate-wrt` ships nftables fragments that hardcode the name of the
//! captive bridge. `/etc/nftables.d/30-backend-firewall.nft` drops the backend
//! API from every interface except a fixed set:
//!
//! ```text
//! meta nfproto ipv4 iifname != { "br-lan", "br-private", "lo" } \
//!      tcp dport 2121 counter drop
//! ```
//!
//! Archipelago names that bridge `br-tollgate` (see [`wifi::provision_ssid`]),
//! so the package's own hardening drops the customer's call to the portal API.
//! Measured on a GL-MT3000 (25.12.5, tollgate-wrt 0.6.0-r1): the portal page
//! served fine on `:2050` while `:2121` timed out from the paid network, the
//! page sat on "Loading" forever, and the drop rule's own counter read
//! `315 packets / 18900 bytes`. Adding `br-tollgate` to that set takes the
//! client from `000` to `200` and the portal renders its price.
//!
//! ## Why it edits the packaged fragment rather than adding a rule
//!
//! nftables runs every base chain on a hook; an `accept` in one chain does not
//! stop a later chain from dropping. A separate include therefore cannot
//! rescue the packet — verified: a chain at `priority filter - 2` accepting
//! `br-tollgate tcp dport 2121` saw **zero** packets while the packaged drop
//! still fired. The only fix is to stop that fragment from dropping, so this
//! patches the interface set in place.
//!
//! ## This is a shim and says so
//!
//! The durable fix belongs upstream: the package should not hardcode the
//! bridge name (its own comment admits "an operator who renamed the captive
//! bridge loses this rule"). When upstream ships a name-independent rule this
//! module should be deleted. A package upgrade that replaces the fragment
//! undoes the patch, so provision re-applies it every run — which is exactly
//! why it is idempotent and cheap.

use anyhow::Result;
use tracing::info;

use crate::Router;

/// The packaged fragment that drops the backend API off non-LAN interfaces.
pub const BACKEND_FIREWALL_NFT: &str = "/etc/nftables.d/30-backend-firewall.nft";

/// The interface set as the package ships it. Order is significant: it must
/// match the file byte-for-byte for `sed` to replace it.
const SHIPPED_SET: &str = r#"{ "br-lan", "br-private", "lo" }"#;

/// The same set with the bridge Archipelago actually creates.
const PATCHED_SET: &str = r#"{ "br-lan", "br-private", "lo", "br-tollgate" }"#;

/// What [`ensure_paid_bridge_can_reach_api`] found.
#[derive(Debug, PartialEq, Eq)]
pub enum ApiReachability {
    /// The packaged fragment does not drop the API from the paid bridge.
    AlreadyCorrect,
    /// The fragment assumed `br-lan`; the paid bridge was added and the
    /// firewall reloaded.
    Patched,
    /// The fragment is absent, so the package no longer ships what this shim
    /// defends against — re-check whether the defect still exists.
    FragmentAbsent,
}

/// Make the TollGate API reachable from the paid bridge, and report what was
/// needed.
///
/// Idempotent: a second call on a patched router issues no write and no reload.
pub fn ensure_paid_bridge_can_reach_api(router: &Router) -> Result<ApiReachability> {
    let (exists, code) = router.run(&format!("test -f {BACKEND_FIREWALL_NFT}"))?;
    let _ = exists;
    if code != 0 {
        // Not an error: a future package may stop shipping this fragment. Say
        // so loudly instead of silently claiming the shim is in place.
        info!(
            "[{}] {BACKEND_FIREWALL_NFT} not present — the hardcoded-bridge rule \
             this shim defends against may be gone upstream; re-check whether \
             the portal API is reachable from the paid bridge",
            router.host
        );
        return Ok(ApiReachability::FragmentAbsent);
    }

    let (body, _) = router.run(&format!("cat {BACKEND_FIREWALL_NFT}"))?;
    if body.contains(PATCHED_SET) {
        return Ok(ApiReachability::AlreadyCorrect);
    }
    if !body.contains(SHIPPED_SET) {
        anyhow::bail!(
            "{BACKEND_FIREWALL_NFT} no longer matches the shipped interface set \
             {SHIPPED_SET}, so it cannot be patched safely — the package changed \
             shape and this shim needs re-deriving rather than guessing"
        );
    }

    // `sed` with `|` delimiters: the pattern contains braces, quotes and commas.
    router.run_ok(&format!(
        "sed -i 's|{SHIPPED_SET}|{PATCHED_SET}|g' {BACKEND_FIREWALL_NFT}"
    ))?;

    // The fragment is loaded by fw4, so the rule only changes after a reload.
    router.run_ok("/etc/init.d/firewall reload >/dev/null 2>&1")?;

    info!(
        "[{}] allowed the TollGate API from br-tollgate — the packaged \
         {BACKEND_FIREWALL_NFT} only allowed br-lan/br-private, which dropped \
         the portal's own API call from the paid network",
        router.host
    );
    Ok(ApiReachability::Patched)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn patches_the_shipped_set_and_reloads_the_firewall() {
        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let router = Router::scripted(move |cmd| {
            log.lock().unwrap().push(cmd.to_string());
            if cmd.contains("test -f") {
                return Ok((String::new(), 0));
            }
            if cmd.starts_with("cat ") {
                return Ok((
                    format!("meta iifname != {SHIPPED_SET} tcp dport 2121 counter drop\n"),
                    0,
                ));
            }
            Ok((String::new(), 0))
        });

        let outcome = ensure_paid_bridge_can_reach_api(&router).unwrap();
        assert_eq!(outcome, ApiReachability::Patched);

        let cmds = seen.lock().unwrap().clone();
        assert!(
            cmds.iter()
                .any(|c| c.contains("sed -i") && c.contains("br-tollgate")),
            "must add br-tollgate to the interface set: {cmds:#?}"
        );
        assert!(
            cmds.iter()
                .any(|c| c.contains("/etc/init.d/firewall reload")),
            "must reload the firewall or the patched fragment is never loaded: {cmds:#?}"
        );
    }

    #[test]
    fn an_already_patched_router_is_not_written_to() {
        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let router = Router::scripted(move |cmd| {
            log.lock().unwrap().push(cmd.to_string());
            if cmd.contains("test -f") {
                return Ok((String::new(), 0));
            }
            if cmd.starts_with("cat ") {
                return Ok((format!("iifname != {PATCHED_SET} drop\n"), 0));
            }
            Ok((String::new(), 0))
        });

        assert_eq!(
            ensure_paid_bridge_can_reach_api(&router).unwrap(),
            ApiReachability::AlreadyCorrect
        );
        let cmds = seen.lock().unwrap().clone();
        assert!(
            !cmds.iter().any(|c| c.contains("sed -i")),
            "must not rewrite an already-correct fragment: {cmds:#?}"
        );
        assert!(
            !cmds.iter().any(|c| c.contains("firewall reload")),
            "must not reload a firewall it did not change: {cmds:#?}"
        );
    }

    #[test]
    fn a_changed_fragment_fails_instead_of_guessing() {
        let router = Router::scripted(|cmd| {
            if cmd.contains("test -f") {
                return Ok((String::new(), 0));
            }
            if cmd.starts_with("cat ") {
                // Package reshaped the rule: different set, same intent.
                return Ok((
                    "iifname != { \"br-lan\", \"br-guest\", \"lo\" } drop\n".into(),
                    0,
                ));
            }
            Ok((String::new(), 0))
        });

        let err = ensure_paid_bridge_can_reach_api(&router)
            .expect_err("an unrecognised fragment must not be patched blind");
        assert!(
            err.to_string().contains("no longer matches"),
            "error should say the shape changed, got: {err}"
        );
    }

    #[test]
    fn an_absent_fragment_is_reported_not_treated_as_success() {
        let router = Router::scripted(|cmd| {
            if cmd.contains("test -f") {
                return Ok((String::new(), 1)); // gone
            }
            Ok((String::new(), 0))
        });
        assert_eq!(
            ensure_paid_bridge_can_reach_api(&router).unwrap(),
            ApiReachability::FragmentAbsent
        );
    }
}
