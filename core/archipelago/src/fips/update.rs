//! User-triggered FIPS upgrade from upstream GitHub releases.
//!
//! Flow (no auto-update, no background polling — user clicks a button):
//!   1. Query GitHub for the latest *stable* release of `jmcorgan/fips`
//!      (`/releases/latest` returns the newest non-prerelease, non-draft
//!      tag, so release candidates like `v0.4.0-rc1` are skipped).
//!   2. Compare its tag (e.g. `v0.3.0`) with the installed daemon version
//!      reported by `fipsctl --version`. A dev/pre-release build of the
//!      same number (`0.3.0-dev`) counts as older than the released tag.
//!   3. Pick the Debian package asset matching the host architecture
//!      (`fips_<ver>_amd64.deb` / `_arm64.deb`) plus `checksums-linux.txt`.
//!   4. Download both, SHA256-verify the .deb against the checksums file.
//!   5. `sudo dpkg -i` the verified .deb, then restart the active fips unit.
//!
//! Upstream began publishing tagged releases with `.deb` artefacts and
//! `checksums-linux.txt` (verified present as of v0.1.0 → v0.4.0-rc1), so
//! the apply path is fully wired against those assets.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{service, UPSTREAM_REPO, VERIFIED_UPSTREAM_VERSION};

const GITHUB_API: &str = "https://api.github.com";
const USER_AGENT: &str = "archipelago-fips-updater";

/// Result of `check()` — what the dashboard renders.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateCheck {
    /// Currently installed daemon version (from `fipsctl --version`).
    pub current: Option<String>,
    /// Tag of the latest stable upstream release, e.g. `v0.3.0`.
    pub latest_version: String,
    /// True when the installed version is older than `latest_version`.
    pub update_available: bool,
    /// Release channel this check tracked. Currently always "stable".
    pub channel: String,
    /// Browser download URL of the architecture-matched .deb for the
    /// latest release, when one exists (informational; apply() re-resolves).
    pub asset_url: Option<String>,
    /// Human-readable note for the UI.
    pub notes: String,
}

/// One GitHub release as we consume it.
#[derive(Debug, Clone, Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Debug, Clone, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

fn http_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .context("Build HTTP client")
}

/// Debian architecture string for the host (`amd64` / `arm64`). Returns
/// the raw `std::env::consts::ARCH` for anything we don't map, so the
/// asset lookup simply finds nothing and surfaces a clear error.
fn deb_arch() -> &'static str {
    match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => other,
    }
}

/// Query GitHub for the latest stable release the generated config is known to
/// be valid for, and compare to the installed version.
///
/// "Latest" is capped at [`VERIFIED_UPSTREAM_VERSION`]: the updater offers the
/// newest release **at or below** the tag `fips::config` has been verified
/// against, never merely the newest release that exists. Without the cap a
/// node would silently move onto a daemon whose config schema nobody checked —
/// which is how the `node.discovery.*` → `node.lookup.*`/`node.rendezvous.*`
/// split (v0.5.0) would have gone unnoticed on an updating fleet.
///
/// Never errors on "no package installed" — that is itself a valid state where
/// an update is available.
pub async fn check() -> Result<UpdateCheck> {
    let current = service::daemon_version().await.ok();
    let client = http_client()?;
    let release = fetch_verified_release(&client).await?;

    let update_available = match &current {
        Some(v) => version_is_older(v, &release.tag_name),
        None => true,
    };

    let asset_url = release
        .assets
        .iter()
        .find(|a| is_deb_for_arch(&a.name))
        .map(|a| a.browser_download_url.clone());

    let latest_overall = fetch_latest_stable(&client).await.ok();
    let notes = if update_available {
        format!(
            "Update available: {} (installed: {})",
            release.tag_name,
            current.as_deref().unwrap_or("not installed")
        )
    } else if let Some(overall) = latest_overall
        .as_ref()
        .filter(|o| version_is_older(&release.tag_name, &o.tag_name))
    {
        // Up to date against the cap, but newer upstream exists. Say so
        // explicitly rather than reporting a bare "up to date" — otherwise a
        // node holding a known-good version looks like it is on the newest
        // release, and nobody ever learns the cap is stale.
        format!(
            "Up to date at the verified ceiling {}. Newer upstream release {} \
             exists but is not verified for this build — bump \
             VERIFIED_UPSTREAM_VERSION first.",
            release.tag_name, overall.tag_name
        )
    } else {
        format!("Up to date ({})", release.tag_name)
    };

    Ok(UpdateCheck {
        current,
        latest_version: release.tag_name,
        update_available,
        channel: "stable".to_string(),
        asset_url,
        notes,
    })
}

