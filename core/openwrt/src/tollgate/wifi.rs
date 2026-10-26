use anyhow::{Context, Result};
use tracing::info;

use crate::tollgate::TollGateConfig;
use crate::Router;

/// Create (or update) the dedicated pay-as-you-go WiFi interface for TollGate.
///
/// Uses a fixed named section (`wireless.tollgate`) rather than `uci add`, so
/// re-provisioning (e.g. editing price/mint URL after install) updates the
/// same interface in place instead of piling up a new `wifi-iface` section —
/// and therefore a new duplicate broadcast SSID — on every call.
pub fn provision_ssid(router: &Router, cfg: &TollGateConfig) -> Result<()> {
    let radio = detect_radio(router).context("detect WiFi radio")?;
    info!("[{}] Using radio {} for TollGate SSID", router.host, radio);

    router.uci_apply(
        "wireless",
        &[
            ("wireless.tollgate", "wifi-iface"),
            ("wireless.tollgate.device", &radio),
            ("wireless.tollgate.mode", "ap"),
            ("wireless.tollgate.ssid", &cfg.ssid),
            ("wireless.tollgate.encryption", "none"),
            ("wireless.tollgate.network", "tollgate"),
            // Disable 802.11r/k/v — unnecessary for transient pay-as-you-go clients.
            ("wireless.tollgate.ieee80211r", "0"),
            // Stop broadcasting entirely when disabled, rather than leaving an
            // open SSID up that leads nowhere once the backend is stopped.
            (
                "wireless.tollgate.disabled",
                if cfg.enabled { "0" } else { "1" },
            ),
        ],
    )?;

    provision_network(router)?;
    provision_firewall(router)?;

    Ok(())
}

/// Add a `tollgate` network interface (isolated LAN for TollGate clients).
///
/// Binds to a named bridge device (`br-tollgate`) rather than leaving the
/// wifi-iface as the network's raw device — NoDogSplash's `gatewayinterface`
/// needs a stable, known interface name to gate (see `nodogsplash::provision`),
/// and the driver-assigned name of a bare wifi vif (e.g. `phy0-ap0`) isn't
/// guaranteed across hardware.
fn provision_network(router: &Router) -> Result<()> {
    router.uci_apply(
        "network",
        &[
            ("network.tollgate_bridge", "device"),
            ("network.tollgate_bridge.type", "bridge"),
            ("network.tollgate_bridge.name", "br-tollgate"),
            ("network.tollgate", "interface"),
            ("network.tollgate.device", "br-tollgate"),
            ("network.tollgate.proto", "static"),
            ("network.tollgate.ipaddr", "192.168.99.1"),
            ("network.tollgate.netmask", "255.255.255.0"),
            // NoDogSplash only manages IPv4 iptables rules. If IPv6 RA/DHCPv6
            // stays enabled, clients get routable IPv6 addresses and their OS
            // validates connectivity (and browses freely) over IPv6, bypassing
            // the portal entirely. See OpenTollGate/tollgate-module-basic-go#148.
            ("network.tollgate.ip6assign", "0"),
        ],
    )?;

    // Enable DHCP for the tollgate interface.
    router.uci_apply(
        "dhcp",
        &[
            ("dhcp.tollgate", "dhcp"),
            ("dhcp.tollgate.interface", "tollgate"),
            ("dhcp.tollgate.start", "100"),
            ("dhcp.tollgate.limit", "150"),
            ("dhcp.tollgate.leasetime", "5m"),
            ("dhcp.tollgate.ra", "disabled"),
            ("dhcp.tollgate.dhcpv6", "disabled"),
        ],
    )?;

    Ok(())
}

/// Add firewall zone for the tollgate interface.
///
/// This zone only isolates tollgate clients from other LAN segments and
/// opens the payment port to the router. Per-client forwarding to WAN is
/// actually gated by NoDogSplash's own iptables rules (via `ndsctl`), not by
/// anything in this static firewall config — `tollgate-wrt` has no netfilter
/// code of its own. See `nodogsplash::provision`.
fn provision_firewall(router: &Router) -> Result<()> {
    // Zone
    router.uci_apply(
        "firewall",
        &[
            ("firewall.tollgate_zone", "zone"),
            ("firewall.tollgate_zone.name", "tollgate"),
            ("firewall.tollgate_zone.network", "tollgate"),
            ("firewall.tollgate_zone.input", "ACCEPT"),
            ("firewall.tollgate_zone.output", "ACCEPT"),
            ("firewall.tollgate_zone.forward", "REJECT"),
        ],
    )?;

    // Forwarding rule: tollgate → wan (TollGate manages which clients can forward)
    router.uci_apply(
        "firewall",
        &[
            ("firewall.tollgate_fwd", "forwarding"),
            ("firewall.tollgate_fwd.src", "tollgate"),
            ("firewall.tollgate_fwd.dest", "wan"),
        ],
    )?;

    Ok(())
}

