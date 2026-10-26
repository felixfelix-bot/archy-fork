use anyhow::{Context, Result};
use tracing::info;

use crate::opkg::PkgManager;
use crate::tollgate::assets::{asset_url, AssetShape, PackageTarget, FEED_REPO};
use crate::tollgate::verify::{manifest_url, verify_download, MIN_PACKAGE_BYTES, SHA256SUMS_NAME};
use crate::tollgate::version::{
    decide_install, package_version_from_pin, parse_installed, Installed, TOLLGATE_PACKAGE,
    TOLLGATE_SERVICE_BIN,
};
use crate::Router;

/// Pinned TollGate release.
///
/// **This is the feed release tag, not a tag on the reference-implementation
/// repository.** Up to and including v0.5.0 the packages were attached to a
/// release on `OpenTollGate/tollgate-module-basic-go`. From v0.6.0 they are
/// built and signed by the OpenWrt packages feed, and the same tag on the old
/// repository carries **zero assets** — so a bump that keeps the old
/// repository 404s on every architecture while pointing at a release tag that
/// genuinely exists. See [`crate::tollgate::assets`] for the full account.
///
/// Bump history:
/// * v0.2.0 (Oct 2025) → v0.5.0, 2026-09-05 — nine releases behind; v0.5.0
///   carried the Cashu-mint crash-loop fix and the CBOR-capable portal build
///   that could decode `cashuB` (NUT-00 V4) tokens.
/// * v0.5.0 → v0.6.0 — packages moved to the feed; asset names became
///   target-qualified and the filename version dropped its leading `v`.
///
/// Rolling this constant back to `"v0.5.0"` restores the previous download
/// path, provided the URL is built with [`AssetShape::LegacyArchOnly`] against
/// [`LEGACY_REPO`] — which is why the shape is chosen from the same place the
/// version is, rather than hardcoded at each call site.
pub const TOLLGATE_VERSION: &str = "v0.6.0";

/// The asset-name scheme that matches [`TOLLGATE_VERSION`].
///
/// Kept adjacent to the version on purpose: the two changed together, and
/// separating them is how a bump produces a URL that is well-formed and wrong.
const TOLLGATE_SHAPE: AssetShape = AssetShape::FeedTargetQualified;

/// The repository that publishes the assets matching [`TOLLGATE_VERSION`].
const TOLLGATE_REPO: &str = FEED_REPO;

/// Direct-download URL for the `.ipk` (ar-archive) format.
///
/// Used when the package is not in any configured feed. Requires the router's
/// OpenWrt target as well as its architecture — see
/// [`PackageTarget`](crate::tollgate::assets::PackageTarget).
fn ipk_url(target: &PackageTarget) -> Option<String> {
    if !target.is_complete() {
        return None;
    }
    Some(asset_url(
        TOLLGATE_REPO,
        TOLLGATE_VERSION,
        TOLLGATE_SHAPE,
        &target.arch,
        &target.target,
        "ipk",
    ))
}

/// Direct-download URL for the native Alpine-style `.apk` format.
///
/// This is the only format the apk-native path installs: `apk add` records the
/// package in its own database, so the version the router reports is real. An
/// `.ipk` unpacked by hand would leave no such record and mask an upgrade.
///
/// The v0.5.0-era code published `.apk` for only two architectures, which made
/// every other apk-native router fall through to the manual path. From v0.6.0
/// both formats are published for all eight `(arch, target)` pairs, so the
/// allow-list is gone — an unsupported pair now fails on the fetch rather than
/// being silently excluded.
fn apk_url(target: &PackageTarget) -> Option<String> {
    if !target.is_complete() {
        return None;
    }
    Some(asset_url(
        TOLLGATE_REPO,
        TOLLGATE_VERSION,
        TOLLGATE_SHAPE,
        &target.arch,
        &target.target,
        "apk",
    ))
}