/// Download, verify, and install the latest stable FIPS release, then
/// restart the daemon. Steps: resolve release → match .deb for this arch
/// → download .deb + checksums → SHA256-verify → `sudo dpkg -i` → restart.
pub async fn apply() -> Result<()> {
    let client = http_client()?;
    // Same cap as `check()`. Using `/releases/latest` here would install a
    // daemon the UI never offered — and, worse, one whose config schema is
    // unverified — while `check()` reported "up to date".
    let release = fetch_verified_release(&client).await?;

    let deb = release
        .assets
        .iter()
        .find(|a| is_deb_for_arch(&a.name))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "release {} has no .deb for architecture {}",
                release.tag_name,
                deb_arch()
            )
        })?;
    let checksums = release
        .assets
        .iter()
        .find(|a| a.name == "checksums-linux.txt")
        .ok_or_else(|| {
            anyhow::anyhow!("release {} has no checksums-linux.txt", release.tag_name)
        })?;

    // Download the .deb (bytes) and the checksums (text).
    let deb_bytes = client
        .get(&deb.browser_download_url)
        .send()
        .await
        .context("download .deb")?
        .error_for_status()
        .context(".deb download HTTP error")?
        .bytes()
        .await
        .context("read .deb body")?;
    let checksums_text = client
        .get(&checksums.browser_download_url)
        .send()
        .await
        .context("download checksums")?
        .error_for_status()
        .context("checksums download HTTP error")?
        .text()
        .await
        .context("read checksums body")?;

    // Verify SHA256 against the checksums manifest (sha256sum format:
    // "<hex>␠␠<filename>"). The filename column may include a leading
    // "*" (binary mode) or a path prefix, so match on the basename.
    let expected = checksums_text
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let hash = parts.next()?;
            let name = parts.next()?.trim_start_matches('*');
            let base = name.rsplit('/').next().unwrap_or(name);
            (base == deb.name).then(|| hash.to_lowercase())
        })
        .next()
        .ok_or_else(|| anyhow::anyhow!("checksums-linux.txt has no entry for {}", deb.name))?;

    let actual = {
        let mut hasher = Sha256::new();
        hasher.update(&deb_bytes);
        hex::encode(hasher.finalize())
    };
    if actual != expected {
        anyhow::bail!(
            "SHA256 mismatch for {}: expected {}, got {}",
            deb.name,
            expected,
            actual
        );
    }

    // Stage the verified .deb in /tmp (shared with the host — the
    // service runs with PrivateTmp=no) and install it.
    let dest = std::env::temp_dir().join(&deb.name);
    tokio::fs::write(&dest, &deb_bytes)
        .await
        .with_context(|| format!("write {}", dest.display()))?;

    // Run dpkg via `systemd-run` rather than `sudo dpkg` directly. The
    // archipelago service runs under `ProtectSystem=strict`, so `/usr`
    // and `/var/lib/dpkg` are read-only *inside the service's mount
    // namespace* — and a `sudo` child inherits that namespace, so a
    // bare `sudo dpkg -i` fails with "Read-only file system" on the
    // dpkg database. `systemd-run` asks PID 1 to launch the command in
    // a fresh transient scope outside our sandbox, where the real
    // (writable) host filesystem is visible. `--wait` blocks until it
    // finishes and propagates the exit status; `--pipe` forwards
    // dpkg's output; `--collect` reaps the unit even on failure.
    //
    // dpkg flags, both load-bearing for this package specifically:
    //   --force-confold:  the fips package ships conffiles under
    //     /etc/fips that archipelago rewrites at install time, so dpkg
    //     hits an interactive "keep/replace?" conffile prompt. With our
    //     closed stdin that aborts the configure step ("EOF on stdin at
    //     conffile prompt") and leaves the package half-unpacked
    //     (status `iU`), which `fips.status` then reports as
    //     `installed:false`. confold = keep our managed config, no prompt.
    //   --force-downgrade: ISO/dev nodes carry `0.3.0-dev-1`, which dpkg
    //     orders as NEWER than the stable tag `0.3.0` (a trailing
    //     `-dev` sorts above the bare release). Moving a dev build onto
    //     the stable line is therefore a dpkg "downgrade"; without this
    //     flag dpkg warns and exits non-zero. Our own version_is_older()
    //     gate already decided this is the wanted direction.
    // DEBIAN_FRONTEND=noninteractive belt-and-suspenders against any
    // other maintainer-script prompt.
    let dpkg = tokio::process::Command::new("sudo")
        .args([
            "-n",
            "systemd-run",
            "--collect",
            "--wait",
            "--quiet",
            "--pipe",
            "--",
            "env",
            "DEBIAN_FRONTEND=noninteractive",
            "dpkg",
            "--force-confold",
            "--force-downgrade",
            "-i",
        ])
        .arg(&dest)
        .output()
        .await
        .context("sudo systemd-run dpkg -i failed to launch")?;
    // Best-effort cleanup regardless of dpkg result.
    let _ = tokio::fs::remove_file(&dest).await;
    if !dpkg.status.success() {
        anyhow::bail!(
            "dpkg -i {} exited {}: {}",
            deb.name,
            dpkg.status,
            String::from_utf8_lossy(&dpkg.stderr).trim()
        );
    }

    // Restart whichever fips unit is supervising the daemon so the new
    // binary takes over.
    let unit = service::active_unit().await;
    service::restart(unit)
        .await
        .with_context(|| format!("restart {} after install", unit))?;
    Ok(())
}

