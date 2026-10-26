# PLAN — Bump Archipelago's TollGate pin v0.5.0 → v0.6.0

**Target repo:** `felixfelix-bot/archy-fork` (fork of `lfg2025/archy`)
**Branch:** `pr/tollgate-v0.6.0` · **Base:** `origin/main` @ `fcc18b3`
**Worktree:** `~/worktrees/archy-tollgate-bump`
**Verification harness:** `felixfelix-bot/archy-tollgate-e2e`
**Written:** 2026-10-22

Upstream work is a deliberate, separate act. **This plan is fork-only. Do not
open an upstream PR without an explicit operator decision.**

---

## 0. Why this is not a one-line change

Archipelago pins `TOLLGATE_VERSION = "v0.5.0"` at
`core/openwrt/src/tollgate/install.rs:19` and builds download URLs as:

```
https://github.com/OpenTollGate/tollgate-module-basic-go/releases/download/{V}/tollgate-wrt_{V}_{arch}.{ipk,apk}
```

Bumping only that string to `v0.6.0` fails on **every** architecture, twice
over, without raising any error at bump time:

| # | Fact | Evidence |
|---|---|---|
| F1 | The `v0.6.0` release on that repo has **zero assets** | `gh api …/releases --jq '.[]\|{tag:.tag_name,n:(.assets\|length)}'` → v0.6.0 n=0, v0.5.0 n=17 |
| F2 | Packages moved to `FreedomTechFeed/packages` @ `v0.6.0` (26 assets) | live probe, HTTP 200 |
| F3 | Names are **target-qualified** and the filename version **drops the `v`** | `tollgate-wrt_0.6.0_<arch>-<target>.{apk,ipk}` |
| F4 | Archipelago never reads `DISTRIB_TARGET` | `grep -rn DISTRIB_TARGET core/` → no hits |

**Positive control** (so F1 is falsifiable): the v0.5.0 arch-only URL still
returns HTTP 200. If it ever stops, the probe is broken, not the finding.

## 1. Three latent defects the bump would otherwise hide

These are *pre-existing* bugs on the v0.5.0 pin. They are not caused by the
bump, but the bump makes two of them dangerous, so they ship in this change.

**D1 — the version bump is a silent no-op on a provisioned router.**
`install.rs:106-118` guards on the package name, then falls back to a file test:

```rust
"apk list --installed 2>/dev/null | grep -q '^{}' || \
 test -f /usr/bin/tollgate-wrt 2>/dev/null"   // TOLLGATE_PACKAGE
```

`TOLLGATE_PACKAGE = "tollgate-module-basic-go"` but the real package is
`tollgate-wrt` (`PKG_NAME:=tollgate-wrt`). The grep can **never** match; the
`test -f` then succeeds on any router already carrying the v0.5.0 binary, and
the function returns `Ok(())`. The install is skipped. The UI reports success.
This is the defect that makes the whole bump unverifiable, so it is fixed
first.

**D2 — the paid bridge is not the bridge that gets enforced.**
Side effect of D1's fix, worth stating: v0.6.0's shipped `uci-defaults`
hardcode `br-lan` — `99-tollgate-setup` sets
`nodogsplash.@nodogsplash[0].gatewayinterface='br-lan'`, and
`20-nds-enforce.nft` matches `iifname "br-lan"` four times. There are **zero**
`br-tollgate` references in the shipped tree. Archipelago deliberately runs the
paid SSID on `br-tollgate` (`wifi.rs:21-67`). Verified at the commit the feed
actually pins (`9364f2e`), not at the module tag:
`git show 9364f2e:packaging/files/etc/uci-defaults/99-tollgate-setup | grep gatewayinterface`.

**D3 — the download is unverified.**
The only gate is a 50 KB size floor (`install.rs:159`, `:199`). No checksum,
no signature. v0.6.0 publishes a signed `SHA256SUMS`; use it.

## 2. Config compatibility — settled, no action needed

Archipelago writes `"price_unit": "sats"` (`config.rs:107`). At the feed's
pinned commit `9364f2e`, `config_manager_config.go:561` migrates exactly that
spelling to `"sat"`, and there is **no** `Unit` field and therefore no unit
gate. So the written config neither misprices nor is rejected.

Do **not** "fix" `price_unit` to `sat` in this change: writing `sats` is
correct for both eras, and the migration is upstream's contract.

## 3. Scope — what this change does and does not do

**In:**
- `TOLLGATE_VERSION` → the v0.6.0 package release, sourced from the feed repo.
- Target-qualified asset naming (`arch` + `target`).
- `DISTRIB_TARGET` discovery.
- Widened arch/target tables (8 pairs, both formats) replacing the narrow
  v0.5.0-era allow-lists.
- The already-installed guard (D1) — corrected package name **and** a real
  version read-back.
- `SHA256SUMS` verification (D3).
- `jq` + `ca-bundle` installed by the install path.
- Version reported by `openwrt.get-status`.
- Docs.

**Out, explicitly:**
- The `br-lan` vs `br-tollgate` enforcement fix (D2). It needs a live router to
  verify and must not ride along unverified. **File it as its own card.**
- Adopting `tollgate-installer`. Separate architecture question.
- The schema-driven config UI.
- Anything on upstream. Fork-only.

