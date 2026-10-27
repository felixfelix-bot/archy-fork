use anyhow::{Context, Result};

use crate::opkg::PkgManager;
use crate::tollgate::TollGateConfig;
use crate::Router;

/// Install NoDogSplash and immediately stop it, before configuring anything.
///
/// The OpenWrt package's postinst auto-enables and starts nodogsplash on
/// install using its stock default config — critically, `gatewayinterface`
/// defaults to `br-lan`. On a fresh install that window is real: NoDogSplash
/// only manages IPv4 iptables, so anything plugged into `br-lan` (e.g. an
/// admin's own management box) silently loses IPv4 connectivity (DHCP still
/// listens, but the gate blocks the client until ndsctl authorizes its MAC)
/// until we get a chance to repoint it — a full network re-scan can take
/// long enough for that to matter. Stopping it right after install, before
/// `configure()` ever runs, closes that window as early as possible.
///
/// `tollgate-wrt` delegates all MAC authorization and gate open/close to
/// NoDogSplash via `ndsctl` — it has no firewall/netfilter code of its own
/// (confirmed: its binary has no `nft`/`ipset`/`iptables` calls at all).
/// Upstream's package therefore hard-depends on `+nodogsplash`, but neither
/// of our install paths (see `tollgate::install`) pull it in automatically.
pub fn install_and_stop(router: &Router, pkg_mgr: PkgManager) -> Result<()> {
    router
        .install_package(pkg_mgr, "nodogsplash")
        .context("install nodogsplash — required by tollgate-wrt for client gating")?;
    router.run_ok("/etc/init.d/nodogsplash stop || true")?;
    Ok(())
}

/// Point NoDogSplash's webroot at TollGate's own splash page instead of the
/// generic stock one NoDogSplash ships with.
///
/// Confirmed live: without this, NoDogSplash serves its own bundled
/// click-to-continue splash page — clicking "Continue" calls NDS's built-in
/// auth handler directly and authorizes the client with zero payment
/// involved. TollGate's actual payment UI (a QR/Cashu-token entry SPA) lives
/// at `/etc/tollgate/tollgate-captive-portal-site` — the .ipk's data payload
/// stages it there (see `packaging/files/tollgate-captive-portal-site/` in
/// the upstream repo), it's just never wired up as NoDogSplash's webroot.
///
/// Mirrors upstream's own `90-tollgate-captive-portal-symlink` uci-defaults
/// script exactly (symlink swap, not a `webroot` UCI override) — confirmed
/// live that setting `option webroot` directly instead causes NoDogSplash to
/// 500 on every request, for reasons not fully understood (worth filing
/// upstream, but the symlink approach is what's actually shipped/tested).
pub fn install_captive_portal_symlink(router: &Router) -> Result<()> {
    let (_, exists) = router.run("test -d /etc/tollgate/tollgate-captive-portal-site")?;
    if exists != 0 {
        anyhow::bail!(
            "/etc/tollgate/tollgate-captive-portal-site missing — expected to be staged \
             by the tollgate-wrt package install"
        );
    }

    router.run_ok(
        "if [ -L /etc/nodogsplash/htdocs ]; then \
             true; \
         else \
             if [ -d /etc/nodogsplash/htdocs ]; then \
                 mv /etc/nodogsplash/htdocs /etc/nodogsplash/htdocs.backup; \
             fi; \
             rm -rf /etc/nodogsplash/htdocs; \
             ln -sf /etc/tollgate/tollgate-captive-portal-site /etc/nodogsplash/htdocs; \
         fi",
    )?;
    Ok(())
}