/// `/releases/latest` returns the most recent non-prerelease, non-draft
/// release. We still re-check the flags defensively in case the endpoint
/// or repo settings change.
async fn fetch_latest_stable(client: &reqwest::Client) -> Result<Release> {
    let url = format!("{}/repos/{}/releases/latest", GITHUB_API, UPSTREAM_REPO);
    let resp = client
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .context("GitHub releases/latest API")?;
    if !resp.status().is_success() {
        anyhow::bail!("GitHub releases/latest API returned {}", resp.status());
    }
    let release: Release = resp.json().await.context("Parse release JSON")?;
    if release.draft || release.prerelease {
        anyhow::bail!(
            "releases/latest returned a {} release ({})",
            if release.draft { "draft" } else { "prerelease" },
            release.tag_name
        );
    }
    Ok(release)
}

/// The newest stable release at or below a ceiling.
///
/// Lists releases rather than using `/releases/latest` because the cap can sit
/// several releases behind the newest one — and does, by construction: the cap
/// only moves when somebody bumps it deliberately. Entries are walked newest
/// first and the first stable tag ≤ the ceiling wins.
///
/// **Fails closed.** It does NOT fall back to `/releases/latest` when no
/// in-ceiling candidate exists. An earlier revision did, "so a node is never
/// left unable to update at all" — but that made the ceiling advisory: a 403
/// (rate limit), a transient 5xx, or a withdrawn tag each silently produced the
/// newest release upstream, whose config schema is unverified, and `apply()`
/// would install it. That is precisely the failure the ceiling exists to stop.
/// Refusing to update is recoverable; installing an unverified daemon onto a
/// live node is not.
///
/// Pure over the release list so the policy is testable without HTTP.
fn select_verified_release<'a>(releases: &'a [Release], ceiling: &str) -> Result<&'a Release> {
    releases
        .iter()
        .filter(|r| !r.draft && !r.prerelease)
        // At or below the ceiling only.
        .filter(|r| !version_is_older(ceiling, &r.tag_name))
        .max_by_key(|r| version_sort_key(&r.tag_name))
        .ok_or_else(|| {
            anyhow::anyhow!(
                "no stable upstream release at or below the verified ceiling {ceiling}. \
                 Refusing to update: any newer release's config schema is unverified for \
                 this build. Bump VERIFIED_UPSTREAM_VERSION (and its fixtures) once the \
                 newer schema is verified."
            )
        })
}

