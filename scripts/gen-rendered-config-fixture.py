#!/usr/bin/env python3
"""Extract archipelago's rendered fips.yaml from the Rust exact-output snapshot.

The live smoke test (`scripts/fips-live-smoke.sh`) must feed the daemon the bytes
the application actually writes. Copying them by hand is the failure mode this
avoids: a hand-copied config can agree with the test while disagreeing with the
product, and the test then certifies a file nothing ships.

`fips/config.rs` already pins the exact rendering in `test_rendered_yaml_exact_snapshot`,
so that string literal IS the artifact of record. This reads it out of the source
instead of duplicating it, which also means the fixture cannot drift: if the
snapshot changes, the fixture goes stale visibly and `--check` fails.

Usage:
    scripts/gen-rendered-config-fixture.py [--write] [--check]

  --write   (re)write tests/fixtures/fips/archipelago-rendered.yaml
  --check   exit 1 if the fixture is missing or differs from the snapshot
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CONFIG_RS = REPO / "core/archipelago/src/fips/config.rs"
FIXTURE = REPO / "tests/fixtures/fips/archipelago-rendered.yaml"

# The snapshot is a Rust string literal introduced by `let expected = "\` and
# terminated by the first unescaped `";` on its own line indentation.
SNAPSHOT_RE = re.compile(
    r'fn test_rendered_yaml_exact_snapshot\(\)\s*\{\s*let expected = "\\\n(.*?)";\n',
    re.S,
)


def extract() -> str:
    src = CONFIG_RS.read_text(encoding="utf-8")
    m = SNAPSHOT_RE.search(src)
    if not m:
        raise SystemExit(
            f"FAIL: could not find the exact-output snapshot in {CONFIG_RS}.\n"
            "      If the test was renamed or its literal form changed, update\n"
            "      SNAPSHOT_RE here rather than pasting the config by hand."
        )
    body = m.group(1)
    # Rust literal escapes: only backslash and double-quote can appear in a YAML
    # rendering of this struct. Anything else would be a surprise worth failing on.
    if re.search(r'\\[^"\\]', body):
        bad = re.search(r'\\[^"\\]', body)
        raise SystemExit(f"FAIL: unexpected escape sequence in snapshot: {bad!r}")
    return body.replace('\\"', '"').replace("\\\\", "\\")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    yaml = extract()

    # Cheap structural guards: an empty or truncated extraction would otherwise
    # produce a "rendered config" that trivially fails to boot and look like a
    # daemon problem.
    for required in ("node:", "lookup:", "rendezvous:", "retry:", "rate_limit:",
                     "tun:", "dns:", "transports:", "peers:"):
        if f"{required}" not in yaml:
            raise SystemExit(f"FAIL: extracted config is missing '{required}'")
    if "discovery" in yaml:
        raise SystemExit(
            "FAIL: extracted config still contains 'discovery' — the pre-v0.5.0\n"
            "      key path this bump removed. Regenerate only after config.rs is fixed."
        )

    if args.check:
        if not FIXTURE.is_file():
            print(f"FAIL: fixture missing: {FIXTURE}", file=sys.stderr)
            return 1
        current = FIXTURE.read_text(encoding="utf-8")
        if current != yaml:
            print(
                f"FAIL: {FIXTURE} differs from the config.rs snapshot.\n"
                "      Run with --write to regenerate.",
                file=sys.stderr,
            )
            return 1
        print(f"OK: fixture matches the config.rs snapshot ({len(yaml)} bytes)")
        return 0

    if args.write:
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_text(yaml, encoding="utf-8")
        print(f"wrote {FIXTURE.relative_to(REPO)} ({len(yaml)} bytes)")
        return 0

    sys.stdout.write(yaml)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