/// Configure NoDogSplash to gate the dedicated `br-tollgate` bridge (see
/// `wifi::provision_network`), not `br-lan` — the paid SSID here lives on its
/// own isolated network/subnet rather than the canonical upstream layout
/// where it's bridged into `lan`.
///
/// Must run after `wifi::provision_ssid` has created `br-tollgate` — pointing
/// `gatewayinterface` at a bridge that doesn't exist yet is at best a no-op
/// and at worst leaves NoDogSplash in a confused state.
pub fn configure(router: &Router, cfg: &TollGateConfig) -> Result<()> {
    router.run_ok("touch /etc/config/nodogsplash")?;

    // The nodogsplash package's own uci-defaults populate an anonymous
    // `@nodogsplash[0]` section on first install, pointed at `br-lan` (its
    // stock default — see `install_and_stop`). NoDogSplash supports multiple
    // simultaneous gateway instances, one per config section, so leaving this
    // in place alongside our own `nodogsplash.main` doesn't get overridden by
    // it — it starts a *second* instance gating br-lan for real. Delete it;
    // `main` is the only instance this project manages.
    //
    // NOTE the ordering consequence this creates, which is the whole subject of
    // `assert_gateway_interface_is_paid_bridge`: once this section is gone,
    // `main` IS `@nodogsplash[0]`. Anything that later writes
    // `nodogsplash.@nodogsplash[0].gatewayinterface` therefore writes OUR
    // section, not a foreign one. The tollgate-wrt package does exactly that
    // (see the guard below), so the delete is only safe together with it.
    let _ = router.uci_delete("nodogsplash.@nodogsplash[0]");

    router.uci_set("nodogsplash.main", "nodogsplash")?;
    router.uci_set("nodogsplash.main.enabled", "1")?;
    router.uci_set("nodogsplash.main.gatewayinterface", PAID_BRIDGE)?;
    router.uci_set(
        "nodogsplash.main.gatewayname",
        &format!("{} Portal", cfg.ssid),
    )?;
    router.uci_set("nodogsplash.main.gatewaydomainname", "TollGate.lan")?;
    router.uci_set("nodogsplash.main.gatewayport", "2050")?;

    // Pre-auth "walled garden": traffic an unauthenticated client must still
    // reach before ndsctl authorizes their MAC. `uci_delete` + rebuild (rather
    // than only adding our own entries) is deliberate — the stock package
    // config ships a `users_to_router` default of its own (DNS, DHCP, plus
    // SSH/Telnet to the router), and `uci_set`/`add_list` on an existing
    // *named* section does not clear an inherited default list, so without
    // an explicit delete first, re-provisioning would silently keep
    // whatever was there before.
    //
    // DNS (53) and DHCP (67, udp) are carried over from that stock default —
    // without them a client can't even get an IP or resolve the portal
    // domain before authenticating (confirmed live: omitting udp/67 here
    // broke DHCP entirely for new clients on the archipelago SSID). 2121
    // (TollGate payment) and 2050 (NDS's own splash portal) are ours.
    // SSH/Telnet (22/23) are deliberately *not* carried over — the stock
    // default exposes router shell access to every unauthenticated device
    // on a public pay-as-you-go network, which is a bad default here.
    let _ = router.uci_delete("nodogsplash.main.users_to_router");
    router.uci_add_list("nodogsplash.main.users_to_router", "allow udp port 53")?;
    router.uci_add_list("nodogsplash.main.users_to_router", "allow tcp port 53")?;
    router.uci_add_list("nodogsplash.main.users_to_router", "allow udp port 67")?;
    router.uci_add_list("nodogsplash.main.users_to_router", "allow tcp port 2121")?;
    router.uci_add_list("nodogsplash.main.users_to_router", "allow tcp port 2050")?;

    // Post-auth (paid) clients get full access — matches the stock package
    // default (`list authenticated_users 'allow all'`), which our from-scratch
    // named section never carried over. Under this router's default-ACCEPT
    // FORWARD policy an empty list happens to behave the same, but that's an
    // accident of this specific setup, not something to depend on.
    let _ = router.uci_delete("nodogsplash.main.authenticated_users");
    router.uci_add_list("nodogsplash.main.authenticated_users", "allow all")?;

    router.uci_commit(Some("nodogsplash"))?;
    Ok(())
}

/// (Re)start the nodogsplash service so config changes and gate state take effect.
pub fn restart(router: &Router) -> Result<()> {
    router.run_ok("/etc/init.d/nodogsplash enable")?;
    router.run_ok("/etc/init.d/nodogsplash restart || /etc/init.d/nodogsplash start")?;
    Ok(())
}

/// The bridge the paid SSID lives on, and the only interface NoDogSplash may be
/// told to gate in this project.
pub const PAID_BRIDGE: &str = "br-tollgate";

/// The upstream first-boot script that rewrites `gatewayinterface`, and the
/// exact value it writes.
///
/// `99-tollgate-setup` is shipped by the `tollgate-wrt` package itself (it is
/// the module's own packaging tree, staged verbatim — `etc/uci-defaults/
/// 99-tollgate-setup`, line 1827 in the released v0.6.0 artifact). Its
/// `setup_nodogsplash` does `uci set
/// nodogsplash.@nodogsplash[0].gatewayinterface='br-lan'`.
const UPSTREAM_SETUP_SCRIPT: &str = "/etc/uci-defaults/99-tollgate-setup";
const UPSTREAM_GATEWAY_VALUE: &str = "br-lan";

