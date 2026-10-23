# ADR-012: Pin the FIPS Daemon and Cap the Runtime Updater

## Status

Proposed

## Context

Archipelago embeds [FIPS](https://github.com/jmcorgan/fips) as its preferred
non-Tor mesh transport. The daemon is installed two ways, and until now the two
disagreed about which version the node runs:

- **Image build** — `image-recipe/_archived/build-auto-installer-iso.sh` cloned
  upstream at `ARG FIPS_VERSION=v0.4.1`, built a `.deb`, and baked it into the
  rootfs.
- **Runtime** — `core/archipelago/src/fips/update.rs` queried
  `/repos/jmcorgan/fips/releases/latest`, SHA256-verified the arch-matched
  `.deb`, and `dpkg -i`'d it. No ceiling.

That split produced a documentation claim we could not keep. `fips/config.rs`
said its typed schema was *"verified field-by-field against jmcorgan/fips
v0.4.1"*. The claim was already false in three specific ways and was about to
become more broadly false:

1. The module emitted `node.discovery.timeout_secs`,
   `node.discovery.retry_interval_secs` and `node.discovery.max_attempts`.
   **None of those keys exist in any upstream release.** `DiscoveryConfig`
   carries no `deny_unknown_fields`, so every daemon silently ignored them. The
   "fail fast lookup" tuning those fields were written to apply — 5 s timeout,
   3 attempts, 2 s retry — has never taken effect on any shipped node. Nobody
   noticed, because nothing failed.
2. Upstream **v0.5.0** split the overloaded `node.discovery.*` table into
   `node.lookup.*` (mesh-lookup scalars) and `node.rendezvous.*` (nostr + LAN
   peer rendezvous). A legacy block still folds via `DiscoveryConfigCompat`, but
   with a deprecation warning on every start that an operator cannot clear.
3. Upstream **v0.5.3** made the daemon refuse to start when its config
   configures nothing. A config that loses its real settings to a rename now
   fails at boot rather than degrading.

Meanwhile any operator who pressed "Update" was already running v0.5.3 against a
config generated for v0.4.1 — a version nobody had verified.

## Decision

1. **The image pin and the runtime updater share one ceiling.**
   `fips::VERIFIED_UPSTREAM_VERSION` names the newest upstream release whose
   schema this build is verified against. `update::check()` and
   `update::apply()` both resolve releases against it; neither can install or
   offer a version above it. `check()` says so explicitly when newer upstream
   exists, so a stale cap is visible instead of masquerading as "up to date".
2. **The pin moves only with its evidence.** A bump is complete when, together:
   the ISO `ARG FIPS_VERSION` changes, `render_config_yaml()` matches the new
   schema, the verbatim upstream fixtures are refreshed, and the contract tests
   pass. `scripts/verify-fips-fixtures.sh` re-downloads the upstream example at
   the pinned tag and fails on drift; `scripts/gen-fips-schema.py` re-extracts
   the valid key paths from upstream's `Deserialize` structs.
3. **A schema claim is carried by a test, not a comment.**
   `fips::config_upstream_contract` asserts every path the generated config
   emits exists in the upstream schema at the pinned tag, and that the three
   phantom keys and the deprecated table stay gone. Upstream's own
   `fips.yaml` example documents only about a third of the schema — it does not
   mention `node.retry.*` or `node.rate_limit.*`, both of which we set — so the
   authority is the source structs, not the example text. The example is still
   kept as a fixture, because it proves we read a real upstream artefact.
4. **The shipped version is v0.5.3.** The ISO pin moves from v0.4.1 to v0.5.3.
5. **One supervisor for the daemon.** `archipelago-fips.service` declares
   `Conflicts=fips.service`. Both units run the same binary against the same
   config and bind the same TUN, UDP 8668 and TCP 8443; previously whichever
   started first won and the loser crash-looped while `fips.status` reported a
   red service with a daemon demonstrably running.

## Consequences

- An updating node can no longer leave the verified config surface. Adopting a
  new upstream release becomes a deliberate act with a checklist, not a side
  effect of somebody clicking Update.
- **A node on v0.5.3 stops receiving updates until the cap is bumped.** That is
  the intent, but it means the cap is now maintenance debt: leaving it stale
  blocks legitimate upstream fixes. `check()` surfaces the newer release in its
  notes so the debt is visible from the dashboard.
- The Android companion is **not** covered by this ADR and is not bumped here.
  It pins `fips` as a library at a personal fork
  (`Zazawowow/fips-native@07d21d44`, upstream `46494a74` + patches) and calls
  `Node::start_with_tun_fd`, which **exists at no upstream tag**. v0.5.0 added
  `Node::enable_app_owned_tun()` as the supported embedder API, so moving to
  upstream is an API port, not a version bump, and needs its own change.
- `node.discovery.*`-era tuning is now honestly absent rather than silently
  absent. Where the old fields were meant to make lookups fail fast, upstream's
  `node.lookup.attempt_timeouts_secs` sequence (`[1, 2, 4, 8]`) is the real
  control. Overriding it changes failure semantics and needs a field
  measurement, so it is left at upstream's default deliberately.
- `PeerEntry` (`peers[].{npub, address, transport}`) is still not a valid
  upstream `PeerConfig` shape. The list is always empty — archipelago feeds
  peers dynamically — so nothing breaks today. A contract test asserts it stays
  empty rather than letting a wrong shape ship if static peering is ever wired.