/// Fetch the release list and select within the ceiling. Errors rather than
/// uncapping — see [`select_verified_release`].
async fn fetch_verified_release(client: &reqwest::Client) -> Result<Release> {
    let url = format!(
        "{}/repos/{}/releases?per_page=100",
        GITHUB_API, UPSTREAM_REPO
    );
    let resp = client
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .context("GitHub releases API")?;

    // A non-2xx is an ERROR, not a reason to reach for the uncapped endpoint.
    let releases: Vec<Release> = resp
        .error_for_status()
        .context("GitHub releases API returned an error status")?
        .json()
        .await
        .context("Parse releases JSON")?;

    Ok(select_verified_release(&releases, VERIFIED_UPSTREAM_VERSION)?.clone())
}

/// Sort key for a release tag: `(major, minor, patch)`.
///
/// Build metadata and pre-release suffixes sort as the release they attach to;
/// pre-releases are filtered out before this is used, so the simplification is
/// safe here and avoids a semver dependency for one comparison.
fn version_sort_key(tag: &str) -> (u64, u64, u64) {
    match parse_version(tag) {
        Some((core, _)) => core,
        None => (0, 0, 0),
    }
}

fn is_deb_for_arch(name: &str) -> bool {
    name.starts_with("fips_") && name.ends_with(&format!("_{}.deb", deb_arch()))
}

/// Parse the leading `MAJOR.MINOR.PATCH` triple from a version string,
/// plus whether a pre-release suffix (`-dev`, `-rc1`, …) follows it.
fn parse_version(s: &str) -> Option<((u64, u64, u64), bool)> {
    // Take the first whitespace token, drop a leading 'v'.
    let tok = s.split_whitespace().next().unwrap_or(s);
    let tok = tok.strip_prefix('v').unwrap_or(tok);
    // Split off any pre-release / build suffix.
    let (core, rest) = match tok.find(|c: char| c == '-' || c == '+') {
        Some(i) => (&tok[..i], &tok[i..]),
        None => (tok, ""),
    };
    let mut it = core.split('.');
    let major = it.next()?.parse::<u64>().ok()?;
    let minor = it.next().unwrap_or("0").parse::<u64>().ok()?;
    let patch = it.next().unwrap_or("0").parse::<u64>().ok()?;
    let has_prerelease = rest.starts_with('-');
    Some(((major, minor, patch), has_prerelease))
}

