# Bumping the pinned FIPS daemon

The daemon version is pinned in **two** places that must never disagree:

| Where | What | Why |
|---|---|---|
| `image-recipe/_archived/build-auto-installer-iso.sh` | `ARG FIPS_VERSION` | what the ISO builds and ships |
| `core/archipelago/src/fips/mod.rs` | `VERIFIED_UPSTREAM_VERSION` | ceiling the runtime updater will offer |

A test (`fips::update::tests::test_verified_ceiling_matches_the_iso_pin`) fails
if they drift, so this is enforced, not merely documented.

## Why the bump is not just a version string

`fips::config` renders `/etc/fips/fips.yaml` from typed structs. If upstream
renames or removes a key, one of two things happens and **neither fails loudly
at the point of change**:

- the struct drops unknown keys silently (many upstream config structs have no
  `deny_unknown_fields`) → the setting stops applying and nobody notices;
- upstream tightens validation (from v0.5.3 the daemon refuses to start on a
  config that configures nothing) → the node falls off the mesh after upgrade.

This has already happened once. Archipelago emitted
`node.discovery.{timeout_secs, retry_interval_secs, max_attempts}` for months;
none of those keys exists in any upstream release, so every daemon ignored them
and the tuning never took effect. See ADR-012.

## Checklist

### 1. Establish the target and read upstream's changes

```bash
gh api repos/jmcorgan/fips/releases --jq '.[] | "\(.tag_name) \(.published_at)"'
gh api repos/jmcorgan/fips/releases/latest --jq '.tag_name'
```

Read the changelog for **every** release between the current pin and the
target, not just the newest:

```bash
git -C ~/repos/fips-upstream show <tag>:CHANGELOG.md
```

Look specifically for: config table renames, removed/renamed struct fields,
newly-required keys, systemd unit changes, TUN interface renames, config or key
path changes, and new build dependencies. Grep the diff for the tables we own:

```bash
git -C ~/repos/fips-upstream diff <old>..<new> -- src/config/ src/upper/config.rs
git -C ~/repos/fips-upstream diff <old>..<new> -- packaging/
```

### 2. Move the pin

```bash
# image-recipe/_archived/build-auto-installer-iso.sh
ARG FIPS_VERSION=<new-tag>

# core/archipelago/src/fips/mod.rs
pub const VERIFIED_UPSTREAM_VERSION: &str = "<new-version>";   # no leading 'v'
```

### 3. Refresh both fixtures

```bash
./scripts/verify-fips-fixtures.sh --update     # re-fetch the upstream example
./scripts/gen-fips-schema.py --tag <new-tag> --write
```

`verify-fips-fixtures.sh` re-downloads `packaging/common/fips.yaml` at the pin
and fails on drift, so a re-tagged release is caught rather than trusted.

> The example alone is **not** the schema. It documents roughly a third of it —
> it does not mention `node.retry.*` or `node.rate_limit.*`, both of which we
> set. `gen-fips-schema.py` extracts the real key-path set from upstream's
> `#[derive(Deserialize)]` structs, which is the authority.

### 4. Update `fips/config.rs` to match

Edit the typed structs and the `Default` impl. Then update the exact-output
snapshot in `fips::config::tests::test_rendered_yaml_exact_snapshot` — and
re-verify each changed key against `fips-<tag>-schema.txt` before pasting a new
expected string, because that test only proves the output is *stable*, not that
it is *correct*. The contract module is what proves correctness.

### 5. Run the gates

```bash
# Compile first — cheaper than a full test build on a small host.
CARGO_BUILD_JOBS=2 cargo check -p archipelago --bin archipelago --tests

# Then the FIPS tests. The crate is BIN-ONLY (no [lib]), so --lib fails;
# use --bin. On a 7 GB host the default job count OOMs the cold build.
CARGO_BUILD_JOBS=2 cargo test -p archipelago --bin archipelago fips
```

All of `fips::config_upstream_contract`, `fips::config::tests` and
`fips::update::tests` must pass. A failure in
`every_path_we_emit_is_valid_upstream` names the exact offending key path.

### 6. Build the ISO and test on a real node

The unit tests prove the config is *schema-valid*. They do not prove the daemon
*starts* with it, that the node re-peers, or that the mesh comes back. Build the
ISO and bring up a node; confirm `fipsctl show peers` and that the node is
reachable over the mesh before calling the bump done.

### 7. Push and mirror

Public repo ⇒ push to **both** GitHub and ngit on the default branch
(`fleet-git-hygiene`). Branch name must be `pr/<slug>`.

## What is deliberately not covered

**The Android companion.** It pins `fips` as a *library* at a personal fork
(`Zazawowow/fips-native@07d21d44`, which is upstream `46494a74` plus patches)
and calls `Node::start_with_tun_fd` — a method that **exists at no upstream
tag**. Upstream v0.5.0 added `Node::enable_app_owned_tun()` as the supported
embedder API (channel-pair exchange instead of passing a raw fd), and
`NodeConfig.discovery` is `pub(crate)` upstream, so `cfg.node.discovery.*` will
not compile against it. Moving the app to upstream is an **API port**, not a
version bump, and belongs in its own change.

**`peers[]` static entries.** `PeerEntry` (`{npub, address, transport}`) is not
a valid upstream `PeerConfig` (`{npub, alias?, addresses: [{transport, addr,
priority?}]}`). The list is always empty because archipelago feeds peers
dynamically, and a contract test asserts it *stays* empty — so a wrong shape
cannot ship unnoticed if static peering is ever wired up. Rewrite the struct as
part of that work.
