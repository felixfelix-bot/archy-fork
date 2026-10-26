use anyhow::Result;
use tracing::info;

use crate::Router;

/// Which package manager is available on this router.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PkgManager {
    /// Traditional opkg (OpenWrt ≤24.x).
    Opkg,
    /// OpenWrt 25.x+ — apk is the native manager, opkg is not in repos.
    ApkNative,
}

impl Router {
    /// Detect which package manager is available.
    ///
    /// Looks up `opkg`/`apk` via the router's `$PATH` (`command -v`) rather
    /// than a hardcoded `/usr/bin/<tool>` — official OpenWrt images don't all
    /// symlink `/bin` into `/usr/bin` (e.g. the `glinet_gl-mt3000` 24.10.2
    /// build keeps them as separate real directories with `opkg` living in
    /// `/bin`), so a fixed absolute path silently misses a perfectly normal
    /// install and reports "no package management" (archy-x250-pa3, 2026-09-05).
    ///
    /// - If `opkg` is on PATH → `PkgManager::Opkg` (nothing to do).
    /// - If `apk` is on PATH → run `apk update` (switching repos to HTTP
    ///   first to work around missing CA bundle on fresh images), then try
    ///   `apk add opkg`.  If opkg is in the repos → `Opkg`.  If not (OpenWrt
    ///   25.x) → `ApkNative`.
    /// - Neither found → error.
    ///
    /// Which package manager is present — WITHOUT changing the router.
    /// [`opkg_check`](Self::opkg_check) is a provisioning step, not a query: it
    /// rewrites `/etc/apk/repositories` to plaintext HTTP, runs `apk update`, and
    /// `apk add opkg`. Calling it from a read path (the dashboard's status RPC)
    /// therefore downgraded a router's package transport and installed software
    /// on every poll, and made an already-slow SSH round-trip slower.
    ///
    /// This probe only asks what is on `$PATH`. It never writes, and a failure
    /// returns an error rather than guessing — a guessed manager makes the next
    /// version probe report `Absent` for a router that is fine, which reads as
    /// "not installed" and is exactly the kind of silent wrong answer this
    /// module exists to prevent.
    pub fn pkg_manager(&self) -> Result<PkgManager> {
        let (_, opkg) = self.run("command -v opkg >/dev/null 2>&1")?;
        if opkg == 0 {
            return Ok(PkgManager::Opkg);
        }
        let (_, apk) = self.run("command -v apk >/dev/null 2>&1")?;
        if apk == 0 {
            return Ok(PkgManager::ApkNative);
        }
        anyhow::bail!(
            "Neither opkg nor apk found on this router's $PATH — its firmware may not \
             support package management (TollGate requires a standard OpenWrt build)"
        )
    }

    /// Which package manager this router should use, provisioning `opkg` if the
    /// image is apk-native and its repos carry one.
    ///
    /// This MUTATES the router (see the doc comment above). Call it from
    /// provisioning only.
    pub fn opkg_check(&self) -> Result<PkgManager> {
        let (_, code) = self.run("command -v opkg >/dev/null 2>&1")?;
        if code == 0 {
            return Ok(PkgManager::Opkg);
        }

        let (_, apk_code) = self.run("command -v apk >/dev/null 2>&1")?;
        if apk_code == 0 {
            info!("[{}] opkg not found — using apk (OpenWrt 25.x+)", self.host);
            // Fresh images ship without a CA bundle; switch repos to HTTP so
            // apk's wget can reach the package index without TLS verification.
            self.run_ok("sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true")?;
            let (update_out, update_code) = self.run("apk update 2>&1")?;
            if update_code != 0 {
                anyhow::bail!(
                    "apk update failed (exit {}) — router may have no internet access. \
                     Ensure WAN/internet is working on the router before provisioning.\n{}",
                    update_code,
                    update_out.trim()
                );
            }
            // Try to install opkg (only available on some 25.x builds).
            let (add_out, add_code) = self.run("apk add opkg 2>&1")?;
            if add_code == 0 {
                return Ok(PkgManager::Opkg);
            }
            if add_out.contains("no such package") || add_out.contains("unable to select") {
                info!(
                    "[{}] opkg not in apk repos — staying in apk-native mode",
                    self.host
                );
                return Ok(PkgManager::ApkNative);
            }
            anyhow::bail!(
                "apk add opkg failed (exit {}): {}",
                add_code,
                add_out.trim()
            );
        }

        anyhow::bail!(
            "Neither opkg nor apk found on this router's $PATH — its firmware may not \
             support package management (TollGate requires a standard OpenWrt build)"
        );
    }