/// True when `installed` is strictly older than release tag `latest`.
/// Same numeric triple but `installed` carries a pre-release suffix while
/// `latest` doesn't ⇒ installed is older (e.g. `0.3.0-dev` < `v0.3.0`).
/// If either side can't be parsed, fall back to "differs ⇒ update".
fn version_is_older(installed: &str, latest: &str) -> bool {
    match (parse_version(installed), parse_version(latest)) {
        (Some((ic, ipre)), Some((lc, lpre))) => {
            if ic != lc {
                ic < lc
            } else {
                // Equal cores: a pre-release is older than the final release.
                ipre && !lpre
            }
        }
        _ => {
            // Unparseable: be conservative — offer the update unless the
            // installed string already mentions the latest tag.
            !installed.contains(latest.trim_start_matches('v'))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deb_arch_maps_known() {
        // On the host running tests this is whatever the test arch is;
        // just assert it returns a non-empty, lowercase token.
        let a = deb_arch();
        assert!(!a.is_empty());
        assert_eq!(a, a.to_lowercase());
    }

    #[test]
    fn test_version_older() {
        assert!(version_is_older("0.3.0-dev (rev abc123)", "v0.3.0"));
        assert!(version_is_older("0.2.1", "v0.3.0"));
        assert!(version_is_older("0.3.0-rc1", "v0.3.0"));
        assert!(!version_is_older("0.3.0", "v0.3.0"));
        assert!(!version_is_older("0.4.0", "v0.3.0"));
        assert!(!version_is_older("0.3.1", "v0.3.0"));
    }

    #[test]
    fn test_parse_version() {
        assert_eq!(parse_version("v0.3.0"), Some(((0, 3, 0), false)));
        assert_eq!(parse_version("0.3.0-dev (rev x)"), Some(((0, 3, 0), true)));
        assert_eq!(parse_version("0.4.0-rc1"), Some(((0, 4, 0), true)));
        assert_eq!(parse_version("1.2"), Some(((1, 2, 0), false)));
    }

    #[test]
    fn test_is_deb_for_arch() {
        let arch = deb_arch();
        assert!(is_deb_for_arch(&format!("fips_0.3.0_{}.deb", arch)));
        assert!(!is_deb_for_arch("fips_0.3.0_someotherarch.deb"));
        assert!(!is_deb_for_arch("checksums-linux.txt"));
        assert!(!is_deb_for_arch(&format!(
            "fips-0.3.0-linux-{}.tar.gz",
            arch
        )));
    }

    #[test]
    fn test_update_check_serialises() {
        let uc = UpdateCheck {
            current: Some("0.3.0-dev".to_string()),
            latest_version: "v0.3.0".to_string(),
            update_available: true,
            channel: "stable".to_string(),
            asset_url: Some("https://example/fips_0.3.0_amd64.deb".to_string()),
            notes: "test".to_string(),
        };
        let json = serde_json::to_string(&uc).unwrap();
        assert!(json.contains("latest_version"));
        assert!(json.contains("update_available"));
        assert!(json.contains("stable"));
    }

    /// The ceiling must be a real semantic version, and the ISO pin must match
    /// it. Drift between the two is the exact failure this constant exists to
    /// prevent: the shipped image and the runtime updater would disagree about
    /// which daemon version the config is written for.
    #[test]
    fn test_verified_ceiling_matches_the_iso_pin() {
        assert_eq!(
            parse_version(super::super::VERIFIED_UPSTREAM_VERSION).map(|(c, pre)| (c, pre)),
            Some(((0, 5, 3), false)),
            "VERIFIED_UPSTREAM_VERSION must be a plain release triple"
        );
        let iso = include_str!("../../../../image-recipe/_archived/build-auto-installer-iso.sh");
        let pin = iso
            .lines()
            .find_map(|l| l.strip_prefix("ARG FIPS_VERSION="))
            .map(str::trim)
            .expect("ISO builder declares ARG FIPS_VERSION");
        assert_eq!(
            pin.trim_start_matches('v'),
            super::super::VERIFIED_UPSTREAM_VERSION,
            "ISO pin ({pin}) and VERIFIED_UPSTREAM_VERSION disagree — \
             bump them together"
        );
    }

    /// A release newer than the ceiling must be excluded, and the ceiling
    /// itself must be included. This is the whole point of the cap.
    #[test]
    fn test_cap_excludes_newer_releases() {
        let cap = super::super::VERIFIED_UPSTREAM_VERSION;
        // At or below the cap: keep.
        assert!(!version_is_older(cap, "v0.5.3"));
        assert!(!version_is_older(cap, "v0.5.2"));
        assert!(!version_is_older(cap, "v0.4.1"));
        // Above the cap: exclude.
        assert!(version_is_older(cap, "v0.5.4"));
        assert!(version_is_older(cap, "v0.6.0"));
        assert!(version_is_older(cap, "v1.0.0"));
    }

    /// The ceiling must FAIL CLOSED. Every case where no in-ceiling candidate
    /// exists must be an error — never the newest release overall.
    ///
    /// Regression guard: an earlier revision fell back to `/releases/latest`
    /// here, so a rate-limited or failing release-list call silently produced
    /// an uncapped release, and `apply()` would install it. These assertions
    /// fail against that revision.
    #[test]
    fn test_selection_fails_closed_rather_than_uncapping() {
        let cap = super::super::VERIFIED_UPSTREAM_VERSION;
        let rel = |tag: &str| Release {
            tag_name: tag.to_string(),
            draft: false,
            prerelease: false,
            assets: Vec::new(),
        };

        // Nothing at or below the ceiling ⇒ ERROR, not the newest release.
        let all_newer = vec![rel("v9.9.9"), rel("v0.6.0")];
        let err = select_verified_release(&all_newer, cap)
            .expect_err("a list with no in-ceiling candidate must NOT uncap");
        assert!(
            err.to_string().contains(cap),
            "the error must name the ceiling; got: {err}"
        );

        // An empty list ⇒ ERROR (this is the rate-limit / withdrawn-tag shape).
        assert!(
            select_verified_release(&[], cap).is_err(),
            "an empty release list must not fall through to an uncapped release"
        );

        // Only drafts/prereleases ⇒ ERROR. They must not be installable either.
        let mut d = rel("v0.4.1");
        d.draft = true;
        let mut p = rel("v0.5.0");
        p.prerelease = true;
        assert!(
            select_verified_release(&[d, p], cap).is_err(),
            "draft/prerelease entries must not satisfy the ceiling"
        );
    }

    /// Within the ceiling, the newest wins — and the ceiling itself is eligible.
    /// This is the other half of the policy: failing closed must not mean
    /// refusing to update when a perfectly good in-ceiling release exists.
    #[test]
    fn test_selection_picks_newest_within_the_ceiling() {
        let cap = super::super::VERIFIED_UPSTREAM_VERSION; // v0.5.3
        let rel = |tag: &str| Release {
            tag_name: tag.to_string(),
            draft: false,
            prerelease: false,
            assets: Vec::new(),
        };
        // Newer-than-cap entries present and ignored; the ceiling itself wins
        // over older in-cap releases. Order is deliberately unsorted to prove
        // the selection is semantic, not positional.
        let list = vec![rel("v0.4.1"), rel("v0.6.0"), rel("v0.5.3"), rel("v0.5.2")];
        let got = select_verified_release(&list, cap).expect("an in-ceiling release exists");
        // The release carries the upstream tag form (`v0.5.3`); `cap` is the
        // bare triple. Compare against the tag, not the constant.
        assert_eq!(got.tag_name, format!("v{cap}"));

        // A withdrawn ceiling must degrade to the next-newest in-cap release,
        // NOT to an above-cap one.
        let list = vec![rel("v0.4.1"), rel("v0.6.0"), rel("v0.5.2")];
        let got = select_verified_release(&list, cap).expect("an in-ceiling release exists");
        assert_eq!(got.tag_name, "v0.5.2");
    }

    /// A semantic order check: v0.5.10 must beat v0.5.9 within the ceiling.
    /// String ordering gets this wrong, so it is worth an explicit case.
    #[test]
    fn test_selection_is_semantic_not_lexical() {
        let rel = |tag: &str| Release {
            tag_name: tag.to_string(),
            draft: false,
            prerelease: false,
            assets: Vec::new(),
        };
        let list = vec![rel("v0.5.9"), rel("v0.5.10"), rel("v0.5.2")];
        let got = select_verified_release(&list, "0.5.10").expect("v0.5.10 is in ceiling");
        assert_eq!(got.tag_name, "v0.5.10");
    }

    #[test]
    fn test_version_sort_key_is_semantic() {
        let mut tags = vec!["v0.4.1", "v0.5.10", "v0.5.3", "v0.5.9", "v0.5.2"];
        tags.sort_by(|a, b| version_sort_key(b).cmp(&version_sort_key(a)));
        assert_eq!(
            tags,
            vec!["v0.5.10", "v0.5.9", "v0.5.3", "v0.5.2", "v0.4.1"],
            "release list must sort by semantic version, newest first"
        );
    }
}