/// Re-assert that NoDogSplash gates the paid bridge, and report whether it had
/// drifted.
///
/// What this can and cannot do, stated precisely, because the first version of
/// this comment overclaimed it:
///
/// `provision` installs the package (whose postinst runs `99-tollgate-setup`)
/// **before** it calls `nodogsplash::configure`. `configure` then deletes the
/// stock anonymous section, creates `main` (so `main` IS `@nodogsplash[0]`) and
/// writes `br-tollgate` to it. This function is called after that, so on the
/// normal path it reads back the value `configure` itself just wrote and finds
/// it correct — it does not, and cannot, observe the postinst's `br-lan`,
/// because the postinst ran two steps earlier. A guard placed where it would
/// have been needed is therefore not needed at all; this is a POST-CONDITION
/// on `configure`, not a repair of the install.
///
/// The package's write still matters, and is still why `PAID_BRIDGE` is pinned
/// in two places:
///
/// * On a **version-changing install or upgrade outside Archipelago** (a bare
///   `apk add`, a package-manager upgrade on a router nobody re-provisions),
///   `postinst` runs the FULL branch of `99-tollgate-setup` and writes
///   `br-lan`. Nothing re-asserts `br-tollgate` until the next provision, so
///   the value is perishable across upgrades. Measured on a live 25.12.5 guest
///   with the shipped v0.6.0 script, starting from a correctly provisioned
///   router:
///
///   ```text
///   $ uci get nodogsplash.@nodogsplash[0].gatewayinterface
///   br-tollgate
///   $ setup_nodogsplash          # the package's own function, verbatim
///   $ uci get nodogsplash.@nodogsplash[0].gatewayinterface
///   br-lan
///   ```
///
/// * It is branch-gated on `/etc/tollgate-setup-done`: a same-version reinstall
///   takes the VERIFY branch and leaves the value alone, which is why the
///   symptom looked intermittent rather than constant.
///
/// When it does drift the daemon renders `GatewayInterface br-lan`, reports
/// `Managed interface: br-lan`, and listens on the management address
/// `10.99.99.1:2050` instead of the paid `192.168.99.1:2050`. So a drifted
/// router gates its own management LAN — the operator's laptop is treated as an
/// unpaid customer. Measured: the lab guest refused SSH to the host until
/// nodogsplash was stopped.
///
/// Why keep it at all: `configure` could fail to persist (uncommitted config,
/// a competing writer, a future reorder of `provision`), and a provision that
/// returns Ok while the gateway is on the wrong bridge is exactly the silent
/// failure this card was filed against. This turns that into a boot-time error
/// or a logged repair.
///
/// It is a VERIFY-AND-REPAIR, not a rewrite: when the value is already correct
/// it issues no `uci set`, so it cannot paper over a different bug by silently
/// normalising state. It returns which value it found so the caller can log a
/// repair as the event it is.
pub fn assert_gateway_interface_is_paid_bridge(router: &Router) -> Result<GatewayInterfaceCheck> {
    let key = "nodogsplash.@nodogsplash[0].gatewayinterface";

    // Read through the same positional selector the package writes through, so
    // "what the package would clobber" and "what we verify" are the same key.
    // A router where provisioning never ran has no such section at all, which
    // is an absent value rather than an error.
    let (found, _code) = router.run(&format!("uci -q get {key}"))?;
    let found = found.trim().to_string();

    if found == PAID_BRIDGE {
        return Ok(GatewayInterfaceCheck::Correct);
    }

    if found.is_empty() {
        // No section, or no option. Nothing to repair onto: `configure` builds
        // the section from scratch, and inventing one here would create a
        // half-configured gateway. Say so instead of guessing.
        anyhow::bail!(
            "nodogsplash has no {key} — provisioning did not configure the gateway; \
             refusing to invent one (run a full provision)"
        );
    }

    router.uci_set(key, PAID_BRIDGE)?;
    router.uci_commit(Some("nodogsplash"))?;

    // A repaired UCI value is not a repaired daemon: nodogsplash only reads its
    // config at start-up, so the running instance keeps gating whatever it
    // bound when it started. Restart so the repaired value is the enforced one.
    restart(router)?;

    Ok(GatewayInterfaceCheck::Repaired(found))
}

/// What [`assert_gateway_interface_is_paid_bridge`] found.
#[derive(Debug, PartialEq, Eq)]
pub enum GatewayInterfaceCheck {
    /// Already gating the paid bridge; nothing was written.
    Correct,
    /// Gating the wrong interface; the carried value is what it was set to.
    Repaired(String),
}

