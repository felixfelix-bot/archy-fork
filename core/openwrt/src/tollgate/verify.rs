//! Verifying a downloaded package before it is installed.
//!
//! The download path used to have one gate: a 50 KB size floor. That catches
//! an HTML error page and nothing else — a truncated transfer, a corrupted
//! mirror, or a substituted file of plausible size all pass. The size floor
//! stays (it is cheap and it produces a clearer message than a hash mismatch
//! for the common case), but it is no longer the only check.
//!
//! The release publishes a `SHA256SUMS` manifest alongside the
//! packages, so the expected digest is available from a source independent of
//! the file being checked.
//!
//! **What this does and does not prove.** It detects corruption and truncation:
//! a file that was mangled in transit or replaced by an error page cannot match
//! a digest the release published. It does NOT establish authenticity against an
//! active on-path attacker, because both the package and the manifest are
//! fetched with certificate verification disabled (fresh OpenWrt images ship
//! without a CA bundle) and the manifest's own `SHA256SUMS.sig` is not fetched or
//! verified. Such an attacker can serve a payload *and* a matching manifest.
//! Claiming otherwise in a doc comment about a money path would be worse than
//! having no check at all, because a reader cannot tell the two apart.

/// The manifest filename, as published by the feed's release job.
pub const SHA256SUMS_NAME: &str = "SHA256SUMS";

/// Minimum plausible size for a `tollgate-wrt` package.
///
/// The shipped assets are ~8–10 MB; the Go binary alone is several MB. 50 KB
/// is far below any real package and far above any HTML error page, which is
/// what makes it a useful cheap pre-check rather than a security control.
pub const MIN_PACKAGE_BYTES: u64 = 50_000;

/// A parsed `SHA256SUMS` manifest: filename → hex digest.
///
/// The manifest format is the standard `sha256sum` output — one line per file,
/// `<64 hex chars><whitespace><filename>` — with the filename sometimes
/// prefixed by `*` (binary mode) or `./`. All three spellings occur in the
/// wild, so all three are accepted.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Manifest {
    entries: Vec<(String, String)>,
}

impl Manifest {
    /// Parse `sha256sum` output.
    ///
    /// Unparseable lines are skipped rather than failing the parse: a manifest
    /// may legitimately carry blank lines, comments, or entries for files this
    /// caller does not care about. The *lookup* is what fails closed.
    pub fn parse(text: &str) -> Self {
        let mut entries = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            // Strip a leading `*` first. `sha256sum -b` emits the binary-mode
            // marker either before the digest or before the filename depending
            // on the tool and version, so handling only one of those positions
            // leaves a 65-character "digest" that then fails the hex check and
            // silently drops the entry — a manifest that parses short is worse
            // than one that fails loudly, because the missing entry looks like
            // an unpublished asset.
            let line = line.strip_prefix('*').unwrap_or(line);

            let Some((digest, name)) = line.split_once(char::is_whitespace) else {
                continue;
            };
            let digest = digest.trim();
            // A SHA-256 digest is exactly 64 hex characters. Anything else is
            // not a digest and must not be treated as one.
            if digest.len() != 64 || !digest.chars().all(|c| c.is_ascii_hexdigit()) {
                continue;
            }
            let name = name.trim();
            // Strip the `*` marker before the filename, and any `./` prefix.
            let name = name.strip_prefix('*').unwrap_or(name);
            let name = name.strip_prefix("./").unwrap_or(name);
            if !name.is_empty() {
                entries.push((name.to_string(), digest.to_ascii_lowercase()));
            }
        }
        Manifest { entries }
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Look up a filename. Matches on the basename so a manifest written with
    /// a directory prefix still resolves.
    pub fn digest_for(&self, filename: &str) -> Option<&str> {
        let wanted = filename.rsplit('/').next().unwrap_or(filename);
        self.entries
            .iter()
            .find(|(name, _)| name == wanted || name.rsplit('/').next() == Some(wanted))
            .map(|(_, digest)| digest.as_str())
    }
}

