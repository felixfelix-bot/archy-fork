# Pre-existing test failures on `main` (not caused by this branch)

Recorded 2026-10-23 while validating `pr/fips-bump-0.5.3`.

The full `archipelago` bin test suite reports **9 failures**. This file exists
so the next person does not have to re-derive whether they are ours. They are
not.

## Evidence

Same command, same host, same day — once on the branch, once on pristine `main`
at `fcc18b3` in a separate checkout with its own target dir:

```
CARGO_BUILD_JOBS=1 CARGO_INCREMENTAL=0 CARGO_PROFILE_TEST_OPT_LEVEL=0 \
  cargo test -p archipelago --bin archipelago
```

| Test | On branch | On pristine main |
|---|---|---|
| `bootstrap::tests::executable_sync_replaces_stale_payload_and_repairs_mode_idempotently` | FAILED | **FAILED** |
| `container::boot_reconciler::tests::second_pass_fires_after_interval` | FAILED | **ok** (flaky) |
| `container::prod_orchestrator::tests::install_applies_data_uid_chown_before_create` | FAILED | **FAILED** |
| `container::prod_orchestrator::tests::install_resolves_derived_and_secret_env_before_create` | FAILED | **FAILED** |
| `container::quadlet::tests::actual_quadlet_generator_stops_before_forced_removal` | FAILED | **FAILED** |
| `container::supervised_runtime::tests::api_and_relay_overrides_cannot_borrow_each_others_obligation` | FAILED | **FAILED** |
| `container::supervised_runtime::tests::only_exact_active_api_restart_override_is_owned` | FAILED | **FAILED** |
| `container::supervised_runtime::tests::restart_override_refuses_tamper_symlink_and_writable_ownership_paths` | FAILED | **FAILED** |
| `wallet::ecash::payment_tests::process_fixture::committed_settlement_reply_loss_recovers_after_both_processes_restart` | FAILED | **FAILED** |

8 of 9 reproduce identically on unmodified `main`. The ninth
(`boot_reconciler::second_pass_fires_after_interval`) is **timing-dependent** —
it asserts `left: 0, right: 1` on a tick count and passes on an unloaded host —
i.e. flaky under load, not order-dependent on this diff.

## Why these are not this branch's doing

`git diff --name-only fcc18b3..HEAD` touches only:

```
core/archipelago/src/fips/config.rs
core/archipelago/src/fips/config_upstream_contract.rs
core/archipelago/src/fips/mod.rs
core/archipelago/src/fips/update.rs
docs/adr/012-*.md, docs/fips-*.md
image-recipe/_archived/build-auto-installer-iso.sh
image-recipe/configs/archipelago-fips.service
scripts/gen-fips-schema.py, scripts/verify-fips-fixtures.sh
tests/fixtures/fips/*
PROGRESS.md
```

No `container/`, `wallet/` or `bootstrap` file appears. Checking for indirect
coupling, `grep -c fips` over each failing module returns 0, except
`bootstrap.rs` where the single hit is a **comment** (`// Companion mesh access:
phones reach this node over FIPS at its fips0`), not code.

The failing tests are filesystem-ownership and process-supervision assertions
(`chown`, symlink tamper checks, forced removal, process restart), which are
exactly the kind that fail when run with unexpected privileges or a shared
target directory — see this repo's `AGENTS.md` warning against running
`cargo test` unrestricted on a node with installed apps.

## FIPS suite is green

The scoped run that matters for this change:

```
$ cargo test -p archipelago --bin archipelago fips::
test result: ok. 72 passed; 0 failed; 0 ignored; 0 measured; 2018 filtered out
```

## Action

These 9 belong in their own issue. They are out of scope for a version bump and
were **not** touched, worked around, or silenced here.
