pub mod assets;
pub mod config;
pub mod firewall;
pub mod install;
pub mod nodogsplash;
pub mod verify;
pub mod version;
pub mod wifi;

pub use assets::{AssetShape, PackageTarget, FEED_REPO, LEGACY_REPO};
pub use config::TollGateConfig;
pub use install::{
    install_runtime_deps, install_tollgate, installed_tollgate_version,
    installed_tollgate_version_any, read_package_target, TOLLGATE_VERSION,
};
pub use verify::{manifest_url, verify_download, VerifyOutcome};
pub use version::{package_version_from_pin, TOLLGATE_PACKAGE, TOLLGATE_SERVICE_BIN};
pub use wifi::provision_ssid;

use anyhow::{Context, Result};
use tracing::info;

use crate::{opkg::PkgManager, Router};

/// Full TollGate provisioning sequence:
/// 1. Install `tollgate-wrt` at the pinned release
/// 2. Install NoDogSplash and immediately stop it (its postinst auto-starts
///    it against `br-lan` by default — see `nodogsplash::install_and_stop`)
/// 3. Write TollGate config: UCI (status/detection only) + the JSON file the
///    daemon actually reads
/// 4. Create the pay-as-you-go WiFi SSID and its dedicated bridge/network
/// 5. Configure NoDogSplash to gate that bridge (now that it exists) —
///    client gating; tollgate-wrt has no enforcement code of its own
/// 6. Restart affected services
pub async fn provision(router: &Router, config: &TollGateConfig) -> Result<()> {
    info!("[{}] Starting TollGate provisioning", router.host);

    let pkg_mgr = router.opkg_check()?;
    match pkg_mgr {
        PkgManager::Opkg => {
            router.opkg_update()?;
            install_tollgate(router)?;
        }
        PkgManager::ApkNative => {
            install::install_tollgate_apk_native(router)?;
        }
    }

    // Runtime dependencies the package declares but that no install path here
    // resolves: jq decides which UI answers the entry ports, and ca-bundle is
    // what lets the gateway verify a mint over TLS. Installed after the
    // package so a failure names the dependency rather than the package.
    install::install_runtime_deps(router, pkg_mgr)?;

    // NoDogSplash is a hard runtime dependency of tollgate-wrt (upstream's
    // package declares `+nodogsplash`), but neither install path above pulls
    // it in: both install paths install a single verified local asset with no
    // feed solver behind it (opkg/apk resolve deps only for packages they
    // fetch themselves), so nothing pulls the declared DEPENDS in.
    // Without it, tollgate-wrt runs and accepts payments but never actually
    // blocks unpaid clients. Install + stop happens before anything else so
    // its auto-started default config (gating br-lan) is live for as little
    // time as possible.
    nodogsplash::install_and_stop(router, pkg_mgr)
        .context("install nodogsplash — tollgate-wrt cannot gate clients without it")?;

    // Wire NoDogSplash's webroot to TollGate's actual payment portal instead
    // of the generic stock splash page it ships with. Confirmed live: without
    // this, "click continue" on the stock page authorizes the client via
    // NoDogSplash's own built-in handler with zero payment involved.
    nodogsplash::install_captive_portal_symlink(router).context(
        "wire up TollGate's captive portal — without it NoDogSplash serves its own \
         generic splash page, which authorizes clients on click with no payment",
    )?;

    config::apply(router, config)?;
    wifi::provision_ssid(router, config)?;
    // Must come after provision_ssid (creates the `tollgate` network this
    // folds the upstream installer's own default AP onto) — see
    // regate_upstream_default_aps for why this is needed at all.
    wifi::regate_upstream_default_aps(router)
        .context("re-gate upstream tollgate-module-basic-go default AP(s)")?;
    // Must come after provision_ssid (which creates br-tollgate) and before
    // the daemon restart below — config.json is only read at startup.
    config::apply_daemon_config(router, config)
        .context("write /etc/tollgate/config.json — tollgate-wrt reads this, not UCI")?;
    config::apply_payout_identity(router, config.payout_address.as_deref())
        .context("write /etc/tollgate/identities.json owner payout address")?;
    // Also must come after provision_ssid: points gatewayinterface at
    // br-tollgate, which provision_ssid is what creates.
    nodogsplash::configure(router, config)
        .context("configure nodogsplash — tollgate-wrt cannot gate clients without it")?;

    // The packaged nft fragments assume the captive bridge is called
    // br-lan; this deployment calls it br-tollgate, so the backend API
    // (the portal's own data source) was dropped from the paid network.
    firewall::ensure_paid_bridge_can_reach_api(router)
        .context("allow the TollGate API from the paid bridge")?;

    restart_services(router, config.enabled)?;
    nodogsplash::restart(router)?;

    info!("[{}] TollGate provisioning complete", router.host);
    Ok(())
}

