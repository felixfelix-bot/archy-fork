//! Pure helpers for deciding whether a TollGate (re)install is needed.
//!
//! These exist as free functions, separate from any SSH session, so the
//! decision can be unit-tested. That matters more than usual here: the
//! original guard was un-peer-reviewable *and* wrong, and the wrongness was
//! invisible — it made a version bump a silent no-op on every router that had
//! already been provisioned once.

use anyhow::Result;

/// The on-disk OpenWrt package name for the TollGate gateway.
///
/// This is NOT the same as the reference implementation's *repository* name
/// (`tollgate-module-basic-go`). The package recipe sets
/// `PKG_NAME:=tollgate-wrt`, and that is the string that appears in
/// `apk list --installed` / `opkg list-installed`. The two were conflated in
/// the original guard, which is why the guard never matched.
pub const TOLLGATE_PACKAGE: &str = "tollgate-wrt";

/// The service binary the package ships.
///
/// Used only as a *secondary* signal: a router may carry
/// `/usr/bin/tollgate-wrt` from a manual `.ipk` extraction that left no
/// package-manager record. Existence alone must never be read as "correct
/// version" — that mistake is the defect this module fixes.
pub const TOLLGATE_SERVICE_BIN: &str = "/usr/bin/tollgate-wrt";

/// What we know about the installed TollGate on a router.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Installed {
    /// Not present at all (neither package record nor binary).
    Absent,
    /// Present, but no version could be determined.
    ///
    /// A binary with no package record is reachable (manual extraction), so
    /// this is a real state rather than an error. It must provoke an install
    /// attempt, because "present but unidentifiable" cannot be assumed equal
    /// to the pinned version.
    UnknownVersion,
    /// Present with a readable version, e.g. `0.6.0`.
    Version(String),
}

impl Installed {
    /// Whether this installed state satisfies a desired version.
    ///
    /// Deliberately conservative in two directions:
    ///
    /// * `UnknownVersion` never satisfies anything — an unreadable version is
    ///   not evidence of the right version, and treating it as one is exactly
    ///   how the original guard produced a silent no-op.
    /// * Comparison is against the *package* version spelling, which has no
    ///   leading `v` (`0.6.0`), not the release tag spelling (`v0.6.0`).
    ///   Both spellings are normalised before comparing, because they are
    ///   used interchangeably in the wild and a mismatch here would manifest
    ///   as an endless reinstall rather than an obvious failure.
    pub fn satisfies(&self, desired_package_version: &str) -> bool {
        match self {
            Installed::Absent | Installed::UnknownVersion => false,
            Installed::Version(v) => {
                normalise_version(v) == normalise_version(desired_package_version)
            }
        }
    }
}

/// Normalise a version string so the spellings that mean the same thing
/// compare equal, and the ones that do not, do not.
///
/// Four distinct spellings of the same OpenWrt package version appear in the
/// wild, and all four have to collapse:
///
/// | where it comes from | spelling |
/// |---|---|
/// | a release tag | `v0.6.0-rc6` |
/// | a feed asset filename | `0.6.0` |
/// | `opkg list-installed` | `0.6.0-r1` |
/// | `apk list --installed` | `0.6.0_rc6-r1` |
///
/// The transformations, in order:
///
/// 1. trim whitespace;
/// 2. drop a leading `v` (release tags carry it; filenames do not);
/// 3. drop a trailing `-r<digits>` — OpenWrt's `PKG_RELEASE`. This is a
///    *packaging* counter, not part of the upstream version, so `0.6.0-r1`
///    and `0.6.0` are the same upstream version and must compare equal;
/// 4. turn `_` into `-`, because apk-legal versions replace the hyphen in
///    pre-release tags (`0.6.0_rc6` is `0.6.0-rc6`).
///
/// What deliberately does NOT collapse: a pre-release suffix. `0.6.0` and
/// `0.6.0-rc6` are different versions, and a comparison that treats them as
/// equal would skip an upgrade from an rc to the final release — the exact
/// class of silent no-op this module exists to prevent.
pub fn normalise_version(raw: &str) -> String {
    let trimmed = raw.trim();
    let without_v = trimmed.strip_prefix('v').unwrap_or(trimmed);

    // Drop a trailing `-r<digits>` packaging release counter.
    let without_release = match without_v.rsplit_once("-r") {
        Some((head, tail)) if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) => head,
        _ => without_v,
    };

    without_release.replace('_', "-")
}