/// The outcome of verifying a download.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerifyOutcome {
    /// Digest matched the manifest.
    Verified { digest: String },
    /// Digest did not match.
    Mismatch { expected: String, actual: String },
    /// The file is too small to be a package.
    TooSmall { bytes: u64 },
    /// No manifest entry for this filename, so no independent digest exists.
    ///
    /// A distinct outcome from `Mismatch` on purpose. An absent entry is a
    /// *provenance* problem (the release did not publish what we asked for),
    /// whereas a mismatch is an *integrity* problem (someone served different
    /// bytes). Collapsing them into one "verification failed" loses the
    /// distinction an operator needs.
    NoManifestEntry { filename: String },
    /// The manifest itself was empty or unparseable.
    NoManifest,
}

impl VerifyOutcome {
    pub fn is_verified(&self) -> bool {
        matches!(self, VerifyOutcome::Verified { .. })
    }

    /// Whether installation may proceed.
    ///
    /// Only `Verified` returns true. `NoManifestEntry` and `NoManifest` are
    /// deliberately fatal: an unpublishable digest is exactly the case where a
    /// substituted file would go unnoticed, and this is a money path — the
    /// gateway takes payments with the binary being installed.
    pub fn may_install(&self) -> bool {
        self.is_verified()
    }

    /// A message an operator can act on, naming what was checked.
    pub fn message(&self) -> String {
        match self {
            VerifyOutcome::Verified { digest } => {
                format!("package verified against SHA256SUMS (sha256:{digest})")
            }
            VerifyOutcome::Mismatch { expected, actual } => format!(
                "package digest MISMATCH — expected sha256:{expected}, got sha256:{actual}. \
                 The download is not the file the release published; refusing to install."
            ),
            VerifyOutcome::TooSmall { bytes } => format!(
                "package is only {bytes}B (minimum {MIN_PACKAGE_BYTES}B) — the download \
                 likely captured an error page rather than a package."
            ),
            VerifyOutcome::NoManifestEntry { filename } => format!(
                "{SHA256SUMS_NAME} has no entry for {filename} — the release did not publish \
                 this asset, or it was published under a different name. Refusing to install \
                 a package whose integrity cannot be checked against the release manifest."
            ),
            VerifyOutcome::NoManifest => format!(
                "{SHA256SUMS_NAME} was empty or unparseable — cannot verify the download. \
                 Refusing to install."
            ),
        }
    }
}

/// Decide whether a downloaded file may be installed.
///
/// Pure, so the policy is unit-testable without a router: given the file size,
/// its digest, and the manifest text, what happens?
pub fn verify_download(
    filename: &str,
    bytes: u64,
    actual_digest: &str,
    manifest_text: &str,
) -> VerifyOutcome {
    if bytes < MIN_PACKAGE_BYTES {
        return VerifyOutcome::TooSmall { bytes };
    }

    let manifest = Manifest::parse(manifest_text);
    if manifest.is_empty() {
        return VerifyOutcome::NoManifest;
    }

    let Some(expected) = manifest.digest_for(filename) else {
        return VerifyOutcome::NoManifestEntry {
            filename: filename.to_string(),
        };
    };

    let actual = actual_digest.trim().to_ascii_lowercase();
    if expected == actual {
        VerifyOutcome::Verified { digest: actual }
    } else {
        VerifyOutcome::Mismatch {
            expected: expected.to_string(),
            actual,
        }
    }
}

/// URL of the `SHA256SUMS` manifest for a release.
pub fn manifest_url(repo: &str, release_tag: &str) -> String {
    format!("https://github.com/{repo}/releases/download/{release_tag}/{SHA256SUMS_NAME}")
}

#[cfg(test)]
mod tests {
    use super::*;

    // A real-shaped excerpt: the feed's manifest covers the packages plus the
    // offline bundles, and uses the plain `sha256sum` layout.
    const MANIFEST: &str = "\
# TollGate v0.6.0 release manifest
d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2  tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk
00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff  tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.ipk
*abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  ./tollgate-wrt_0.6.0_x86_64-x86-64.apk
";

