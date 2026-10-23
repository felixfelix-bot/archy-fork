# FIPS v0.5.3 bump — verification evidence

Recorded 2026-10-23 on x280 (7.7 GB RAM, 8 cores). Branch `pr/fips-bump-0.5.3`.

The point of this file is that a claim without observed output is not evidence.
Everything below is a command whose result was actually read.

## 1. Upstream state

```
$ gh api repos/jmcorgan/fips/releases --jq '.[] | "\(.tag_name) \(.published_at)"'
v0.5.3  2026-10-16T18:41:48Z   <- latest stable
v0.5.2  2026-09-29T00:16:16Z
v0.5.1  2026-09-06T20:31:54Z
v0.5.0  2026-08-30T15:05:57Z
v0.4.2  2026-08-25T11:42:37Z
v0.4.1  2026-07-19T18:46:36Z   <- was pinned
```

v0.5.3 still publishes `fips_0.5.3_amd64.deb`, `fips_0.5.3_arm64.deb` and
`checksums-linux.txt`, so the updater's asset matcher and SHA256 verification
path needed no change.

## 2. Fixture integrity

```
$ ./scripts/verify-fips-fixtures.sh
pinned upstream tag: v0.5.3
note: stale fixture kept for history: fips-v0.4.1.yaml
OK: tests/fixtures/fips/fips-v0.5.3.yaml matches upstream v0.5.3 \
    (98bb2fde87ef2a45a8c960a8a47943a0f25c9c42f66eb0aa60ac15d6caf50281)
```

Observed **RED before the bump** (`FAIL: fixture missing: fips-v0.4.1.yaml`,
exit 1, because the script reads the pin from the ISO builder and the fixture
did not exist for the old pin), then GREEN after. The script re-downloads the
upstream file, so a re-tagged release is caught rather than trusted.

```
$ ./scripts/gen-fips-schema.py --tag v0.5.3 --write
wrote tests/fixtures/fips/fips-v0.5.3-schema.txt (266 paths)
```

Re-running the extractor produces a byte-identical file (verified by `diff`),
so the fixture is reproducible rather than a one-off paste.

## 3. Compilation

```
$ CARGO_BUILD_JOBS=2 cargo check -p archipelago --bin archipelago --tests
Finished `dev` profile [unoptimized + debuginfo] target(s) in 3m 24s
```

Warnings only (17 pre-existing dead-code warnings in unrelated modules), no
errors. Three real errors were found and fixed first, all in this change:

- `use super::{service, UPSTREAM_REPO}` did not import
  `VERIFIED_UPSTREAM_VERSION` (`error[E0425]`, 3 sites).
- `include_str!` in `update.rs` had one `../` too many
  (`../../../../../image-recipe/...` vs `../../../../image-recipe/...`).

## 4. Tests

```
$ CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 CARGO_PROFILE_TEST_OPT_LEVEL=0 \
    cargo test -p archipelago --bin archipelago fips::
test result: ok. 72 passed; 0 failed; 0 ignored; 0 measured; 2018 filtered out
```

The 13 config/contract tests individually:

```
test fips::config::tests::test_rendered_yaml_exact_snapshot ... ok
test fips::config::tests::test_rendered_yaml_matches_upstream_schema ... ok
test fips::config::tests::test_install_refuses_when_key_missing ... ok
test fips::config::tests::test_lan_rendezvous_enabled_at_upstream_path ... ok
test fips::config::tests::test_render_is_deterministic ... ok
test fips::config_upstream_contract::fixture_is_a_real_upstream_config ... ok
test fips::config_upstream_contract::schema_fixture_covers_the_paths_we_own ... ok
test fips::config_upstream_contract::every_path_we_emit_is_valid_upstream ... ok
test fips::config_upstream_contract::we_no_longer_emit_the_deprecated_discovery_table ... ok
test fips::config_upstream_contract::the_three_phantom_keys_stay_deleted ... ok
test fips::config_upstream_contract::upstream_example_documents_the_new_split_tables ... ok
test fips::config_upstream_contract::tun_dns_and_transports_match_upstream_shape ... ok
test fips::config_upstream_contract::peer_list_shape_is_not_silently_wrong ... ok
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured; 2077 filtered out
```

Updater tests, including the new ceiling ones:

```
test fips::update::tests::test_verified_ceiling_matches_the_iso_pin ... ok
test fips::update::tests::test_cap_excludes_newer_releases ... ok
test fips::update::tests::test_version_sort_key_is_semantic ... ok
```

## 5. Mutation check — the tests actually bite

Passing tests prove nothing if they cannot fail. The phantom-key regression was
re-injected by hand (`node.lookup.max_attempts` added back to `LookupSection`
and its `Default` impl) and the suite re-run:

```
test fips::config_upstream_contract::the_three_phantom_keys_stay_deleted ... FAILED
test fips::config_upstream_contract::every_path_we_emit_is_valid_upstream ... FAILED

generated fips.yaml emits paths upstream v0.5.3 does not accept:
  ["node.lookup.max_attempts"]
test result: FAILED. 6 passed; 2 failed
```

Both the specific assertion and the general contract caught it, and the failure
message names the exact offending key path. The mutation was then reverted and
the tree confirmed identical to HEAD (`git diff --stat` empty).

## 6. Host constraint discovered during this work

The first two test attempts died with `exit code -9` (SIGKILL).

```
$ journalctl -k --since '20 min ago' | grep -i 'killed process'
Out of memory: Killed process 1303074 (rustc) total-vm:9688892kB,
  anon-rss:1395032kB ... oom_score_adj:100
```

Not a leak in this change: the box already had ~6.3 GB in use, partly by other
concurrent worktree builds. This repo sets `[profile.test] opt-level = 3`,
which makes the already-large test binary expensive to link. What worked:

```
CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 CARGO_PROFILE_TEST_OPT_LEVEL=0
```

`CARGO_PROFILE_TEST_OPT_LEVEL=0` is an environment override only — the repo's
`Cargo.toml` is unchanged, so CI is unaffected.

## 7. Not yet verified

- **ISO build.** `cmake`-free Docker build of the `.deb` at v0.5.3 and the
  rootfs were not run here. Layer caching means this is cheap, but it has not
  been observed.
- **Real node.** Unit tests prove the config is schema-valid. They do not prove
  the daemon starts with it, that the node re-peers after upgrade, or that the
  mesh returns. `fipsctl show peers` on a live node is still outstanding.
- **Android companion.** Out of scope by design — see ADR-012.