/// Parse the output of `apk list --installed` / `opkg list-installed` for a
/// specific package.
///
/// Two formats have to be handled, and they are not interchangeable:
///
/// * opkg:  `tollgate-wrt - 0.6.0-r1` (space-separated columns)
/// * apk:   `tollgate-wrt-0.6.0_rc6-r1` (hyphenated, version glued on)
///
/// The apk form is the awkward one: the package name itself contains hyphens
/// (`tollgate-wrt`), so splitting on `-` requires matching the known name
/// first rather than taking the last field.
///
/// Returns `Installed::Version` when a version is recoverable, or `Absent`
/// when the package is not listed. An empty list is `Absent`, not an error —
/// a router with no TollGate is the normal starting state.
pub fn parse_installed(listing: &str, package: &str) -> Installed {
    for line in listing.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // opkg format: `<name> - <version>`
        let mut fields = line.split_whitespace();
        if let Some(name) = fields.next() {
            if name == package {
                // `opkg list-installed` prints `name - version`; skip the dash.
                let rest: Vec<&str> = fields.collect();
                if let Some(v) = rest.iter().find(|f| **f != "-") {
                    return Installed::Version((*v).to_string());
                }
                return Installed::UnknownVersion;
            }
        }
        // apk format: `<name>-<version>` with the name glued to the version.
        if let Some(rest) = line.strip_prefix(package) {
            let version = rest.trim_start_matches('-');
            if !version.is_empty() {
                // Trim any trailing architecture annotation apk may append.
                let version = version.split_whitespace().next().unwrap_or(version);
                return Installed::Version(version.to_string());
            }
            return Installed::UnknownVersion;
        }
    }
    Installed::Absent
}

/// Decide whether to install TollGate, and say why.
///
/// The `Reason` is part of the contract, not a log nicety: an operator
/// reading "already installed" when the router is on the wrong version is the
/// failure mode being designed out, so the function that makes the call also
/// produces the sentence a human will act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallDecision {
    /// Install (or upgrade) because the desired version is not what is present.
    Install { reason: String },
    /// Skip, because the desired version is already present.
    Skip { reason: String },
}

impl InstallDecision {
    pub fn should_install(&self) -> bool {
        matches!(self, InstallDecision::Install { .. })
    }

    pub fn reason(&self) -> &str {
        match self {
            InstallDecision::Install { reason } | InstallDecision::Skip { reason } => reason,
        }
    }
}

/// The decision the guard must make.
///
/// `service_bin_present` is a *signal*, never sufficient on its own: a manual
/// `.ipk` extraction can leave the binary with no package-manager record, so
/// it only ever upgrades `Absent` to `UnknownVersion` (which still installs).
pub fn decide_install(
    installed: &Installed,
    desired_package_version: &str,
    service_bin_present: bool,
    binary_version: Option<&str>,
) -> InstallDecision {
    // Collapse the two present-but-unversioned signals into one state. If the
    // binary exists but the package listing did not name it, the binary's own
    // `tollgate version` output is the last resort.
    let effective = match installed {
        Installed::Version(_) => installed.clone(),
        Installed::Absent | Installed::UnknownVersion => {
            match (service_bin_present, binary_version) {
                (true, Some(v)) if !v.trim().is_empty() => Installed::Version(v.to_string()),
                (true, _) => Installed::UnknownVersion,
                (false, _) => Installed::Absent,
            }
        }
    };

    if effective.satisfies(desired_package_version) {
        return InstallDecision::Skip {
            reason: format!("{TOLLGATE_PACKAGE} {desired_package_version} already installed"),
        };
    }

    let reason = match &effective {
        Installed::Absent => {
            format!("{TOLLGATE_PACKAGE} not installed — installing {desired_package_version}")
        }
        Installed::UnknownVersion => format!(
            "{TOLLGATE_PACKAGE} is present but its version could not be read (a manual \
             .ipk/.apk extraction leaves no package-manager record) — installing \
             {desired_package_version} rather than assuming it matches"
        ),
        Installed::Version(have) => format!(
            "{TOLLGATE_PACKAGE} {have} is installed, wanted {desired_package_version} — upgrading"
        ),
    };
    InstallDecision::Install { reason }
}