/// Install `tollgate-wrt` via opkg (OpenWrt ≤24.x).
///
/// The asset is always the **exact pinned release**, downloaded and verified
/// against the release's `SHA256SUMS` and then installed by opkg from the local
/// file. Two earlier shapes of this function were wrong in ways that a green
/// test suite could not see:
///
/// * it asked `opkg install tollgate-wrt` (no version) and returned `Ok(())` on
///   success. On a router whose configured feed carried an older build, opkg
///   reports success and the pin silently does nothing;
/// * when that failed it fell back to a manual `ar`/`tar` extraction, which
///   leaves **no package-manager record** — so the next read still sees the old
///   version in the database while the new files are on disk, and an upgrade
///   can be masked indefinitely.
///
/// So: a local-file `opkg install` of the verified asset, then a read-back of
/// the version opkg now reports. Caller is responsible for running `opkg_update`
/// first.
pub fn install_tollgate(router: &Router) -> Result<()> {
    info!("[{}] Installing {}", router.host, TOLLGATE_PACKAGE);

    // The version decision comes FIRST, and it is the same decision the apk path
    // makes. It did not use to be here at all, and the omission was invisible in
    // a specific and dangerous way.
    //
    // `router.opkg_install()` is not version-aware: it greps
    // `opkg list-installed` for the package name and returns Ok(()) if it is
    // present, at ANY version. While the constant was the repository name
    // (`tollgate-module-basic-go`) that grep could never match, so control fell
    // through to a real install and the missing version check did not matter.
    // Renaming the constant to the real package name — required for the apk
    // guard — made the grep match again, which turned this path into the very
    // silent no-op this change exists to remove, on OpenWrt ≤24.x.
    //
    // So the guard is explicit here, not delegated to opkg_install.
    let installed = installed_tollgate_version(router, PkgManager::Opkg);
    let desired = package_version_from_pin(TOLLGATE_VERSION)
        .context("derive the package version from the pinned release tag")?;
    let decision = decide_install(&installed, &desired, false, None);
    if !decision.should_install() {
        info!("[{}] {}", router.host, decision.reason());
        return Ok(());
    }
    info!("[{}] {}", router.host, decision.reason());

    // The architecture alone is not sufficient: from v0.6.0 the asset name is
    // target-qualified, because one CPU arch legitimately serves several OpenWrt
    // targets (`mips_24kc` is both `ath79-generic` and `ath79-nand`). Read both
    // halves.
    let target = read_package_target(router)?;
    let url = ipk_url(&target).ok_or_else(|| {
        anyhow::anyhow!(
            "Could not build a TollGate package URL for arch '{}' target '{}'. \
             Both values are required — an arch-only asset name no longer exists. \
             Check that /etc/openwrt_release defines DISTRIB_ARCH and DISTRIB_TARGET.",
            target.arch,
            target.target
        )
    })?;

    download_verified_asset(router, &url, "/tmp/tollgate.ipk")?;

    // Install the LOCAL, verified file. Asking opkg for the package by name
    // resolves against whatever feed the router has configured, which is how a
    // pin turns into "installed, wrong version, reported success".
    let (install_out, install_code) =
        router.run(&format!("{OPKG_INSTALL_LOCAL} /tmp/tollgate.ipk 2>&1"))?;
    router.run_ok("rm -f /tmp/tollgate.ipk")?;
    if install_code != 0 {
        anyhow::bail!(
            "opkg could not install the verified {desired} package: {}",
            install_out.trim()
        );
    }

    // Exit status is not evidence that the pin took effect; the version opkg
    // now reports is. See `assert_installed_version`.
    assert_installed_version(router, PkgManager::Opkg)?;
    Ok(())
}

/// The opkg install form used to install a verified local asset.
///
/// Every force flag is load-bearing for a *re-provision*, which is the common
/// case: the router already has some build and we want this exact file on it.
///
/// * `--force-downgrade` — opkg compares versions with `verrevcmp`. An rc
///   build sorts *above* its final release (`0.6.0_rc6` > `0.6.0`), so moving
///   from an rc to the release it precedes is a **downgrade** as far as opkg is
///   concerned and is refused with "Not downgrading" without this. Rolling the
///   pin back to an older release is the same case. The file is already
///   verified against the release manifest, so "older" is deliberate, not drift.
/// * `--force-reinstall` — opkg refuses an install whose version it believes is
///   already present, and the effect that matters here is **remove-then-
///   install**: the old files are removed before the new ones are unpacked.
///   That is what makes a re-provision over an earlier build actually rewrite
///   `/usr/bin/tollgate-wrt` instead of leaving stale content in place.
///
///   Note this does **not** cover a republished `PKG_RELEASE` (`0.6.0-r1`
///   present, `0.6.0-r2` wanted): [`normalise_version`] strips the trailing
///   `-r<digits>` counter, so that pair compares equal, `decide_install`
///   returns `Skip`, and no install command runs at all — the flag never gets
///   the chance to act. Changing a packaging counter is not a content change
///   worth reinstalling for; a genuinely new build has a new upstream version.
/// * `--force-overwrite` — reinstalling over an existing copy collides on
///   files opkg did not record as owned (a previous manual extraction, or a
///   config it now ships).
/// * `--force-depends` — the package's `DEPENDS` are installed by
///   `install_runtime_deps` *after* this install completes (see the ordering in
///   `tollgate::provision`), so at this point none of them are present and
///   opkg's dependency check would refuse the local file. The dependency graph
///   is resolved later by design, so the check has to be waived here.
const OPKG_INSTALL_LOCAL: &str =
    "opkg install --force-downgrade --force-reinstall --force-overwrite --force-depends";

/// Download `url` to `dest` on the router and verify it against the release
/// `SHA256SUMS` before anything installs it.
///
/// Fails closed: an unreachable asset, a tiny error page, or a digest mismatch
/// all abort. This is the only download-and-verify path both installers use, so
/// neither can quietly skip the check.
fn download_verified_asset(router: &Router, url: &str, dest: &str) -> Result<()> {
    let (dl_out, dl_code) = router.run(&format!(
        "wget --no-check-certificate -O {dest} '{url}' 2>&1"
    ))?;
    if dl_code != 0 {
        anyhow::bail!(
            "TollGate download failed ({}): {}",
            filename_from_url(url),
            dl_out.trim()
        );
    }
    verify_downloaded_package(router, dest, &filename_from_url(url))
}

