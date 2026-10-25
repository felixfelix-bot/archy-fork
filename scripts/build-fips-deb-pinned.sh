#!/usr/bin/env bash
# Build the v0.4.1 .deb using the SAME recipe the ISO uses, so the upgrade test
# has a real old package to install rather than a hand-made approximation.
#
# ## Why this exists
#
# The upgrade rehearsal (`fips-upgrade-rehearsal.sh`) covers the CONFIG
# migration with the installed v0.5.3 binary. It explicitly does not cover a
# real package transition, because that needs the v0.4.1 .deb, which nobody had
# built.
#
# The stage is EXTRACTED from the ISO builder and the tag substituted, so the
# old package is produced by the same toolchain and same `cargo-deb` invocation
# that ships the new one. Building it by hand would make the test depend on a
# recipe that could differ from the product's.
#
# Usage: scripts/build-fips-deb-pinned.sh <tag> [--rebuild]
#   e.g. scripts/build-fips-deb-pinned.sh v0.4.1
#        scripts/build-fips-deb-pinned.sh v0.5.3
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_BUILDER="$REPO/image-recipe/_archived/build-auto-installer-iso.sh"
TAG="${1:?usage: build-fips-deb-pinned.sh <tag> [--rebuild]}"
[ -f "$ISO_BUILDER" ] || { echo "FAIL: ISO builder not found: $ISO_BUILDER" >&2; exit 1; }

WORK="$REPO/image-recipe/build/fips-deb-${TAG#v}"
DOCKERFILE="$WORK/Dockerfile.fips-stage"
mkdir -p "$WORK"

# Extract the stage verbatim, then substitute ONLY the pin, so the build recipe
# is byte-identical to the shipped one except for which tag it clones.
sed -n '/^FROM rust:1-slim-bookworm AS fips-builder$/,/^RUN cp target\/debian\/fips_.*\.deb \/tmp\/fips\.deb$/p' \
    "$ISO_BUILDER" > "$DOCKERFILE"

if ! grep -q "^ARG FIPS_VERSION=" "$DOCKERFILE"; then
    echo "FAIL: extracted stage has no ARG FIPS_VERSION — extraction broke" >&2
    exit 1
fi
sed -i "s|^ARG FIPS_VERSION=.*|ARG FIPS_VERSION=${TAG}|" "$DOCKERFILE"

echo "building $TAG from the ISO's own FIPS stage"
echo "  stage sha256: $(sha256sum "$DOCKERFILE" | cut -d' ' -f1)"
grep "^ARG FIPS_VERSION=" "$DOCKERFILE"

if command -v docker >/dev/null 2>&1; then RUNTIME=(docker)
elif command -v podman >/dev/null 2>&1; then RUNTIME=(podman)
else echo "FAIL: no container runtime" >&2; exit 1; fi

REGARGS=()
if [ "${RUNTIME[0]}" = podman ] && \
   ! grep -qE '^[[:space:]]*unqualified-search-registries[[:space:]]*=' \
        /etc/containers/registries.conf 2>/dev/null; then
    printf 'unqualified-search-registries = ["docker.io"]\n' > "$WORK/registries.conf"
    REGARGS=(--registries-conf="$WORK/registries.conf")
fi

IMAGE="archy-fips-deb:${TAG}"
"${RUNTIME[@]}" "${REGARGS[@]}" build --network=host -t "$IMAGE" -f "$DOCKERFILE" "$WORK"

CID="$("${RUNTIME[@]}" "${REGARGS[@]}" create "$IMAGE" true)"
trap '"${RUNTIME[@]}" "${REGARGS[@]}" rm -f "$CID" >/dev/null 2>&1 || true' EXIT
OUT="$WORK/fips-${TAG}.deb"
rm -f "$OUT"
"${RUNTIME[@]}" "${REGARGS[@]}" cp "$CID:/tmp/fips.deb" "$OUT"

[ -s "$OUT" ] || { echo "FAIL: empty .deb" >&2; exit 1; }
echo
echo "package: $(dpkg-deb -f "$OUT" Package) $(dpkg-deb -f "$OUT" Version)  ($TAG)"
echo "sha256:  $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "path:    $OUT"