    #[test]
    fn parses_a_sha256sums_manifest() {
        let m = Manifest::parse(MANIFEST);
        assert_eq!(m.len(), 3, "comment line must be skipped");
        assert_eq!(
            m.digest_for("tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk"),
            Some("d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2")
        );
    }

    #[test]
    fn accepts_the_binary_mode_star_and_dot_slash_prefix() {
        let m = Manifest::parse(MANIFEST);
        assert_eq!(
            m.digest_for("tollgate-wrt_0.6.0_x86_64-x86-64.apk"),
            Some("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        );
    }

    #[test]
    fn ignores_lines_whose_digest_is_not_a_digest() {
        let text = "notadigest  file.apk\nd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2  good.apk\n";
        let m = Manifest::parse(text);
        assert_eq!(m.len(), 1);
        assert_eq!(m.digest_for("file.apk"), None);
    }

    #[test]
    fn lookup_is_case_insensitive_on_the_digest() {
        let m = Manifest::parse(MANIFEST);
        let upper = m
            .digest_for("tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk")
            .unwrap()
            .to_uppercase();
        let outcome = verify_download(
            "tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk",
            9_000_000,
            &upper,
            MANIFEST,
        );
        assert!(outcome.is_verified(), "{outcome:?}");
    }

    #[test]
    fn a_matching_digest_verifies() {
        let outcome = verify_download(
            "tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk",
            9_000_000,
            "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2",
            MANIFEST,
        );
        assert!(outcome.is_verified());
        assert!(outcome.may_install());
    }

    #[test]
    fn a_single_flipped_byte_is_caught() {
        // The whole point. A corrupted or substituted file of plausible size.
        let outcome = verify_download(
            "tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk",
            9_000_000,
            "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e3",
            MANIFEST,
        );
        assert!(!outcome.may_install());
        assert!(matches!(outcome, VerifyOutcome::Mismatch { .. }));
        assert!(outcome.message().contains("MISMATCH"));
    }

    #[test]
    fn a_tiny_file_is_rejected_before_hashing() {
        // An HTML error page: the size floor gives a clearer message than a
        // digest mismatch would.
        let outcome = verify_download("anything.apk", 1_200, "whatever", MANIFEST);
        assert!(matches!(outcome, VerifyOutcome::TooSmall { .. }));
        assert!(outcome.message().contains("error page"));
    }

    #[test]
    fn a_filename_absent_from_the_manifest_refuses_to_install() {
        // Provenance, not integrity — and deliberately fatal, because this is
        // the case where a substituted file would otherwise go unnoticed.
        let outcome = verify_download(
            "tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk.evil",
            9_000_000,
            "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2",
            MANIFEST,
        );
        assert!(matches!(outcome, VerifyOutcome::NoManifestEntry { .. }));
        assert!(!outcome.may_install());
        assert!(outcome.message().contains("no entry"));
    }

    #[test]
    fn an_empty_manifest_refuses_to_install() {
        let outcome = verify_download("x.apk", 9_000_000, "deadbeef", "");
        assert!(matches!(outcome, VerifyOutcome::NoManifest));
        assert!(!outcome.may_install());
    }

    #[test]
    fn a_manifest_of_only_junk_is_treated_as_absent_not_as_a_pass() {
        // Fails closed: unparseable is not the same as "nothing to check".
        let outcome = verify_download("x.apk", 9_000_000, "deadbeef", "garbage\nmore garbage\n");
        assert!(matches!(outcome, VerifyOutcome::NoManifest));
        assert!(!outcome.may_install());
    }

    #[test]
    fn manifest_url_points_at_the_release() {
        assert_eq!(
            manifest_url("FreedomTechFeed/packages", "v0.6.0"),
            "https://github.com/FreedomTechFeed/packages/releases/download/v0.6.0/SHA256SUMS"
        );
    }
}