    /// `opkg update` — refresh package lists.
    pub fn opkg_update(&self) -> Result<()> {
        info!("[{}] opkg update", self.host);
        self.run_ok("opkg update")?;
        Ok(())
    }

    /// Install a package, skipping if already installed.
    pub fn opkg_install(&self, package: &str) -> Result<()> {
        // Check if already installed to avoid unnecessary network traffic.
        let (_, code) = self.run(&format!("opkg list-installed | grep -q '^{} '", package))?;
        if code == 0 {
            info!("[{}] {} already installed", self.host, package);
            return Ok(());
        }

        info!("[{}] opkg install {}", self.host, package);
        self.run_ok(&format!("opkg install {}", package))?;
        Ok(())
    }

    /// Remove a package.
    pub fn opkg_remove(&self, package: &str) -> Result<()> {
        info!("[{}] opkg remove {}", self.host, package);
        self.run_ok(&format!("opkg remove {}", package))?;
        Ok(())
    }

    /// Install a standard OpenWrt package via whichever manager is active.
    ///
    /// Unlike `tollgate-module-basic-go` itself (which falls back to manual
    /// `.ipk` extraction and therefore skips dependency resolution — see
    /// `tollgate::install`), packages like `nodogsplash` are in every
    /// upstream OpenWrt feed, so a plain `apk add` / `opkg install` works
    /// even in `ApkNative` mode.
    pub fn install_package(&self, pkg_mgr: PkgManager, package: &str) -> Result<()> {
        match pkg_mgr {
            PkgManager::Opkg => self.opkg_install(package),
            PkgManager::ApkNative => self.apk_install(package),
        }
    }

    /// `apk add <package>`, skipping if already installed.
    pub fn apk_install(&self, package: &str) -> Result<()> {
        let (_, code) = self.run(&format!("apk info -e {} >/dev/null 2>&1", package))?;
        if code == 0 {
            info!("[{}] {} already installed", self.host, package);
            return Ok(());
        }

        info!("[{}] apk add {}", self.host, package);
        self.run_ok(&format!("apk add {}", package))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    // These assert the SHAPE of the two probes, because the defect they guard
    // against is a shape defect: a read path must not mutate the router, and a
    // version-aware caller must not use the name-only install shortcut. Both are
    // invisible to a green functional suite — the router still answers, it just
    // answers after being changed.

    /// `opkg_check` MUST stay obviously mutating, so nobody wires it into a read
    /// path again. It rewrites the repository URLs and installs a package.
    #[test]
    fn opkg_check_is_a_mutating_provisioning_step() {
        let src = include_str!("opkg.rs");
        let body = src
            .split("pub fn opkg_check")
            .nth(1)
            .expect("opkg_check exists");
        let body = &body[..body.find("\n    /// `opkg update`").unwrap_or(body.len())];
        assert!(
            body.contains("sed -i"),
            "opkg_check must not lose its repository rewrite without also \
             ceasing to be documented as mutating"
        );
        assert!(
            body.contains("apk add opkg"),
            "opkg_check installs opkg; if that is removed, the read/write split \
             should be reconsidered rather than silently widened"
        );
    }

    /// The non-mutating probe must contain only `command -v` lookups.
    #[test]
    fn the_read_path_probe_never_writes() {
        let src = include_str!("opkg.rs");
        let body = src
            .split("pub fn pkg_manager")
            .nth(1)
            .expect("pkg_manager exists");
        let body = &body[..body
            .find("\n    /// Which package manager")
            .unwrap_or(body.len())];
        for forbidden in ["sed -i", "apk add", "apk update", "run_ok("] {
            assert!(
                !body.contains(forbidden),
                "pkg_manager must never mutate the router, but it contains {forbidden:?}"
            );
        }
        assert!(body.contains("command -v opkg"));
        assert!(body.contains("command -v apk"));
    }
}
