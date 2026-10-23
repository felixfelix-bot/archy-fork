#!/usr/bin/env bash
# Verify the committed FIPS config fixtures still match the upstream tag.
#
# The fixtures under tests/fixtures/fips/ are verbatim copies of
# `packaging/common/fips.yaml` at a named upstream jmcorgan/fips tag. The
# contract tests in core/archipelago/src/fips/config_upstream_contract.rs
# assert our generated /etc/fips/fips.yaml against them — which only means
# something if the fixtures are real.
#
# Run this after bumping FIPS_VERSION, and in CI. Exits 1 on drift.
#
#   ./scripts/verify-fips-fixtures.sh            # check
#   ./scripts/verify-fips-fixtures.sh --update   # rewrite fixture + pin together
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/fips"
# Single source of truth for the pin: the ISO builder's FIPS_VERSION arg.
ISO_BUILDER="$REPO_ROOT/image-recipe/_archived/build-auto-installer-iso.sh"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

PIN="$(grep -oP '^ARG FIPS_VERSION=\K.*' "$ISO_BUILDER" | head -1 || true)"
if [ -z "$PIN" ]; then
    echo "FAIL: could not read ARG FIPS_VERSION from $ISO_BUILDER" >&2
    exit 1
fi
echo "pinned upstream tag: $PIN"

FIXTURE="$FIXTURE_DIR/fips-$PIN.yaml"
URL="https://raw.githubusercontent.com/jmcorgan/fips/$PIN/packaging/common/fips.yaml"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL --max-time 30 "$URL" -o "$tmp"; then
    echo "FAIL: could not fetch $URL" >&2
    exit 1
fi

remote_sha="$(sha256sum "$tmp" | awk '{print $1}')"

if [ "$UPDATE" = "1" ]; then
    mkdir -p "$FIXTURE_DIR"
    cp "$tmp" "$FIXTURE"
    echo "wrote $FIXTURE ($remote_sha)"
    exit 0
fi

if [ ! -f "$FIXTURE" ]; then
    echo "FAIL: fixture missing: $FIXTURE" >&2
    echo "      run: $0 --update" >&2
    exit 1
fi

local_sha="$(sha256sum "$FIXTURE" | awk '{print $1}')"
if [ "$local_sha" != "$remote_sha" ]; then
    echo "FAIL: fixture drift for $PIN" >&2
    echo "  committed: $local_sha  ($FIXTURE)" >&2
    echo "  upstream:  $remote_sha  ($URL)" >&2
    echo "  The upstream tag was re-tagged, or the fixture was hand-edited." >&2
    exit 1
fi

# Every other fixture must correspond to a tag we no longer pin — warn only,
# so an old fixture does not fail a build but does not rot silently either.
for f in "$FIXTURE_DIR"/fips-*.yaml; do
    [ -e "$f" ] || continue
    [ "$f" = "$FIXTURE" ] && continue
    echo "note: stale fixture kept for history: $(basename "$f")"
done

echo "OK: $FIXTURE matches upstream $PIN ($local_sha)"