/// Fold the upstream `tollgate-module-basic-go` installer's own default
/// AP(s) onto the gated `tollgate` network.
///
/// The package's own `postinst` runs its `/etc/uci-defaults/*` first-boot
/// scripts on every install and upgrade (both install paths now go through the
/// real package manager, so `default_postinst` sees the file list). Those
/// upstream scripts rebrand OpenWrt's
/// factory-default wifi sections (`wireless.default_radioN`, present on
/// every fresh install) to a `TollGate-<serial>` SSID, but only ever touch
/// the SSID — they leave `network` at its original `lan` binding. Nothing
/// else in this project's own provisioning (`provision_ssid` above) ever
/// looks at those sections; it only manages the separate `wireless.tollgate`
/// SSID it creates itself. Left alone, the result is two open SSIDs
/// broadcasting side by side: ours (gated by NoDogSplash) and upstream's
/// (wide open on `lan`, with a direct route to whatever's plugged into the
/// wired LAN port).
///
/// Confirmed live against archy-x250-pa3 2026-09-07: a client joining
/// "TollGate-3458" landed on `br-lan` with unrestricted WAN forwarding and
/// zero NoDogSplash involvement — free, unmetered internet, no captive
/// portal, on the router's own admin network.
///
/// Must run after `provision_network` (needs the `tollgate` network/bridge
/// to already exist) and before the network/wifi restart in
/// `restart_services` picks the new binding up.
pub fn regate_upstream_default_aps(router: &Router) -> Result<()> {
    let sections = router.run_ok(
        "uci show wireless 2>/dev/null | grep -o '^wireless\\.default_radio[0-9]*' | sort -u",
    )?;
    for section in sections.lines().map(str::trim).filter(|s| !s.is_empty()) {
        let network_key = format!("{}.network", section);
        let current = router.uci_get(&network_key).unwrap_or_default();
        let ssid = router
            .uci_get(&format!("{}.ssid", section))
            .unwrap_or_default();
        // A failed/changed upstream first-boot script can leave a stock
        // default_radioN section in place. Moving that interface merely
        // because it is on LAN can seize the router's existing management AP.
        // Only the public APs the TollGate installer demonstrably rebranded
        // belong on the paid network.
        if should_regate_upstream_ap(&current, &ssid) {
            info!(
                "[{}] Re-gating upstream default AP {} ({}) onto the tollgate network",
                router.host, section, ssid
            );
            router.uci_set(&network_key, "tollgate")?;
        }
    }
    router.uci_commit(Some("wireless"))?;
    Ok(())
}

fn should_regate_upstream_ap(network: &str, ssid: &str) -> bool {
    network.trim() == "lan" && ssid.trim().starts_with("TollGate-")
}

/// Return the first available wireless radio device name (e.g. "radio0").
fn detect_radio(router: &Router) -> Result<String> {
    let out =
        router.run_ok("uci show wireless | grep -o 'wireless\\.radio[0-9]*\\.type' | head -1")?;
    // Extract "radioN" from "wireless.radioN.type"
    let radio = out.trim().split('.').nth(1).unwrap_or("radio0").to_string();
    Ok(radio)
}

#[cfg(test)]
mod tests {
    use super::should_regate_upstream_ap;

    #[test]
    fn regates_only_confirmed_upstream_tollgate_aps() {
        assert!(should_regate_upstream_ap("lan", "TollGate-3458"));
        assert!(should_regate_upstream_ap(" lan\n", " TollGate-A1B2 "));

        assert!(!should_regate_upstream_ap("lan", "OpenWrt"));
        assert!(!should_regate_upstream_ap("lan", "Archipelago Admin"));
        assert!(!should_regate_upstream_ap("tollgate", "TollGate-3458"));
        assert!(!should_regate_upstream_ap("lan", "tollgate-3458"));
    }
}