/// A shell snippet that reports whether the package still ships the write this
/// project is defending against.
///
/// The guard above assumes one specific line in one file the package owns. If a
/// future `tollgate-wrt` fixes `setup_nodogsplash` upstream (or renames the
/// script), the assumption behind this project's repair becomes false and the
/// comment explaining it becomes a lie — the exact failure this card was filed
/// against, where prose outlived the mechanism.
///
/// Callers: `examples/live_driver.rs` runs this on a real router before trusting
/// the guard's rationale. It is deliberately not asserted in a unit test — a
/// unit test cannot see the package's filesystem, so a test over this string
/// would check our own formatting rather than the package.
pub fn upstream_gateway_write_probe() -> String {
    format!(
        "grep -n \"gatewayinterface='{UPSTREAM_GATEWAY_VALUE}'\" {UPSTREAM_SETUP_SCRIPT} 2>/dev/null"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tollgate::TollGateConfig;
    use std::sync::{Arc, Mutex};

    /// The repair exists because the package writes `br-lan` at the SAME
    /// positional selector `configure` uses for `main`. If someone changes the
    /// guard to a key that is not the one the package writes, the guard can
    /// pass while the daemon still gates the wrong bridge — so assert the key
    /// the guard actually *reads*, on the wire.
    #[test]
    fn the_guard_reads_the_key_the_package_actually_writes() {
        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let router = Router::scripted(move |cmd| {
            log.lock().unwrap().push(cmd.to_string());
            if cmd.contains("uci -q get") {
                return Ok((format!("{PAID_BRIDGE}\n"), 0));
            }
            Ok((String::new(), 0))
        });

        assert_gateway_interface_is_paid_bridge(&router).unwrap();

        let commands = seen.lock().unwrap().clone();
        assert!(
            commands
                .iter()
                .any(|c| c.contains("uci -q get nodogsplash.@nodogsplash[0].gatewayinterface")),
            "guard must read the positional key the package writes \
             (nodogsplash.@nodogsplash[0].gatewayinterface), saw {commands:#?}"
        );
    }

    /// A correct router must not be rewritten. `uci set` on an already-correct
    /// value is harmless in isolation but makes the guard's return value a lie
    /// (it would report a repair that did not happen), and it would mask a
    /// genuine second-config bug by normalising it away.
    #[test]
    fn a_correct_gateway_interface_is_not_rewritten() {
        let router = Router::scripted(|cmd| {
            if cmd.contains("uci -q get nodogsplash") {
                return Ok((format!("{PAID_BRIDGE}\n"), 0));
            }
            if cmd.contains("uci set") {
                panic!("must not rewrite an already-correct value: {cmd}");
            }
            if cmd.contains("/etc/init.d/nodogsplash restart") {
                panic!("must not restart a daemon whose config did not change: {cmd}");
            }
            Ok((String::new(), 0))
        });

        let outcome = assert_gateway_interface_is_paid_bridge(&router).unwrap();
        assert_eq!(outcome, GatewayInterfaceCheck::Correct);
    }

    /// The measured drift: `br-lan` must be repaired to `br-tollgate`, AND the
    /// daemon restarted — the UCI value alone is not enforcement.
    #[test]
    fn a_drifted_gateway_interface_is_repaired_and_the_daemon_restarted() {
        let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let router = Router::scripted(move |cmd| {
            log.lock().unwrap().push(cmd.to_string());
            if cmd.contains("uci -q get nodogsplash") {
                return Ok(("br-lan\n".into(), 0));
            }
            Ok((String::new(), 0))
        });

        let outcome = assert_gateway_interface_is_paid_bridge(&router).unwrap();
        assert_eq!(outcome, GatewayInterfaceCheck::Repaired("br-lan".into()));

        let commands = seen.lock().unwrap().clone();
        assert!(
            commands.iter().any(|c| c
                .contains("uci set nodogsplash.@nodogsplash[0].gatewayinterface='br-tollgate'")),
            "must write the paid bridge, saw {commands:#?}"
        );
        assert!(
            commands
                .iter()
                .any(|c| c.contains("uci commit nodogsplash")),
            "must commit, otherwise the write is lost on reload: saw {commands:#?}"
        );
        assert!(
            commands
                .iter()
                .any(|c| c.contains("/etc/init.d/nodogsplash restart")),
            "must restart nodogsplash or the repaired value is not enforced: saw {commands:#?}"
        );
    }

    /// An absent option is not a drifted one. Inventing a section here would
    /// create a gateway with none of `configure`'s other settings (portal
    /// allow-list, post-auth policy) and look healthy.
    #[test]
    fn an_absent_gateway_interface_fails_instead_of_inventing_a_section() {
        let router = Router::scripted(|cmd| {
            if cmd.contains("uci -q get nodogsplash") {
                return Ok((String::new(), 1));
            }
            if cmd.contains("uci set") {
                panic!("must not invent a nodogsplash section: {cmd}");
            }
            Ok((String::new(), 0))
        });

        let err = assert_gateway_interface_is_paid_bridge(&router)
            .expect_err("an unconfigured gateway must not be silently created");
        assert!(
            err.to_string().contains("refusing to invent"),
            "error should say it refused, got: {err}"
        );
    }

    /// The guard is a POST-CONDITION on `configure`, and that is only true
    /// because `configure` runs after the install. Pin the pairing that makes
    /// it true, behaviourally: replay `configure` against a router whose
    /// postinst has already written `br-lan`, and assert the value the guard
    /// then reads is `br-tollgate` — i.e. `configure`, not the guard, is what
    /// repairs the install.
    ///
    /// If someone reorders `provision` so the install lands after `configure`,
    /// this pairing breaks and the guard becomes load-bearing again — which is
    /// fine, but the prose must change with it. Asserting the current shape
    /// keeps the two from drifting apart silently.
    #[test]
    fn configure_is_what_repairs_the_postinst_write_not_the_guard() {
        // Stateful fake: models the one section and its gatewayinterface.
        let value: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(Some("br-lan".into())));
        let v = value.clone();
        let router = Router::scripted(move |cmd| {
            let mut slot = v.lock().unwrap();
            if cmd.contains("uci -q get nodogsplash.@nodogsplash[0].gatewayinterface") {
                return match slot.as_ref() {
                    Some(s) => Ok((format!("{s}\n"), 0)),
                    None => Ok((String::new(), 1)),
                };
            }
            if cmd.contains("uci delete nodogsplash.@nodogsplash[0]") {
                *slot = None;
                return Ok((String::new(), 0));
            }
            if cmd.contains("uci set nodogsplash.main=nodogsplash") {
                *slot = Some(String::new());
                return Ok((String::new(), 0));
            }
            if let Some(rest) = cmd
                .strip_prefix("uci set nodogsplash.main.gatewayinterface=")
                .or_else(|| {
                    cmd.strip_prefix("uci set nodogsplash.@nodogsplash[0].gatewayinterface=")
                })
            {
                *slot = Some(rest.trim_matches('\'').to_string());
                return Ok((String::new(), 0));
            }
            if cmd.contains("uci set nodogsplash.main.") && slot.is_none() {
                *slot = Some(String::new());
            }
            Ok((String::new(), 0))
        });

        // The postinst has already run: @[0] reads br-lan (set above).
        // configure() is what provision calls after the install.
        configure(
            &router,
            &TollGateConfig {
                mint_url: "http://127.0.0.1:3338".into(),
                ..Default::default()
            },
        )
        .expect("configure");

        // ...and by the time the guard runs, the install's write is already gone.
        let outcome = assert_gateway_interface_is_paid_bridge(&router).expect("guard");
        assert_eq!(
            outcome,
            GatewayInterfaceCheck::Correct,
            "configure must have already repaired the postinst's br-lan write; \
             if this is Repaired, provision's ordering changed and the guard's \
             doc comment is now wrong"
        );
        assert_eq!(
            value.lock().unwrap().as_deref(),
            Some(PAID_BRIDGE),
            "the enforced bridge must be the paid bridge after configure"
        );
    }

    /// The other half of the same claim: when the value IS wrong by the time
    /// the guard runs, the guard fixes it. This is the case a bare `apk add`
    /// after provisioning leaves behind, and what `live_driver assert-guard`
    /// exercises on a real router.
    #[test]
    fn the_guard_repairs_a_value_that_is_wrong_when_it_runs() {
        let value: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(Some("br-lan".into())));
        let v = value.clone();
        let router = Router::scripted(move |cmd| {
            let mut slot = v.lock().unwrap();
            if cmd.contains("uci -q get nodogsplash.@nodogsplash[0].gatewayinterface") {
                return match slot.as_ref() {
                    Some(s) => Ok((format!("{s}\n"), 0)),
                    None => Ok((String::new(), 1)),
                };
            }
            if let Some(rest) = cmd
                .strip_prefix("uci set nodogsplash.@nodogsplash[0].gatewayinterface=")
                .or_else(|| cmd.strip_prefix("uci set nodogsplash.main.gatewayinterface="))
            {
                *slot = Some(rest.trim_matches('\'').to_string());
            }
            Ok((String::new(), 0))
        });

        let outcome = assert_gateway_interface_is_paid_bridge(&router).expect("guard");
        assert_eq!(outcome, GatewayInterfaceCheck::Repaired("br-lan".into()));
        assert_eq!(value.lock().unwrap().as_deref(), Some(PAID_BRIDGE));
    }
}