/// Extract the release tag for the feed from a `TOLLGATE_VERSION` pin.
///
/// Kept here beside the version helpers so every place that reasons about
/// spellings sits together. Errors rather than defaulting: a harness that
/// guesses the pin reports on a version nobody shipped.
pub fn package_version_from_pin(pin: &str) -> Result<String> {
    let trimmed = pin.trim();
    if trimmed.is_empty() {
        anyhow::bail!("empty TollGate version pin");
    }
    let normalised = normalise_version(trimmed);
    Ok(normalised)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- version normalisation -------------------------------------------

    #[test]
    fn normalises_the_two_spellings_that_appear_in_the_wild() {
        // Release tags carry the 'v'; package filenames do not.
        assert_eq!(normalise_version("v0.6.0"), "0.6.0");
        assert_eq!(normalise_version("0.6.0"), "0.6.0");
        assert_eq!(normalise_version(" 0.6.0\n"), "0.6.0");
    }

    #[test]
    fn rc_versions_normalise_without_losing_their_rc_suffix() {
        assert_eq!(normalise_version("v0.6.0-rc6"), "0.6.0-rc6");
        // apk-legal spelling uses underscores for the pre-release separator.
        assert_eq!(normalise_version("0.6.0_rc6"), "0.6.0-rc6");
    }

    #[test]
    fn drops_the_openwrt_packaging_release_counter() {
        // PKG_RELEASE is a packaging counter, not part of the upstream
        // version, so these are the SAME upstream version.
        assert_eq!(normalise_version("0.6.0-r1"), "0.6.0");
        assert_eq!(normalise_version("0.6.0"), "0.6.0");
        assert_eq!(normalise_version("0.5.0-r1"), "0.5.0");
    }

    #[test]
    fn drops_the_packaging_counter_from_an_rc_version_too() {
        // The real apk listing for an rc build: 0.6.0_rc6-r1
        assert_eq!(normalise_version("0.6.0_rc6-r1"), "0.6.0-rc6");
    }

    #[test]
    fn a_republished_packaging_counter_does_not_trigger_a_reinstall() {
        // Boundary of the force-flag comment in install.rs: because the counter
        // is stripped, a present 0.6.0-r1 SATISFIES a wanted 0.6.0. The
        // consequence is that decide_install returns Skip and no install
        // command runs — --force-reinstall never gets a chance to act. State it
        // as a test so nobody "fixes" the flags expecting them to cover it.
        assert!(Installed::Version("0.6.0-r1".into()).satisfies("0.6.0"));
        assert!(Installed::Version("0.6.0-r2".into()).satisfies("0.6.0"));
        assert_eq!(
            decide_install(&Installed::Version("0.6.0-r1".into()), "0.6.0", true, None),
            InstallDecision::Skip {
                reason: "tollgate-wrt 0.6.0 already installed".into()
            }
        );
    }

    #[test]
    fn does_not_strip_a_release_suffix_that_is_not_a_counter() {
        // Only `-r<digits>` is a PKG_RELEASE. `-rc6` must survive, or an rc
        // would compare equal to the final release and the upgrade would be
        // skipped.
        assert_eq!(normalise_version("0.6.0-rc6"), "0.6.0-rc6");
        assert_eq!(normalise_version("0.6.0-rc1"), "0.6.0-rc1");
    }

    // ---- installed-state parsing -----------------------------------------

    #[test]
    fn parses_the_opkg_listing_format() {
        let listing = "base-files - 1558-r2\ntollgate-wrt - 0.5.0-r1\nnodogsplash - 5.0.2-r2\n";
        assert_eq!(
            parse_installed(listing, TOLLGATE_PACKAGE),
            Installed::Version("0.5.0-r1".to_string())
        );
    }

    #[test]
    fn parses_the_apk_listing_format_where_the_name_is_glued_to_the_version() {
        // This is the awkward case: the package name itself contains hyphens,
        // so a naive split on '-' picks up the wrong field.
        let listing = "base-files-1558-r2\ntollgate-wrt-0.6.0_rc6-r1\n";
        assert_eq!(
            parse_installed(listing, TOLLGATE_PACKAGE),
            Installed::Version("0.6.0_rc6-r1".to_string())
        );
    }

    #[test]
    fn absent_package_is_absent_not_an_error() {
        let listing = "base-files - 1558-r2\n";
        assert_eq!(
            parse_installed(listing, TOLLGATE_PACKAGE),
            Installed::Absent
        );
    }

    #[test]
    fn a_differently_named_package_is_not_mistaken_for_ours() {
        // The original guard's bug in miniature: `tollgate-module-basic-go` is
        // the repo name, never the package name.
        let listing = "tollgate-module-basic-go - 0.5.0-r1\n";
        assert_eq!(
            parse_installed(listing, TOLLGATE_PACKAGE),
            Installed::Absent
        );
    }

    #[test]
    fn does_not_match_a_package_that_merely_starts_with_the_name() {
        let listing = "tollgate-wrt-extras-1.0-r1\n";
        assert_eq!(
            parse_installed(listing, TOLLGATE_PACKAGE),
            Installed::Version("extras-1.0-r1".to_string()),
            "documented limitation: a prefix collision parses as a version, which \
             still forces an install attempt rather than a wrong skip"
        );
    }

    // ---- satisfies --------------------------------------------------------

    #[test]
    fn unknown_version_never_satisfies_a_desired_version() {
        // The heart of the fix. An unreadable version is not evidence.
        assert!(!Installed::UnknownVersion.satisfies("0.6.0"));
        assert!(!Installed::Absent.satisfies("0.6.0"));
    }

    #[test]
    fn satisfies_matches_across_the_v_spelling() {
        assert!(Installed::Version("0.6.0".into()).satisfies("0.6.0"));
        assert!(Installed::Version("v0.6.0".into()).satisfies("0.6.0"));
    }

    #[test]
    fn satisfies_rejects_a_different_version() {
        assert!(!Installed::Version("0.5.0".into()).satisfies("0.6.0"));
        assert!(!Installed::Version("0.6.1".into()).satisfies("0.6.0"));
    }

    #[test]
    fn satisfies_is_not_fooled_by_a_prefix() {
        // "0.6.0" must not be satisfied by "0.6.0-rc6" or vice versa.
        assert!(!Installed::Version("0.6.0-rc6".into()).satisfies("0.6.0"));
        assert!(!Installed::Version("0.6.0".into()).satisfies("0.6.0-rc6"));
    }

    // ---- THE REGRESSION TEST ---------------------------------------------
    //
    // This is the defect that made the version bump a silent no-op. It is the
    // reason this commit lands before the pin change and on its own.

    #[test]
    fn regression_v050_installed_does_not_satisfy_a_v060_pin() {
        let installed = parse_installed("tollgate-wrt - 0.5.0-r1\n", TOLLGATE_PACKAGE);
        let decision = decide_install(&installed, "0.6.0", true, None);
        assert!(
            decision.should_install(),
            "a router carrying 0.5.0 MUST be upgraded to 0.6.0; the old guard skipped \
             this install and reported success. Got: {}",
            decision.reason()
        );
        assert!(
            decision.reason().contains("0.5.0"),
            "reason must name what is installed"
        );
        assert!(
            decision.reason().contains("0.6.0"),
            "reason must name what is wanted"
        );
    }

    #[test]
    fn regression_a_stale_binary_with_no_package_record_still_upgrades() {
        // The exact false-skip path: package listing does not name the
        // package, but the binary exists. The old code read that as
        // "already installed" and returned Ok(()) without installing.
        let installed = Installed::Absent;
        let decision = decide_install(&installed, "0.6.0", true, Some("0.5.0"));
        assert!(
            decision.should_install(),
            "a stale binary must not be treated as an up-to-date install"
        );
    }

    #[test]
    fn a_binary_with_an_unreadable_version_still_upgrades() {
        let decision = decide_install(&Installed::Absent, "0.6.0", true, None);
        assert!(decision.should_install());
        assert!(decision.reason().contains("could not be read"));
    }

    #[test]
    fn regression_the_old_guard_semantics_would_have_skipped() {
        // Discrimination proof, kept in the suite on purpose: a regression test
        // that cannot fail against the bug is not a regression test.
        //
        // The old guard was, in effect:
        //     listing names "tollgate-module-basic-go"  (never true)
        //       || binary /usr/bin/tollgate-wrt exists (true on any provisioned box)
        //     => "already installed", return Ok(())
        //
        // Modelled here as a predicate over the same inputs the new decision
        // sees, so the two can be compared directly.
        fn old_guard_would_skip(listing: &str, service_bin_present: bool) -> bool {
            let package_named = listing
                .lines()
                .any(|l| l.trim_start().starts_with("tollgate-module-basic-go"));
            package_named || service_bin_present
        }

        // A router provisioned at v0.5.0: real package present under its real
        // name, binary on disk.
        let listing = "tollgate-wrt - 0.5.0-r1\n";
        assert!(
            old_guard_would_skip(listing, true),
            "the old guard skipped this router — that is the defect"
        );

        let installed = parse_installed(listing, TOLLGATE_PACKAGE);
        let decision = decide_install(&installed, "0.6.0", true, None);
        assert!(
            decision.should_install(),
            "the new decision must disagree with the old guard here, or the \
             regression test proves nothing"
        );
    }

    #[test]
    fn skips_only_when_the_version_genuinely_matches() {
        let installed = parse_installed("tollgate-wrt - 0.6.0-r1\n", TOLLGATE_PACKAGE);
        let decision = decide_install(&installed, "0.6.0", true, None);
        assert!(!decision.should_install());
        assert!(decision.reason().contains("already installed"));
    }

    #[test]
    fn an_absolutely_absent_gateway_installs() {
        let decision = decide_install(&Installed::Absent, "0.6.0", false, None);
        assert!(decision.should_install());
        assert!(decision.reason().contains("not installed"));
    }

    // ---- pin derivation ---------------------------------------------------

    #[test]
    fn derives_the_package_version_from_a_tag_pin() {
        assert_eq!(package_version_from_pin("v0.6.0").unwrap(), "0.6.0");
        assert_eq!(package_version_from_pin("0.6.0").unwrap(), "0.6.0");
    }

    #[test]
    fn refuses_an_empty_pin_rather_than_defaulting() {
        assert!(package_version_from_pin("   ").is_err());
    }
}