/// Install the runtime dependencies the TollGate package declares.
///
/// The feed recipe declares `DEPENDS:=+nodogsplash +jq +ca-bundle`. None of
/// them arrive on their own here, because every install path in this module
/// deliberately skips dependency resolution:
///
/// * the `opkg` fast path only resolves deps against a real feed, and there is
///   usually no TollGate feed configured;
/// * the raw `.ipk` path extracts with `ar`/`tar` and runs the scriptlets
///   directly — no solver at all;
/// * the `.apk` path uses `--allow-untrusted` on a local file.
///
/// `nodogsplash` is installed separately (it is also stopped and reconfigured,
/// see `nodogsplash.rs`), so only the other two are handled here:
///
/// * **`jq`** — load-bearing. The package's first-boot scripts read `entry_ui` out of
///   `config.json` with it, and falls back to the `board` mapping when jq is
///   absent. A missing jq therefore silently changes which UI answers the
///   router's entry ports.
/// * **`ca-bundle`** — TLS trust. The gateway verifies Cashu mints and
///   Lightning over TLS using the system root pool only, so without it a
///   router cannot verify a payment.
///
/// Both are Architecture: all and present in both the 24.10 opkg and 25.12 apk
/// indexes, so a plain install resolves either way.
pub fn install_runtime_deps(router: &Router, pkg_mgr: PkgManager) -> Result<()> {
    for dep in ["jq", "ca-bundle"] {
        router
            .install_package(pkg_mgr, dep)
            .with_context(|| format!("install TollGate runtime dependency {dep}"))?;
    }
    Ok(())
}

/// Read the installed version back after an install and fail if it is not the
/// version we asked for.
///
/// The install commands' exit statuses are not evidence that the pin took
/// effect: `apk add` and `opkg install` both report success for a package that
/// resolved to a different version, and the whole defect this change removes
/// was a successful return from a path that installed nothing. The only
/// trustworthy verdict is the version the router now reports.
///
/// Deliberately an error rather than a warning: a caller that reaches the end
/// of a provisioning run believing it is on the pinned version, and is not,
/// will debug the payment path instead of the install.
pub fn assert_installed_version(router: &Router, pkg_mgr: PkgManager) -> Result<String> {
    let desired = package_version_from_pin(TOLLGATE_VERSION)
        .context("derive the package version from the pinned release tag")?;
    let installed = installed_tollgate_version(router, pkg_mgr);
    let have = match &installed {
        Installed::Version(v) => v.clone(),
        Installed::UnknownVersion => {
            anyhow::bail!(
                "installed {TOLLGATE_PACKAGE} but its version is unreadable — cannot confirm \
                 the {desired} pin took effect. Run `{TOLLGATE_SERVICE_BIN} version` on the \
                 router; a manual extraction leaves no package-manager record."
            )
        }
        Installed::Absent => {
            anyhow::bail!(
                "{TOLLGATE_PACKAGE} is not installed after the install step, although the \
                 installer reported success. Expected {desired}."
            )
        }
    };
    if !installed.satisfies(&desired) {
        anyhow::bail!(
            "installed {TOLLGATE_PACKAGE} {have}, but the pin is {desired} — the install \
             resolved to a different version. Check that the configured feed carries {desired} \
             rather than an older build."
        );
    }
    info!(
        "[{}] {TOLLGATE_PACKAGE} {have} is installed and matches the {desired} pin",
        router.host
    );
    Ok(have)
}

/// The basename of a URL's last path segment.
///
/// Used to name the file in the manifest lookup, so the digest is checked
/// against the name the release actually published.
fn filename_from_url(url: &str) -> String {
    url.rsplit('/').next().unwrap_or(url).to_string()
}

