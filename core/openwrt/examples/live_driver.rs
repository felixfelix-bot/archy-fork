//! Run the REAL provisioning code against a live router.
//!
//! This exists because the card is about what the product does to a router, not
//! about what a shell script can imitate. The sequence under test is
//! `tollgate::provision` — the same function the Archipelago RPC calls — driven
//! against the lab guest over the same SSH transport it uses in production.
//!
//! Usage:
//!   driver provision --host 10.99.99.1 --ssid archipelago
//!   driver probe
//!   driver assert-guard
//!   driver reinstall-package          (re-runs the install step only)

use archipelago_openwrt::tollgate::{self, TollGateConfig};
use archipelago_openwrt::Router;

fn connect(host: &str) -> anyhow::Result<Router> {
    // No default: a shipped example must not carry a working credential for a
    // lab router. Fail with an instruction instead of guessing.
    let pw = std::env::var("ARCHY_LAB_ROOT_PASSWORD").map_err(|_| {
        anyhow::anyhow!(
            "set ARCHY_LAB_ROOT_PASSWORD to the router's root password \
             (never commit it or pass it on a command line others can read)"
        )
    })?;
    Router::connect_password(host, 22, "root", &pw)
}

/// Everything the card asks to be shown, read back from the router itself.
fn probe(router: &Router, label: &str) -> anyhow::Result<()> {
    let (uci, _) = router.run("uci -q get nodogsplash.@nodogsplash[0].gatewayinterface")?;
    let (nds, _) = router.run("ndsctl status 2>&1 | grep -i 'Managed interface'")?;
    let (literal, lrc) = router.run("ndsctl status 2>&1 | grep -i gatewayinterface")?;
    let (bridge, _) = router.run("ip -4 addr show br-tollgate 2>&1 | grep inet")?;
    let (listen, _) = router.run("ndsctl status 2>&1 | grep -i 'Server listening'")?;
    let (rendered, _) =
        router.run("grep -i '^GatewayInterface' /tmp/etc/nodogsplash_main.conf 2>&1")?;
    let (sections, _) = router.run("uci show nodogsplash 2>&1 | grep -c nodogsplash")?;
    let (running, _) = router.run("pgrep -f nodogsplash >/dev/null && echo yes || echo no")?;

    println!("===== {label} =====");
    println!("$ uci get nodogsplash.@nodogsplash[0].gatewayinterface");
    println!("{}", uci.trim());
    println!("$ ndsctl status | grep -i 'Managed interface'");
    println!("{}", nds.trim());
    println!("$ ndsctl status | grep -i gatewayinterface   (card's literal form; rc={lrc})");
    println!(
        "{}",
        if literal.trim().is_empty() {
            "(no output)"
        } else {
            literal.trim()
        }
    );
    println!("$ grep -i '^GatewayInterface' /tmp/etc/nodogsplash_main.conf");
    println!("{}", rendered.trim());
    println!("$ ndsctl status | grep -i 'Server listening'");
    println!("{}", listen.trim());
    println!("$ ip -4 addr show br-tollgate | grep inet");
    println!("{}", bridge.trim());
    println!("daemon running: {}", running.trim());
    println!("nodogsplash uci lines: {}", sections.trim());

    // The guard exists because of one specific line in a file the package owns.
    // Print whether that line is still there, so a reader of this output can
    // tell a working guard from one defending against a bug that was fixed
    // upstream — the failure mode where the comment outlives the mechanism.
    println!(
        "$ {}",
        tollgate::nodogsplash::upstream_gateway_write_probe()
    );
    let (upstream, urc) = router.run(&tollgate::nodogsplash::upstream_gateway_write_probe())?;
    if urc != 0 || upstream.trim().is_empty() {
        println!(
            "(no matching write found, rc={urc}) — the package may have fixed \
             setup_nodogsplash; re-check whether this guard is still needed"
        );
    } else {
        println!("{}", upstream.trim());
    }
    println!();
    Ok(())
}

fn main() -> anyhow::Result<()> {
    // No tracing subscriber: the crate emits `tracing` events, but pulling in a
    // subscriber just to print them would add a dev-dependency to the product
    // for a harness's benefit. The evidence below is read back from the router
    // itself, which is what the card asks for anyway.

    let mut args = std::env::args().skip(1);
    let what = args.next().unwrap_or_else(|| "probe".into());
    let host = std::env::var("ARCHY_ROUTER_HOST").unwrap_or_else(|_| "10.99.99.1".into());

    let router = connect(&host)?;
    match what.as_str() {
        "probe" => probe(&router, "PROBE (as found)"),
        "assert-guard" => {
            let outcome = tollgate::nodogsplash::assert_gateway_interface_is_paid_bridge(&router)?;
            println!("guard outcome: {outcome:?}");
            probe(&router, "PROBE (after guard)")?;
            Ok(())
        }
        "provision" => {
            let ssid = std::env::var("ARCHY_SSID").unwrap_or_else(|_| "archipelago".into());
            let mint =
                std::env::var("ARCHY_MINT_URL").unwrap_or_else(|_| "http://10.99.99.2:3338".into());
            let cfg = TollGateConfig {
                ssid,
                mint_url: mint,
                ..Default::default()
            };
            probe(&router, "BEFORE provision")?;
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(tollgate::provision(&router, &cfg))?;
            probe(&router, "AFTER provision")
        }
        "reinstall-package" => {
            // Re-run ONLY the package install, which is the step whose postinst
            // runs 99-tollgate-setup. This is evidence item 4: what the install
            // does to the gateway interface when nothing re-asserts it.
            //
            // Expected, measured on a live 25.12.5 guest with the shipped
            // v0.6.0 package:
            //   * same version  -> apk treats it as installed, runs no postinst,
            //                      the value is unchanged.
            //   * version change -> FULL branch runs and the value goes back to
            //                      br-lan. Archipelago's `provision` is what
            //                      re-pins it, so a bare install followed by no
            //                      provision leaves a drifted router.
            // Run `assert-guard` afterwards to watch the repair, or `provision`
            // to watch the whole sequence converge.
            let pkg_mgr = router.opkg_check()?;
            probe(&router, "BEFORE reinstall")?;
            match pkg_mgr {
                archipelago_openwrt::opkg::PkgManager::Opkg => {
                    tollgate::install_tollgate(&router)?;
                }
                archipelago_openwrt::opkg::PkgManager::ApkNative => {
                    tollgate::install::install_tollgate_apk_native(&router)?;
                }
            }
            probe(&router, "AFTER reinstall (no provision)")
        }
        other => anyhow::bail!(
            "unknown command {other:?}; try probe|assert-guard|provision|reinstall-package"
        ),
    }
}