/// Applies `enabled` to the actual running service, not just the UCI value —
/// the tollgate-wrt init script doesn't consult `tollgate.main.enabled`
/// itself, so toggling it requires an explicit enable/start or disable/stop.
///
/// The service's init script is `/etc/init.d/tollgate-wrt` (its actual
/// on-disk name — "tollgate" alone does not exist).
fn restart_services(router: &Router, enabled: bool) -> Result<()> {
    if enabled {
        router.run_ok("/etc/init.d/tollgate-wrt enable")?;
        router.run_ok("/etc/init.d/tollgate-wrt restart || /etc/init.d/tollgate-wrt start")?;
    } else {
        router.run_ok("/etc/init.d/tollgate-wrt stop || true")?;
        router.run_ok("/etc/init.d/tollgate-wrt disable || true")?;
    }
    router.run_ok("/etc/init.d/network restart")?;

    // Everything below is wifi-dependent, and its absence is a fact about the
    // device, not a provisioning failure. A router with no radio — an x86 VM,
    // a wifi-less CPE, or a board whose radio is disabled — has no `wifi`
    // command at all (`ash: wifi: not found`, exit 127). Treating that as
    // fatal aborts AFTER the package is already installed and verified, so
    // `provision-tollgate` reports failure for a provision that succeeded and
    // callers retry or alarm on a working router.
    //
    // The repo already handles this correctly one module over — `wan.rs` runs
    // `wifi down` with `run`, logs a non-zero status, and falls through to a
    // `network restart`. Follow that: a wifi reload that cannot happen is
    // logged, not propagated.
    //
    // Ask the KERNEL for a radio, not the filesystem for a script. A `wifi`
    // script is not a radio: the x86 image accepts `wifi-scripts` with no phy
    // behind it, and a board with its radios disabled has the script too.
    // Measured: with `wifi-scripts` installed on a radio-less guest this probe
    // returned true, the reload failed harmlessly, and the br-tollgate check
    // below then aborted provisioning after 5 cycles — the same
    // success-reported-as-failure this block exists to remove, moved one step
    // later. `/sys/class/ieee80211/` has one entry per real phy and is empty
    // when there is nothing to drive.
    let wireless_present = router
        .run("ls /sys/class/ieee80211/ 2>/dev/null | grep -q .")
        .map(|(_, code)| code == 0)
        .unwrap_or(false);

    if !wireless_present {
        info!(
            "[{}] no radio on this device — skipping wireless reload (br-tollgate stays unclaimed)",
            router.host
        );
        return Ok(());
    }

    // Reload wireless so wireless.tollgate.disabled takes effect on the radio —
    // `network restart` alone doesn't reliably reconfigure wifi interfaces.
    let (wifi_out, wifi_code) = router.run("wifi down 2>&1; wifi up 2>&1")?;
    if wifi_code != 0 {
        info!(
            "[{}] wifi reload failed ({}): {} — continuing, the package is already installed",
            router.host,
            wifi_code,
            wifi_out.trim()
        );
    }

    // Observed live, twice, in two different ways: netifd can lose the race
    // to claim br-tollgate as the wifi vif attaches to it during the restart
    // above. The first time it showed up as netifd reporting
    // "up: false, DEVICE_CLAIM_FAILED"; the second time netifd reported the
    // interface up with its address assigned while the kernel-level device
    // genuinely had none (`ip -4 addr show br-tollgate` empty) — dnsmasq
    // logged "DHCP packet received on br-tollgate which has no address" and
    // silently dropped every DISCOVER. A single blind ifdown/ifup isn't
    // trustworthy here — verify the address actually landed at the kernel
    // level (not just what netifd claims) and retry the cycle if not, since
    // NoDogSplash refuses to start against an interface that isn't really up
    // and dnsmasq will silently refuse to answer DHCP without erroring loudly.
    //
    // Still fatal when there IS a radio: reaching here with `wireless_present`
    // true means the device can host a paid SSID, so an unclaimed br-tollgate
    // is a genuine fault that would leave every client pointed at a dead
    // gateway.
    let (cycle_out, cycle_code) = router.run(
        "sleep 2; \
         for i in 1 2 3 4 5; do \
             ifdown tollgate 2>&1; sleep 1; ifup tollgate 2>&1; sleep 2; \
             ip -4 addr show br-tollgate 2>/dev/null | grep -q 'inet ' && break; \
             echo \"br-tollgate has no kernel-level IPv4 address after cycle $i, retrying\"; \
         done; \
         ip -4 addr show br-tollgate 2>/dev/null | grep -q 'inet ' || \
             { echo 'br-tollgate never got a kernel-level IPv4 address after 5 cycles'; exit 1; }",
    )?;
    if cycle_code != 0 {
        anyhow::bail!(
            "br-tollgate has no kernel-level IPv4 address after 5 ifdown/ifup cycles: {}",
            cycle_out.trim()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// A router with no radio: the wifi reload and the br-tollgate address
    /// check must both be skipped rather than failing the whole provision.
    ///
    /// Two measured forms of "no radio", both regression-guarded here:
    ///   1. no `wifi` command at all (`ash: wifi: not found`, exit 127);
    ///   2. a `wifi` command present with no phy behind it — installing
    ///      `wifi-scripts` on the x86 lab guest produced exactly this, and a
    ///      probe for the script returned true, so the br-tollgate check ran and
    ///      aborted provisioning after 5 cycles. The probe must ask
    ///      `/sys/class/ieee80211/` (one entry per real phy), not the filesystem
    ///      for a script.
    #[test]
    fn restart_services_tolerates_a_device_with_no_radio() {
        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let router = Router::scripted(move |cmd| {
            log.lock().unwrap().push(cmd.to_string());
            if cmd.contains("/sys/class/ieee80211/") {
                return Ok((String::new(), 1)); // no radio on this device
            }
            if cmd.contains("ifdown tollgate") {
                panic!("must not touch br-tollgate when there is no radio: {cmd}");
            }
            Ok((String::new(), 0))
        });

        restart_services(&router, true).expect("a radio-less device is not a failure");

        let commands = seen.lock().unwrap().clone();
        assert!(
            commands.iter().any(|c| c.contains("/sys/class/ieee80211/")),
            "must probe for the wifi command before using it; saw {commands:#?}"
        );
        assert!(
            !commands.iter().any(|c| c.contains("wifi down")),
            "must not run wifi down when the command does not exist; saw {commands:#?}"
        );
    }

    /// The same call on a device that DOES have a radio must still fail when
    /// br-tollgate never gets a kernel-level address — that leaves every
    /// client pointed at a dead gateway.
    #[test]
    fn restart_services_still_fails_when_a_radio_exists_but_br_tollgate_never_comes_up() {
        let router = Router::scripted(|cmd| {
            if cmd.contains("/sys/class/ieee80211/") {
                return Ok(("phy0\n".to_string(), 0)); // a real radio is present
            }
            if cmd.contains("ifdown tollgate") {
                return Ok(("br-tollgate has no kernel-level IPv4 address".into(), 1));
            }
            Ok((String::new(), 0))
        });

        let err = restart_services(&router, true).expect_err("unclaimed br-tollgate must fail");
        assert!(
            err.to_string().contains("br-tollgate"),
            "error should name the interface, got: {err}"
        );
    }
}