/// Fetch a release's `SHA256SUMS` and verify a downloaded file against it.
///
/// Runs on the ROUTER, not here: the file being checked lives there, and
/// hashing it locally would mean trusting a second transfer.
///
/// Fails closed. An unreachable manifest, an absent entry, or a digest
/// mismatch all abort the install — this is a money path, and a package whose
/// integrity cannot be checked is not installable.
pub fn verify_downloaded_package(router: &Router, path: &str, filename: &str) -> Result<()> {
    let (size_out, _) = router.run(&format!("wc -c < {path} 2>/dev/null"))?;
    let bytes: u64 = size_out.trim().parse().unwrap_or(0);

    // Cheap pre-check first: a tiny file is an error page, and saying so is
    // more useful than a digest mismatch on HTML.
    if bytes < MIN_PACKAGE_BYTES {
        anyhow::bail!("{}", verify_download(filename, bytes, "", "").message());
    }

    // The release manifest. `--no-check-certificate` for the same reason the
    // package download uses it: fresh OpenWrt images ship without a CA bundle,
    // which is one of the reasons we install ca-bundle below.
    let manifest_url = manifest_url(TOLLGATE_REPO, TOLLGATE_VERSION);
    let (_, dl_code) = router.run(&format!(
        "wget --no-check-certificate -q -O /tmp/tollgate-SHA256SUMS '{manifest_url}' 2>&1"
    ))?;
    if dl_code != 0 {
        anyhow::bail!(
            "could not fetch {SHA256SUMS_NAME} from {manifest_url} — refusing to install a \
             package whose integrity cannot be verified against the release manifest"
        );
    }
    let (manifest_text, _) = router.run("cat /tmp/tollgate-SHA256SUMS 2>/dev/null")?;

    let (digest_out, digest_code) = router.run(&format!(
        // The exit status of a pipeline is its LAST command's, so this used to
        // end in `| awk` and `digest_code` was always 0 — the "sha256sum is not
        // available" branch below was dead, and a router without it produced a
        // confusing MISMATCH with an empty actual digest instead. `test -x` first
        // makes the guard mean what it says.
        "command -v sha256sum >/dev/null 2>&1 || exit 3; sha256sum {path} 2>/dev/null | awk '{{print $1}}'"
    ))?;
    if digest_code != 0 {
        anyhow::bail!("sha256sum is not available on this router — cannot verify the download");
    }
    let actual = digest_out.trim();

    let outcome = verify_download(filename, bytes, actual, &manifest_text);
    router.run_ok("rm -f /tmp/tollgate-SHA256SUMS")?;

    if !outcome.may_install() {
        anyhow::bail!("{}", outcome.message());
    }
    info!("[{}] {}", router.host, outcome.message());
    Ok(())
}

/// Read `DISTRIB_ARCH` and `DISTRIB_TARGET` from the router.
///
/// Falls back to the package manager's own architecture report and then
/// `uname -m` for the architecture, because `DISTRIB_ARCH` is absent on some
/// builds. There is deliberately **no fallback for the target**: a guessed
/// target builds a well-formed URL for the wrong package, which is worse than
/// a loud failure.
pub fn read_package_target(router: &Router) -> Result<PackageTarget> {
    let (out, _) = router.run(PackageTarget::READ_CMD)?;
    let mut target = PackageTarget::parse(&out);

    if target.arch.is_empty() {
        // Each probe is tried separately so a failure falls through to the
        // next. Written as ONE `a || b | grep | awk || c` pipeline, the chain
        // looks like a fallback but is not: the pipeline's status is `awk`'s,
        // and `awk` exits 0 even on empty input, so everything after the first
        // `||` was unreachable.
        for probe in [
            "apk --print-arch 2>/dev/null",
            concat!(
                "opkg print-architecture 2>/dev/null ",
                "| grep -v '^arch all' | grep -v '^arch noarch' ",
                "| tail -1 | awk '{print $2}'"
            ),
            "uname -m 2>/dev/null",
        ] {
            let (probe_out, probe_code) = router.run(probe)?;
            let value = probe_out.trim();
            if probe_code == 0 && !value.is_empty() {
                // `uname -m` returns bare "mipsel"/"mips"; map to the 24kc
                // variant, which is the standard for home-router MIPS builds.
                target.arch = match value {
                    "mipsel" => "mipsel_24kc".to_string(),
                    "mips" => "mips_24kc".to_string(),
                    other => other.to_string(),
                };
                break;
            }
        }
    }

    Ok(target)
}

