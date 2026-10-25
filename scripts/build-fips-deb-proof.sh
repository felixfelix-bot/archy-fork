#!/usr/bin/env bash
# Build the FIPS daemon .deb EXACTLY the way the installer ISO builds it, and
# assert the shipped package carries the version we pinned.
#
# ## Why this exists
#
# The ISO builder (`image-recipe/_archived/build-auto-installer-iso.sh`) builds
# FIPS in a Docker/Podman stage, so "the bump compiles" and "the ISO ships the
# bumped daemon" are two different claims. `cargo test` proves the first. This
# script proves the second without needing a full ISO build (debootstrap,
# mksquashfs, xorriso, grub), which is slow and needs root.
#
# The stage is EXTRACTED from the ISO builder, never retyped: a hand-copied
# Dockerfile silently drifts from the real one, and then this proof verifies a
# package the ISO would never build. Extraction is anchored on the stage's FROM
# line and its final `cp ... /tmp/fips.deb`, so an edit to either end breaks
# loudly instead of quietly skipping the daemon.
#
# ## Usage
#
#   scripts/build-fips-deb-proof.sh [--rebuild] [--keep]
#
# Exit 0 only if the .deb exists, its Debian version matches the pinned
# FIPS_VERSION, and it contains /usr/bin/fips.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_BUILDER="$REPO/image-recipe/_archived/build-auto-installer-iso.sh"
# Scratch only. image-recipe/build/ is gitignored, which is correct for build
# output -- the harness itself lives here, in tracked scripts/.
WORK="$REPO/image-recipe/build/fips-deb-proof"
DOCKERFILE="$WORK/Dockerfile.fips-stage"

[ -f "$ISO_BUILDER" ] || { echo "FAIL: ISO builder not found: $ISO_BUILDER" >&2; exit 1; }

mkdir -p "$WORK"

# ── 1. Pin ────────────────────────────────────────────────────────────────
# Single source of truth for what the ISO ships.
PIN="$(grep -oP '^ARG FIPS_VERSION=\K.*' "$ISO_BUILDER" | head -1 || true)"
[ -n "$PIN" ] || { echo "FAIL: could not read ARG FIPS_VERSION from $ISO_BUILDER" >&2; exit 1; }
echo "pinned FIPS_VERSION: $PIN"

# ── 2. Extract the stage verbatim ─────────────────────────────────────────
if [ ! -f "$DOCKERFILE" ] || [ "${1:-}" = "--rebuild" ]; then
    sed -n '/^FROM rust:1-slim-bookworm AS fips-builder$/,/^RUN cp target\/debian\/fips_.*\.deb \/tmp\/fips\.deb$/p' \
        "$ISO_BUILDER" > "$DOCKERFILE"
    LINES=$(wc -l < "$DOCKERFILE")
    # A truncated extraction is the silent-failure mode here: it would build a
    # half-stage or an empty Dockerfile and report a package that proves nothing.
    [ "$LINES" -ge 10 ] || { echo "FAIL: extracted stage looks truncated ($LINES lines)" >&2; exit 1; }
    grep -q "^FROM rust:1-slim-bookworm AS fips-builder$" "$DOCKERFILE" || {
        echo "FAIL: extracted stage has no builder FROM line" >&2; exit 1; }
    grep -q "^RUN cp target/debian/fips_" "$DOCKERFILE" || {
        echo "FAIL: extracted stage has no .deb copy step" >&2; exit 1; }
    echo "extracted stage: $LINES lines, sha256 $(sha256sum "$DOCKERFILE" | cut -d' ' -f1)"
fi

# ── 3. Container runtime ──────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    RUNTIME=(docker)
elif command -v podman >/dev/null 2>&1; then
    RUNTIME=(podman)
else
    echo "FAIL: neither docker nor podman is installed" >&2; exit 1
fi

# The ISO Dockerfile writes unqualified base images (`FROM rust:1-slim-bookworm`),
# which need a search registry. Hosts that ship that line commented out fail with
# "short-name ... did not resolve to an alias". Supply a scratch config for this
# build only -- never edit /etc/containers, and never rewrite the Dockerfile,
# which must stay byte-identical to what the ISO runs.
REGARGS=()
if [ "${RUNTIME[0]}" = podman ]; then
    if ! grep -qE '^[[:space:]]*unqualified-search-registries[[:space:]]*=' \
            /etc/containers/registries.conf 2>/dev/null; then
        # v2 keys only: podman refuses a file that also carries v1
        # [registries.search], which is an easy and very confusing mistake.
        printf 'unqualified-search-registries = ["docker.io"]\n' > "$WORK/registries.conf"
        REGARGS=(--registries-conf="$WORK/registries.conf")
        echo "note: host registries.conf has no unqualified search registries; using scratch config"
    fi
fi

# ── 4. Build ──────────────────────────────────────────────────────────────
TAG="archy-fips-deb:${PIN}"
echo "building $TAG from the extracted stage (this is a cold Rust build)"
"${RUNTIME[@]}" "${REGARGS[@]}" build --network=host -t "$TAG" -f "$DOCKERFILE" "$WORK"

# ── 5. Extract the .deb ───────────────────────────────────────────────────
CID="$("${RUNTIME[@]}" "${REGARGS[@]}" create "$TAG" true)"
trap '"${RUNTIME[@]}" "${REGARGS[@]}" rm -f "$CID" >/dev/null 2>&1 || true' EXIT
DEB_HOST="$WORK/fips-${PIN}.deb"
rm -f "$DEB_HOST"
"${RUNTIME[@]}" "${REGARGS[@]}" cp "$CID:/tmp/fips.deb" "$DEB_HOST"

[ -s "$DEB_HOST" ] || { echo "FAIL: extracted .deb is empty" >&2; exit 1; }

# ── 6. Assert the shipped artifact ────────────────────────────────────────
echo
echo "── assertions ──"
echo "file:   $DEB_HOST"
echo "sha256: $(sha256sum "$DEB_HOST" | cut -d' ' -f1)"
echo "size:   $(stat -c%s "$DEB_HOST") bytes"

DEB_VERSION="$(dpkg-deb -f "$DEB_HOST" Version)"
DEB_PKG="$(dpkg-deb -f "$DEB_HOST" Package)"
echo "package: $DEB_PKG"
echo "version: $DEB_VERSION"

# The pin carries a leading `v`; the Debian version does not.
EXPECT="${PIN#v}"
FAILED=0
[ "$DEB_PKG" = "fips" ] || { echo "FAIL: package name is '$DEB_PKG', expected 'fips'" >&2; FAILED=1; }
case "$DEB_VERSION" in
    "$EXPECT"|"$EXPECT"-*|"$EXPECT"~*) echo "OK: version matches pin $PIN" ;;
    *) echo "FAIL: version '$DEB_VERSION' does not match pinned '$EXPECT'" >&2; FAILED=1 ;;
esac

# Contents: the ISO installs this .deb and then runs /usr/bin/fips. A package
# that unpacks without the daemon binary would pass a version check and ship a
# node with no mesh.
CONTENTS="$(dpkg-deb -c "$DEB_HOST")"
for want in ./usr/bin/fips ./usr/bin/fipsctl; do
    if grep -q " $want\$" <<<"$CONTENTS"; then
        echo "OK: contains $want"
    else
        echo "FAIL: package does not contain $want" >&2; FAILED=1
    fi
done

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL -- the ISO would ship a package that does not match the pin"
    exit 1
fi
echo "RESULT: PASS -- ISO-shipped FIPS package is $DEB_PKG $DEB_VERSION at pin $PIN"
echo "artifact kept at: $DEB_HOST"