---

## 4. Tasks

Each task states its deliverable, its acceptance evidence, and the command
that can falsify it. **A task is not done until the command was run and its
output observed.**

### T1 — Version + target discovery in `install.rs`  *(code)*

**Deliverable.** `TOLLGATE_VERSION` pinned to the feed release; a
`PackageTarget { arch, target }` read from the router; `ipk_url`/`apk_url`
replaced by a target-qualified builder against `FreedomTechFeed/packages`.

**Acceptance evidence.**
- A unit test asserting the exact URL for `(aarch64_cortex-a53,
  mediatek-filogic)` matches
  `…/FreedomTechFeed/packages/releases/download/v0.6.0/tollgate-wrt_0.6.0_aarch64_cortex-a53-mediatek-filogic.apk`.
- A unit test asserting the *legacy* shape still builds the old URL, so
  rollback stays one constant.
- `DISTRIB_TARGET` is read and `/`→`-` normalised.

**Falsify:** the URL for every one of the 8 published pairs returns non-200
(use the e2e harness's `tests/network/`).

### T2 — Fix the already-installed guard (D1)  *(code, blocking)*

**Deliverable.** Guard matches the real package name and compares versions;
an install over an existing v0.5.0 actually proceeds.

**Acceptance evidence.** A test that, given a router reporting
`tollgate-wrt 0.5.0` installed and a pin of v0.6.0, returns "must install"
(NOT "already installed"). This is the regression test for the exact defect.

**Falsify:** the test fails on the pre-fix code. **Observe the RED run.** This
is the single most important test in the change.

### T3 — SHA256 verification (D3)  *(code)*

**Deliverable.** Download checked against the release's `SHA256SUMS`; a
mismatch aborts before install. Keep the size floor as a cheap pre-check.

**Acceptance evidence.** Test with a deliberately corrupted byte → abort.
Test with the real asset → pass.

### T4 — Install the runtime deps the package declares  *(code)*

**Deliverable.** `jq` and `ca-bundle` installed alongside. The feed recipe
declares `DEPENDS:=+nodogsplash +jq +ca-bundle`; Archipelago's path resolves
no dependencies (it uses `wget --no-check-certificate` and
`apk add --allow-untrusted` / manual `ar`+`tar`), so nothing pulls them in.

**Acceptance evidence.** Both present on the router after provisioning.

### T5 — Report the installed version  *(code)*

**Deliverable.** `openwrt.get-status` returns the installed TollGate version.

**Acceptance evidence.** After a bump the version string changes. Without this
the bump cannot be verified from the UI at all.

### T6 — Docs  *(docs)*

`docs/openwrt-gateway-setup.md`: correct the package name (it says
`tollgate-module-basic-go`, which exists in no asset or control file), the
arch-troubleshooting text, and the post-install verification steps.
Add the D2 warning: the paid bridge is not yet the enforced bridge.

### T7 — E2E verification  *(code, gate)*

Run `archy-tollgate-e2e` against this branch: the router installs v0.6.0,
`openwrt.get-status` reports it, and a payment opens the gate.
**A green unit suite is not this task.** The version read-back (T5) is the
acceptance, because it is what D1 was hiding.

---

## 5. Gates

- `cd core && cargo check -p archipelago` → exit 0.
- `cargo fmt --all -- --check` → clean.
- `cargo clippy --all-targets --all-features -- -D warnings` → clean.
- Tests **only** via `scripts/test-backend-isolated.sh`. Unrestricted
  `cargo test` reaches real services (`AGENTS.md`). Note: the runner accepts
  only `-p archipelago`, `-p archipelago-publishing-tests`,
  `-p archipelago-container` — so `archipelago-openwrt` tests may need
  `cargo test -p archipelago-openwrt --no-run` plus a documented manual run.
  **Verify which lane applies before claiming a green suite.**
- No upstream PR. No force-push. No changes outside `core/openwrt`,
  `core/archipelago/src/api/rpc/openwrt.rs`, and `docs/`.

## 6. Commit sequence (one concern per commit)

1. `fix(openwrt): match the real package name and compare versions before install`
2. `feat(openwrt): pin TollGate to the v0.6.0 feed release with target-qualified assets`
3. `feat(openwrt): verify the package against the release SHA256SUMS`
4. `fix(openwrt): install jq and ca-bundle the package declares`
5. `feat(openwrt): report the installed TollGate version in get-status`
6. `docs(openwrt): correct the package name, arch guidance and verification steps`

Commit 1 lands first and alone: it is the regression fix, and reviewing it
separately is what makes the bump auditable.

## 7. Open decisions — operator only

| Decision | Why it is not mine |
|---|---|
| File the D2 (`br-lan`/`br-tollgate`) fix as its own card? | It changes enforcement behaviour on a live payment path; needs a router to verify. |
| Ship the bump without the E2E having run on hardware? | T7 is the acceptance. Without it the change is reasoned, not verified. |
| Upstream the T1/T2 fixes? | Andrey/lfg2025 own `main`. Deliberate act, needs your call. |
| Point `TOLLGATE_VERSION` at the feed release tag or at a resolved commit? | A tag is readable; a pinned commit is reproducible. The feed re-points its tag's assets only by re-releasing, but the choice should be written down. |