/// Install `tollgate-wrt` on an apk-native router (OpenWrt 25.x+).
///
/// Installs the **exact pinned release** as a native `.apk`: download, verify
/// against the release `SHA256SUMS`, `apk add` the local file, then read the
/// version back. The version decision runs first, so a router that is already on
/// the pin is left alone.
///
/// There used to be a fallback here that unpacked an `.ipk` with `ar`/`tar` when
/// the `.apk` was not published. It is gone, deliberately: that path wrote the
/// package's files but left **no package-manager record**, so the installed
/// version kept reading as the previous release and an upgrade could be masked
/// indefinitely while the binary on disk had changed. A missing `.apk` for a
/// target now fails loudly instead of producing a router that lies about its
/// version. Every `(arch, target)` pair the pin publishes has an `.apk`; verify
/// with the release's own asset list before assuming otherwise.
pub fn install_tollgate_apk_native(router: &Router) -> Result<()> {
    info!(
        "[{}] Installing {} (apk-native mode)",
        router.host, TOLLGATE_PACKAGE
    );

    // Already installed AT THE RIGHT VERSION?
    //
    // This guard used to be:
    //     apk list --installed | grep -q '^tollgate-module-basic-go' \
    //       || test -f /usr/bin/tollgate-wrt
    //
    // Both halves were wrong and the failure was silent:
    //   * the package is named `tollgate-wrt` (PKG_NAME), never
    //     `tollgate-module-basic-go` (that is the repository name), so the grep
    //     could never match;
    //   * the file-existence fallback then succeeded on any router that had
    //     ever been provisioned, so the function returned Ok(()) without
    //     installing.
    // Net effect: bumping the pinned version changed nothing on an
    // already-provisioned router, while the UI reported success.
    //
    // The replacement compares VERSIONS. A router on 0.5.0 with a 0.6.0 pin
    // must install; only a genuine version match skips.
    let installed = installed_tollgate_version(router, PkgManager::ApkNative);
    let desired = package_version_from_pin(TOLLGATE_VERSION)
        .context("derive the package version from the pinned release tag")?;
    let decision = decide_install(&installed, &desired, false, None);
    if !decision.should_install() {
        info!("[{}] {}", router.host, decision.reason());
        return Ok(());
    }
    info!("[{}] {}", router.host, decision.reason());

    // Both halves of the package identity, read from the router.
    let target = read_package_target(router)?;
    let url = apk_url(&target).ok_or_else(|| {
        anyhow::anyhow!(
            "Could not build a TollGate .apk URL for arch '{}' target '{}'. From v0.6.0 the \
             package name is target-qualified, so the architecture alone is not enough. \
             Check that /etc/openwrt_release defines DISTRIB_ARCH and DISTRIB_TARGET.",
            target.arch,
            target.target
        )
    })?;
    info!(
        "[{}] detected arch: {:?} target: {:?}",
        router.host, target.arch, target.target
    );

    download_verified_asset(router, &url, "/tmp/tollgate.apk")?;
    let (add_out, add_code) = router.run("apk add --allow-untrusted /tmp/tollgate.apk 2>&1")?;
    router.run_ok("rm -f /tmp/tollgate.apk")?;
    if add_code != 0 {
        anyhow::bail!("TollGate .apk install failed: {}", add_out.trim());
    }

    assert_installed_version(router, PkgManager::ApkNative)?;
    Ok(())
}

/// Read the currently-installed TollGate version from a router.
///
/// Two independent sources, because neither is sufficient alone:
///
/// * the package manager's installed list — authoritative, but empty on a
///   router whose TollGate was unpacked from a tarball by hand (the offline
///   `.tar.gz` assets ship for exactly that), since that leaves no record;
/// * the service binary's own `tollgate version` output — present after such an
///   extraction, but it reports the *module build*, which is not the same
///   string as the feed's package version.
///
/// Returning `Installed::UnknownVersion` rather than guessing is deliberate:
/// an unreadable version must provoke an install attempt. Assuming it matches
/// is the defect that made a version bump a silent no-op.
pub fn installed_tollgate_version(router: &Router, pkg_mgr: PkgManager) -> Installed {
    let listing = query_installed(router, pkg_mgr);
    if let Some(Installed::Version(v)) = &listing {
        return Installed::Version(v.clone());
    }

    match installed_from_binary(router) {
        // Nothing answered at all: the router is unreachable or its manager
        // listing failed. That is "unknown", never "absent".
        Installed::UnknownVersion if listing.is_none() => Installed::UnknownVersion,
        // A listing did answer and did not name the package, and no binary was
        // found either.
        Installed::Absent if matches!(listing, Some(Installed::Absent)) => Installed::Absent,
        other => other,
    }
}

/// Ask one package manager what it has installed.
///
/// `None` means **we could not ask** — the SSH command failed or the manager's
/// listing exited non-zero, which is what happens when the router runs the
/// other manager. That is deliberately distinct from `Some(Absent)`, which
/// means the listing ran and did not name the package. Collapsing the two is
/// how an unreachable or apk-native router used to be reported as "not
/// installed" by an opkg-only read.
fn query_installed(router: &Router, pkg_mgr: PkgManager) -> Option<Installed> {
    let (listing, code) = router.run(listing_cmd(pkg_mgr)).ok()?;
    if code != 0 {
        return None;
    }
    Some(parse_installed(&listing, TOLLGATE_PACKAGE))
}

/// The installed listing command for one package manager.
fn listing_cmd(pkg_mgr: PkgManager) -> &'static str {
    match pkg_mgr {
        PkgManager::Opkg => "opkg list-installed 2>/dev/null",
        PkgManager::ApkNative => "apk list --installed 2>/dev/null",
    }
}

/// Read the installed version without knowing which package manager this
/// router runs.
///
/// For callers that could not detect the manager — chiefly the read path,
/// where [`Router::pkg_manager`](crate::Router::pkg_manager) may legitimately
/// fail. Guessing one manager means running its listing on a router that may
/// not have it: the command fails, the output parses as `Absent`, and a
/// perfectly healthy router is reported as "not installed". That is the silent
/// wrong answer this module exists to prevent, so ask both listings and only
/// then fall back to the binary.
pub fn installed_tollgate_version_any(router: &Router) -> Installed {
    let mut any_listing_answered = false;
    for pkg_mgr in [PkgManager::Opkg, PkgManager::ApkNative] {
        if let Some(parsed) = query_installed(router, pkg_mgr) {
            any_listing_answered = true;
            if let Installed::Version(v) = parsed {
                return Installed::Version(v);
            }
        }
    }
    match installed_from_binary(router) {
        // Neither listing could be run and the binary probe failed too. We have
        // no evidence either way, so say so instead of claiming "not installed".
        Installed::Absent if !any_listing_answered => Installed::UnknownVersion,
        other => other,
    }
}

/// Last-resort read: the service binary's own `tollgate version` output.
///
/// Reached when no package record names the package — which is the normal
/// case after a manual `.ipk`/`.apk` extraction, since those leave no
/// package-manager record. Distinguishing "no binary" (`Absent`) from "binary
/// but unreadable version" (`UnknownVersion`) matters: the first is a clean
/// install, the second must provoke an upgrade attempt.
fn installed_from_binary(router: &Router) -> Installed {
    // A transport failure is not evidence that the binary is missing.
    let (_, bin_present) = match router.run(&format!("test -f {TOLLGATE_SERVICE_BIN} 2>/dev/null"))
    {
        Ok(result) => result,
        Err(_) => return Installed::UnknownVersion,
    };
    if bin_present != 0 {
        return Installed::Absent;
    }

    let (version_out, version_code) =
        match router.run(&format!("{TOLLGATE_SERVICE_BIN} version 2>/dev/null")) {
            Ok(result) => result,
            Err(_) => return Installed::UnknownVersion,
        };
    if version_code == 0 {
        // `tollgate version` prints lines like `version: 0.5.0-gabc1234`.
        if let Some(v) = extract_version_line(&version_out) {
            return Installed::Version(v);
        }
    }

    Installed::UnknownVersion
}

/// Pull the version out of `tollgate version` output.
///
/// Kept separate and pure so it is unit-tested: the binary reports the
/// *module* build (`0.5.0-gabc1234`), not the feed's package version, so the
/// parsing has to tolerate a git-suffix and a `version:` label.
pub fn extract_version_line(output: &str) -> Option<String> {
    for line in output.lines() {
        let line = line.trim();
        let value = match line.split_once(':') {
            Some((label, rest)) if label.trim().eq_ignore_ascii_case("version") => rest.trim(),
            _ => continue,
        };
        // `0.5.0-gabc1234` -> `0.5.0`
        let without_git = value
            .split_once("-g")
            .map(|(head, _)| head)
            .unwrap_or(value);
        if !without_git.is_empty() {
            return Some(without_git.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Script only the SSH boundary: exercise the real installer and verifier.
    fn install_fixture(
        manager: PkgManager,
        after: &'static str,
        bad_digest: bool,
    ) -> (Router, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let commands = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = commands.clone();
        let installed = std::sync::atomic::AtomicBool::new(false);
        let router = Router::scripted(move |cmd| {
            seen.lock().unwrap().push(cmd.to_owned());
            let ext = if matches!(manager, PkgManager::Opkg) {
                "ipk"
            } else {
                "apk"
            };
            let digest = "a".repeat(64);
            if cmd == listing_cmd(manager) {
                let version = if installed.load(std::sync::atomic::Ordering::SeqCst) {
                    after
                } else {
                    "0.5.0-r1"
                };
                return Ok((
                    if matches!(manager, PkgManager::Opkg) {
                        format!("tollgate-wrt - {version}\n")
                    } else {
                        format!(
                            "tollgate-wrt-{version} x86_64 {{tollgate-wrt}} (MIT) [installed]\n"
                        )
                    },
                    0,
                ));
            }
            if cmd == PackageTarget::READ_CMD {
                return Ok(("arch=x86_64\ntarget=x86-64\n".into(), 0));
            }
            if cmd.starts_with("wc -c") {
                return Ok(("100000".into(), 0));
            }
            if cmd == "cat /tmp/tollgate-SHA256SUMS 2>/dev/null" {
                return Ok((
                    format!("{digest}  tollgate-wrt_0.6.0_x86_64-x86-64.{ext}\n"),
                    0,
                ));
            }
            if cmd.starts_with("command -v sha256sum") {
                return Ok((if bad_digest { "b".repeat(64) } else { digest }, 0));
            }
            if cmd.starts_with("wget ") || cmd.starts_with("rm -f ") {
                return Ok((String::new(), 0));
            }
            // Match the exact install command, so dropping a force flag fails
            // the fixture instead of slipping through a prefix match.
            let is_install = cmd == format!("{OPKG_INSTALL_LOCAL} /tmp/tollgate.ipk 2>&1")
                || cmd == "apk add --allow-untrusted /tmp/tollgate.apk 2>&1";
            if is_install {
                installed.store(true, std::sync::atomic::Ordering::SeqCst);
                return Ok((String::new(), 0));
            }
            panic!("unexpected command: {cmd}");
        });
        (router, commands)
    }

    fn install_with(manager: PkgManager, router: &Router) -> Result<()> {
        match manager {
            PkgManager::Opkg => install_tollgate(router),
            PkgManager::ApkNative => install_tollgate_apk_native(router),
        }
    }

    #[test]
    fn regression_opkg_installs_verified_pinned_local_asset() {
        let (router, commands) = install_fixture(PkgManager::Opkg, "0.6.0-r1", false);
        install_tollgate(&router).unwrap();
        let commands = commands.lock().unwrap();
        let verify = commands
            .iter()
            .position(|c| c.starts_with("command -v sha256sum"))
            .expect("must verify asset");
        let expected = format!("{OPKG_INSTALL_LOCAL} /tmp/tollgate.ipk 2>&1");
        let install = commands
            .iter()
            .position(|c| *c == expected)
            .unwrap_or_else(|| {
                panic!(
                    "must install the verified local asset with the full force set \
                     (--force-reinstall is what makes an install over a stale package \
                     database actually write files); saw: {commands:#?}"
                )
            });
        assert!(verify < install);
        assert!(
            !commands
                .iter()
                .any(|c| c.starts_with(&format!("opkg install {TOLLGATE_PACKAGE}"))),
            "a by-name opkg install resolves against the router's feed and can install the \
             wrong version while reporting success"
        );
        assert_eq!(
            commands
                .iter()
                .filter(|c| *c == listing_cmd(PkgManager::Opkg))
                .count(),
            2
        );
    }

    #[test]
    fn regression_both_installers_reject_successful_but_stale_install() {
        for manager in [PkgManager::Opkg, PkgManager::ApkNative] {
            let (router, _) = install_fixture(manager, "0.5.0-r1", false);
            assert!(
                install_with(manager, &router).is_err(),
                "stale install must fail: {manager:?}"
            );
        }
    }

    #[test]
    fn regression_apk_rejects_successful_but_stale_install() {
        let (router, _) = install_fixture(PkgManager::ApkNative, "0.5.0-r1", false);
        assert!(install_tollgate_apk_native(&router).is_err());
    }

    #[test]
    fn regression_an_unreachable_router_is_not_reported_as_not_installed() {
        // Every command fails at the transport level: we could not ask, which is
        // not the same answer as "not installed". Reporting Absent here makes a
        // healthy-but-unreachable gateway look unprovisioned and invites a
        // reinstall.
        let router = Router::scripted(|_| Err(anyhow::anyhow!("channel closed")));
        assert_eq!(
            installed_tollgate_version_any(&router),
            Installed::UnknownVersion
        );
    }

    #[test]
    fn regression_both_installers_read_the_version_back_after_installing() {
        for manager in [PkgManager::Opkg, PkgManager::ApkNative] {
            let (router, commands) = install_fixture(manager, "0.6.0-r1", false);
            install_with(manager, &router).unwrap();
            let commands = commands.lock().unwrap();
            let install = commands
                .iter()
                .position(|c| {
                    (c.starts_with("opkg install") || c.starts_with("apk add"))
                        && c.contains("/tmp/tollgate.")
                })
                .expect("the installer must install the local asset");
            let read_back = commands
                .iter()
                .rposition(|c| *c == listing_cmd(manager))
                .expect("the installer must read the version back");
            assert!(
                read_back > install,
                "{manager:?}: the read-back must come AFTER the install, or it repeats \
                 the pre-install decision and can never catch a wrong-version install"
            );
        }
    }

    #[test]
    fn regression_a_router_with_no_package_and_no_binary_is_absent() {
        // The UnknownVersion-vs-Absent distinction must stay honest in both
        // directions: a listing that answered "not here" plus no binary is a
        // clean install, not a transport failure.
        let router = Router::scripted(|cmd| {
            if cmd.contains("list-installed") || cmd.contains("list --installed") {
                return Ok((String::new(), 0));
            }
            Ok((String::new(), cmd.starts_with("test -f").into()))
        });
        assert_eq!(installed_tollgate_version_any(&router), Installed::Absent);
    }

    #[test]
    fn regression_both_installers_stop_on_digest_mismatch() {
        for manager in [PkgManager::Opkg, PkgManager::ApkNative] {
            let (router, commands) = install_fixture(manager, "0.6.0-r1", true);
            assert!(install_with(manager, &router).is_err());
            assert!(!commands
                .lock()
                .unwrap()
                .iter()
                .any(|c| c.starts_with("opkg install") || c.starts_with("apk add")));
        }
    }

    #[test]
    fn extracts_the_version_from_the_binarys_self_report() {
        let out = "TollGate Gateway\nversion: 0.5.0-gabc1234\ncommit: abc1234\n";
        assert_eq!(extract_version_line(out).as_deref(), Some("0.5.0"));
    }

    #[test]
    fn tolerates_a_plain_version_line() {
        let out = "version: 0.6.0\n";
        assert_eq!(extract_version_line(out).as_deref(), Some("0.6.0"));
    }

    #[test]
    fn is_not_fooled_by_a_commit_line_that_contains_the_word_version() {
        // Only a `version:` label counts; `commit:` must not be picked up.
        let out = "commit: deadbeef\nversion: 0.6.0-rc6-g1234abc\n";
        assert_eq!(extract_version_line(out).as_deref(), Some("0.6.0-rc6"));
    }

    #[test]
    fn returns_none_when_there_is_no_version_line() {
        // The caller turns this into UnknownVersion, which forces an install —
        // it must not be silently treated as a match.
        assert_eq!(extract_version_line("something else entirely\n"), None);
    }

    // ---- both install paths must consult the version decision -------------
    //
    // This is the gap that let a blocking defect through a green suite. All the
    // `decide_install` tests exercise it in isolation; none asserted it was
    // CALLED by both install paths. So when the opkg path kept its presence-only
    // guard, every test still passed and the bump remained a silent no-op on
    // OpenWrt <=24.x — the exact failure the change claims to remove.
    //
    // A source-level assertion is the honest tool here: the router is an SSH
    // session, so "was the decision consulted before installing" is a question
    // about the code path, not about a return value.

    fn function_body(name: &str) -> String {
        let src = include_str!("install.rs");
        let start = src
            .find(&format!("pub fn {name}("))
            .unwrap_or_else(|| panic!("{name} not found"));
        let rest = &src[start..];
        // Body ends at the next top-level `pub fn` or the doc comment above it.
        let end = rest[1..]
            .find("\npub fn ")
            .map(|i| i + 1)
            .unwrap_or(rest.len());
        rest[..end].to_string()
    }

    #[test]
    fn the_opkg_path_consults_the_version_decision_before_installing() {
        let body = function_body("install_tollgate");
        assert!(
            body.contains("decide_install"),
            "install_tollgate must consult decide_install; without it a router \
             carrying an old version is reported as installed"
        );
        let decide_at = body.find("decide_install").expect("checked above");
        // The install must be a LOCAL verified asset, not a by-name opkg
        // request: by-name resolves against whatever feed the router has and
        // reports success for the wrong version.
        let install_at = body
            .find("OPKG_INSTALL_LOCAL")
            .expect("install_tollgate must install the verified local asset");
        assert!(
            decide_at < install_at,
            "the version decision must come BEFORE the install call, or it is \
             discarded by opkg's name-only short-circuit"
        );
        assert!(
            !body.contains("opkg_install(TOLLGATE_PACKAGE)"),
            "the presence-only opkg_install must not be used once a version \
             decision exists: it returns Ok(()) on any version"
        );
        assert!(
            body.contains("assert_installed_version"),
            "install_tollgate must read the version back: opkg's exit status does \
             not prove the pin took effect"
        );
    }

    #[test]
    fn the_apk_path_consults_the_version_decision_before_installing() {
        let body = function_body("install_tollgate_apk_native");
        let decide_at = body
            .find("decide_install")
            .expect("install_tollgate_apk_native must consult decide_install");
        let install_at = body
            .find("apk add --allow-untrusted")
            .expect("the apk path must install");
        assert!(
            decide_at < install_at,
            "the version decision must come before the apk install"
        );
    }

    // ---- the post-install read-back must be REACHED from both paths -------

    #[test]
    fn both_install_paths_assert_the_installed_version_after_installing() {
        // The install commands report success for a package that resolved to a
        // different version; the read-back is the only thing that turns that
        // into a failure. It is useless if it is defined but never called.
        for name in ["install_tollgate", "install_tollgate_apk_native"] {
            let body = function_body(name);
            assert!(
                body.contains("assert_installed_version"),
                "{name} must read the installed version back; without it a wrong-version \
                 install still reports success"
            );
        }
    }

    #[test]
    fn a_router_still_on_the_old_version_cannot_satisfy_the_pin() {
        // The decision the read-back makes, on the listing of exactly the state
        // this change exists to detect. `assert_installed_version` delegates to
        // `satisfies`, so this is the assertion that makes it fail loudly
        // instead of passing a 0.5.0 router as provisioned.
        let installed = parse_installed("tollgate-wrt - 0.5.0-r1\n", TOLLGATE_PACKAGE);
        let desired = package_version_from_pin(TOLLGATE_VERSION).unwrap();
        assert_eq!(desired, "0.6.0");
        assert!(!installed.satisfies(&desired));
        assert_eq!(
            installed,
            Installed::Version("0.5.0-r1".to_string()),
            "the listing must parse as a version, not fall through to Absent"
        );
    }

    #[test]
    fn a_binary_self_report_on_the_pin_satisfies_it() {
        // The manual-extraction path: no package record, so the binary's own
        // `tollgate version` output decides. It appends a git suffix.
        let out = extract_version_line("version: 0.6.0-gabc1234\n").unwrap();
        assert!(
            Installed::Version(out).satisfies("0.6.0"),
            "a binary reporting 0.6.0-gabc1234 is on the 0.6.0 pin"
        );
    }
}
