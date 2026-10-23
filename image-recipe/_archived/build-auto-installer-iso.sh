#!/bin/bash
#
# Build Archipelago Auto-Installer ISO (StartOS-like)
# 
# This creates an ISO that automatically installs to the internal disk
# with minimal user interaction - similar to StartOS experience.
#
# CRITICAL: This script CAPTURES the LIVE SERVER state by default.
# Set DEV_SERVER to point to your development server.
#
# Usage: 
#   DEV_SERVER=archipelago@192.0.2.10 ./build-auto-installer-iso.sh
#   OR just: ./build-auto-installer-iso.sh (uses default server)
#
# To build from source instead:
#   BUILD_FROM_SOURCE=1 ./build-auto-installer-iso.sh
#
# Features:
# - Pre-built root filesystem (no network needed during install)
# - Auto-detects internal disk (skips USB boot drive)
# - Automatic installation with progress display
# - Boots directly to web UI after install
#
# Image versions: sourced from scripts/image-versions.sh (single source of truth).
# All container image references MUST use the $*_IMAGE variables defined there.
#
# --- PLANNED REFACTOR (post-beta) ---
# This script is ~1870 lines and should be split into a modular library.
# Proposed structure:
#   image-recipe/
#     build-auto-installer-iso.sh   — Main orchestrator (config, CLI args, step sequencing)
#     lib/
#       rootfs.sh                   — Step 1: Build root filesystem via Docker (~185 lines)
#       installer-env.sh            — Step 2: Build minimal installer via debootstrap (~80 lines)
#       components.sh               — Step 3: Add Archipelago components (binary, configs, web UI) (~120 lines)
#       container-images.sh         — Step 3b: Bundle container images for offline install (~330 lines)
#       auto-install-script.sh      — Step 4: Generate the embedded auto-install.sh (~615 lines)
#       boot-config.sh              — Step 5: Configure live boot auto-start + overlay squashfs (~215 lines)
#       create-iso.sh               — Step 6: Build final bootable ISO with xorriso/grub (~140 lines)
# Each lib/ script exports functions; main script sources them and calls in sequence.
# DO NOT split until tested on the build server — this is critical infrastructure.
# ---
#

set -e

# Source pinned image versions (single source of truth)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/../../scripts/image-versions.sh" ] && . "$SCRIPT_DIR/../../scripts/image-versions.sh"

# Configuration
DEV_SERVER="${DEV_SERVER:-archipelago@192.0.2.10}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
UNBUNDLED="${UNBUNDLED:-0}"
ARCH="${ARCH:-x86_64}"

# ── Sequential build numbering ─────────────────────────────────────────
# Increments on each build. Users see this in UI (Settings, sidebar).
# Counter persists in /opt/archipelago/build-counter (on build machine).
BUILD_COUNTER_FILE="/opt/archipelago/build-counter"
if [ -f "$BUILD_COUNTER_FILE" ]; then
    BUILD_NUM=$(( $(cat "$BUILD_COUNTER_FILE") + 1 ))
else
    BUILD_NUM=1
fi
echo "$BUILD_NUM" | sudo tee "$BUILD_COUNTER_FILE" > /dev/null 2>/dev/null || BUILD_NUM=1
GIT_SHORT=$(cd "$SCRIPT_DIR/.." && git rev-parse --short HEAD 2>/dev/null || echo "dev")
# Version format: major.minor.patch-prerelease (semver)
# Read version from Cargo.toml (single source of truth)
BUILD_VERSION=$(grep '^version' "$SCRIPT_DIR/../../core/archipelago/Cargo.toml" 2>/dev/null | head -1 | sed 's/version = "//;s/"//' || echo "0.0.0")
echo "Build #${BUILD_NUM} (${BUILD_VERSION}, commit ${GIT_SHORT})"

# Architecture-dependent variables
case "$ARCH" in
    x86_64|amd64)
        ARCH="x86_64"
        DEB_ARCH="amd64"
        LINUX_IMAGE_PKG="linux-image-amd64"
        GRUB_EFI_PKG="grub-efi-amd64"
        GRUB_EFI_SIGNED_PKG="grub-efi-amd64-signed"
        GRUB_PC_PKG="grub-pc-bin"
        GRUB_TARGET="x86_64-efi"
        GRUB_BIOS_TARGET="i386-pc"
        CONTAINER_PLATFORM="linux/amd64"
        LIB_DIR="${LIB_DIR}"
        ;;
    arm64|aarch64)
        ARCH="arm64"
        DEB_ARCH="arm64"
        LINUX_IMAGE_PKG="linux-image-arm64"
        GRUB_EFI_PKG="grub-efi-arm64"
        GRUB_EFI_SIGNED_PKG="grub-efi-arm64-signed"
        GRUB_PC_PKG=""
        GRUB_TARGET="arm64-efi"
        GRUB_BIOS_TARGET=""
        CONTAINER_PLATFORM="linux/arm64"
        LIB_DIR="aarch64-linux-gnu"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH (use x86_64 or arm64)"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$SCRIPT_DIR/build/auto-installer"
OUTPUT_DIR="$SCRIPT_DIR/results"
ROOTFS_DIR="$WORK_DIR/rootfs"
INSTALLER_DIR="$WORK_DIR/installer"

if [ "$UNBUNDLED" = "1" ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Building Archipelago UNBUNDLED ISO (no pre-loaded apps)      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
else
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Building Archipelago Auto-Installer ISO (StartOS-like)       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
fi
echo ""
if [ "$BUILD_FROM_SOURCE" = "1" ]; then
    echo "📦 Mode: Building from SOURCE CODE"
elif [ "$UNBUNDLED" = "1" ]; then
    echo "📦 Mode: UNBUNDLED (apps downloaded on-demand from Marketplace)"
    echo "   Server: $DEV_SERVER (backend + web UI only)"
else
    echo "📦 Mode: Capturing LIVE SERVER state"
    echo "   Server: $DEV_SERVER"
fi
echo "🏗️  Architecture: $ARCH ($DEB_ARCH)"
echo ""

# Check for required tools
check_tools() {
    local missing=""
    local can_install=false
    
    # Check if we can auto-install (running as root on Debian/Ubuntu)
    if [ "$EUID" -eq 0 ] && [ -f /etc/debian_version ]; then
        can_install=true
    fi
    
    # Check for docker or podman
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    else
        missing="$missing docker-or-podman"
    fi
    
    for tool in xorriso mksquashfs; do
        if ! command -v $tool >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    # Check for isolinux MBR (needed for hybrid USB boot)
    if [ ! -f /usr/lib/ISOLINUX/isohdpfx.bin ] && [ ! -f /usr/share/syslinux/isohdpfx.bin ]; then
        missing="$missing isolinux"
    fi

    if [ -n "$missing" ]; then
        echo "Missing required tools:$missing"

        if [ "$can_install" = true ]; then
            echo "   Auto-installing missing dependencies..."
            apt-get update -qq

            if [[ "$missing" == *"xorriso"* ]]; then
                apt-get install -y xorriso
            fi
            if [[ "$missing" == *"mksquashfs"* ]]; then
                apt-get install -y squashfs-tools
            fi
            if [[ "$missing" == *"isolinux"* ]]; then
                apt-get install -y isolinux syslinux-common
            fi

            if [[ "$missing" == *"docker-or-podman"* ]]; then
                echo "   Installing podman..."
                apt-get install -y podman
                CONTAINER_CMD="podman"
            fi

            echo "   Dependencies installed successfully!"
        else
            echo "   Install with: sudo apt install xorriso squashfs-tools isolinux podman"
            echo "   Or run this script with sudo to auto-install"
            exit 1
        fi
    fi
    
    # Re-check after potential installation
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    else
        echo "❌ Container runtime still not available after installation"
        exit 1
    fi
    
    echo "Using container runtime: $CONTAINER_CMD"

    # Fix root podman D-Bus issue (sd-bus: Transport endpoint is not connected)
    # When running as sudo, systemd cgroup manager can't reach the user D-Bus session.
    if [ "$CONTAINER_CMD" = "podman" ] && [ "$(id -u)" = "0" ]; then
        if ! $CONTAINER_CMD run --rm debian:trixie true 2>/dev/null; then
            echo "   Root podman D-Bus issue detected, using cgroupfs manager"
            CONTAINER_CMD="podman --cgroup-manager=cgroupfs"
        fi
    fi

    # Ensure insecure registry config for Archipelago app registries that are
    # intentionally served over HTTP during ISO builds. Rootless podman reads
    # the per-user config dir; only root can write /etc. Never fatal — the
    # node may already carry this config.
    if [[ "$CONTAINER_CMD" == podman* ]]; then
        if [ "$(id -u)" = "0" ]; then
            REGCONF_DIR="/etc/containers/registries.conf.d"
        else
            REGCONF_DIR="${HOME}/.config/containers/registries.conf.d"
        fi
        if mkdir -p "$REGCONF_DIR" 2>/dev/null && cat > "$REGCONF_DIR/archipelago.conf" 2>/dev/null <<'REGCONF'
[[registry]]
location = "source.archipelago-foundation.org"
insecure = true
REGCONF
        then
            :
        else
            echo "   ⚠️  Could not write $REGCONF_DIR/archipelago.conf — assuming registry config already present"
        fi
    fi
}

check_tools

mkdir -p "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

container_pull() {
    local image="$1"
    if [[ "$CONTAINER_CMD" == podman* && "$image" == source.archipelago-foundation.org/* ]]; then
        $CONTAINER_CMD pull --tls-verify=false --platform "$CONTAINER_PLATFORM" "$image"
    else
        $CONTAINER_CMD pull --platform "$CONTAINER_PLATFORM" "$image"
    fi
}

# =============================================================================
# STEP 1: Build complete root filesystem using Docker
# =============================================================================
echo "📦 Step 1: Building root filesystem..."

ROOTFS_TAR="$WORK_DIR/archipelago-rootfs.tar"
ROOTFS_STAMP="$WORK_DIR/archipelago-rootfs.recipe.sha256"

# The cached rootfs must be invalidated when its recipe changes: a stale
# archipelago-rootfs.tar on the build machine shipped ISOs with NO
# wpasupplicant/iw/rfkill (WiFi dead on laptops) long after those packages
# were added to the Dockerfile below — the cache condition never looked at
# the recipe. Hash the rootfs-defining region of this script; any edit to it
# forces a rebuild. `--rebuild` still forces one unconditionally.
RECIPE_HASH=$(
    {
        sed -n '/^# STEP 1: Build complete root filesystem/,/^# STEP 2: Build minimal installer/p' "$0"
        cat "$SCRIPT_DIR/../configs/install-ngit.sh"
    } | sha256sum | cut -d' ' -f1
)

if [ ! -f "$ROOTFS_TAR" ] || [ "${1:-}" == "--rebuild" ] || [ "$(cat "$ROOTFS_STAMP" 2>/dev/null)" != "$RECIPE_HASH" ]; then
    echo "   Using Docker to create Debian root filesystem..."
    
    # Create a Dockerfile for building the rootfs
    # The Dockerfile body is written with a QUOTED heredoc delimiter.
    #
    # It used to be unquoted, which meant the build shell performed command
    # substitution on the body: any backtick in a Dockerfile COMMENT was executed
    # on the build host and its output spliced into the Dockerfile. Six comments
    # did that, and one of them ran "systemctl start archipelago-fips.service"
    # against the build machine on every ISO build. The comment text was also
    # silently deleted from the generated Dockerfile.
    #
    # bash -n cannot see this class of bug — the script is syntactically perfect
    # either way — so quoting the delimiter is the fix, not vigilance about
    # backticks. tests/first-boot-secrets/run-tests.sh case 7 fails if the
    # delimiter is ever unquoted again, or if a substitution appears in the body.
    #
    # The whole body needs exactly four build-time values, all package names, and
    # they are interpolated explicitly by the printf between the two halves.
    cat > "$WORK_DIR/Dockerfile.rootfs" <<'DOCKERFILE_HEAD'
# ─── Stage 1: Build the FIPS mesh daemon .deb at a pinned tag ────────────
#
# FIPS (github.com/jmcorgan/fips) is a fast Nostr-keyed mesh routing
# protocol archipelago uses as its preferred non-Tor transport.
# Pinned so the shipped version is knowable: an unpinned --depth 1 clone of
# main made every ISO carry whatever upstream happened to be that day.
# v0.5.3 is the version fips/config.rs renders its typed config against and
# the one validated in the field. Bump the two together.
#
# Bumping this ARG alone is NOT sufficient — three things move with it:
#   1. core/archipelago/src/fips/config.rs (typed schema + snapshot test)
#   2. tests/fixtures/fips/fips-<tag>.yaml (verbatim upstream example)
#   3. the runtime updater's version ceiling, if the bump is pinned
# Run `scripts/verify-fips-fixtures.sh` after editing; it re-downloads the
# upstream example at this tag and fails on drift.
# The .deb is rebuilt every ISO build; Docker layer caching keeps the
# incremental cost low. Failure here fails the ISO build on purpose:
# we don't want to ship an ISO that silently skips FIPS.
FROM rust:1-slim-bookworm AS fips-builder
ENV DEBIAN_FRONTEND=noninteractive
# Build deps tracked as upstream fips adds transitive native deps:
# - libdbus-1-dev: libdbus-sys (observed 2026-04-19 rebuild)
# - libssl-dev: openssl dependencies
# - libnftnl-dev, libmnl-dev, clang, libclang-dev: rustables →
#   bindgen (the gateway feature enables rustables for nftables
#   integration). bindgen panics without libclang.so.
RUN apt-get -o Acquire::ForceIPv4=true update && apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends \
    git ca-certificates build-essential pkg-config dpkg-dev \
    libdbus-1-dev libssl-dev \
    clang libclang-dev libnftnl-dev libmnl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN cargo install --locked cargo-deb
ARG FIPS_VERSION=v0.5.3
RUN git clone --depth 1 --branch "$FIPS_VERSION" \
    https://github.com/jmcorgan/fips.git /src/fips
WORKDIR /src/fips
# fips-gateway is gated behind the `gateway` Cargo feature (depends on
# `rustables`). Without the feature, cargo doesn't build it, and
# cargo deb --no-build panics hunting for target/release/fips-gateway.
# Inspected upstream Cargo.toml 2026-04-19 — features.gateway = ["dep:rustables"].
RUN cargo build --release
RUN cargo deb --no-build
RUN cp target/debian/fips_*_amd64.deb /tmp/fips.deb

# ─── Stage 2: The actual Archipelago rootfs ──────────────────────────────
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

# Preseed keyboard/console config to prevent console-setup.service failure
RUN echo "keyboard-configuration keyboard-configuration/layoutcode string us" | debconf-set-selections && \
    echo "keyboard-configuration keyboard-configuration/model select Generic 105-key PC" | debconf-set-selections && \
    echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections && \
    echo "console-setup console-setup/codeset47 select Uni2" | debconf-set-selections && \
    echo "console-setup console-setup/fontface47 select Terminus" | debconf-set-selections && \
    echo "console-setup console-setup/fontsize-fb47 select 16" | debconf-set-selections

# Enable non-free-firmware repo — replace DEB822 sources with traditional format
# (DEB822 sed was silently failing, so just overwrite with known-good sources.list)
RUN echo "deb http://deb.debian.org/debian trixie main non-free-firmware" > /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian trixie-updates main non-free-firmware" >> /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian-security trixie-security main non-free-firmware" >> /etc/apt/sources.list && \
    rm -f /etc/apt/sources.list.d/debian.sources

# Install all packages we need including nginx, podman, tor, and openssl (for self-signed certs)
RUN apt-get -o Acquire::ForceIPv4=true update && apt-get -o Acquire::ForceIPv4=true -y full-upgrade && apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends \
DOCKERFILE_HEAD

    # The ONLY build-time interpolation in the entire Dockerfile: the kernel and
    # GRUB package names, which vary by architecture and Debian suite.
    printf '    %s \\\n' \
        "$LINUX_IMAGE_PKG" "$GRUB_EFI_PKG" "$GRUB_EFI_SIGNED_PKG" "$GRUB_PC_PKG" \
        >> "$WORK_DIR/Dockerfile.rootfs"

    cat >> "$WORK_DIR/Dockerfile.rootfs" <<'DOCKERFILE_TAIL'
    systemd \
    systemd-sysv \
    dbus \
    sudo \
    network-manager \
    wpasupplicant \
    wireless-regdb \
    iw \
    rfkill \
    polkitd \
    openssh-server \
    nginx \
    avahi-daemon \
    avahi-utils \
    libnss-mdns \
    podman \
    catatonit \
    uidmap \
    slirp4netns \
    passt \
    aardvark-dns \
    netavark \
    nftables \
    fuse-overlayfs \
    tor \
    python3 \
    curl \
    git \
    tmux \
    vim-tiny \
    nano \
    ca-certificates \
    openssl \
    chrony \
    iputils-ping \
    esptool \
    python3-venv \
    binutils \
    libpython3.13 \
    locales \
    console-setup \
    keyboard-configuration \
    cryptsetup \
    cryptsetup-initramfs \
    e2fsprogs \
    firmware-realtek \
    firmware-iwlwifi \
    firmware-misc-nonfree \
    firmware-linux-nonfree \
    firmware-intel-graphics \
    firmware-amd-graphics \
    intel-microcode \
    amd64-microcode \
    xorg \
    xdotool \
    chromium \
    mesa-va-drivers \
    intel-media-va-driver \
    i965-va-driver \
    vainfo \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    wireplumber \
    alsa-utils \
    unclutter \
    fonts-liberation \
    fonts-noto-color-emoji \
    xfonts-base \
    plymouth \
    plymouth-themes \
    zstd \
    socat \
    python3 \
    apache2-utils \
    wireguard-tools \
    acpid \
    acpi-support-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Strip docs, man pages, and unused locales
RUN find /usr/share/doc -depth -type f ! -name copyright -delete 2>/dev/null || true && \
    find /usr/share/doc -empty -delete 2>/dev/null || true && \
    rm -rf /usr/share/man /usr/share/info /usr/share/lintian /usr/share/linda && \
    find /usr/share/locale -maxdepth 1 -mindepth 1 ! -name 'en_US' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true

# Install Tailscale from official repo
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get -o Acquire::ForceIPv4=true update && apt-get -o Acquire::ForceIPv4=true -y full-upgrade && apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends tailscale && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install FIPS mesh daemon from the .deb built in stage 1. apt-get install
# resolves dependencies from trixie so a cross-dist build still lands cleanly.
COPY --from=fips-builder /tmp/fips.deb /tmp/fips.deb
RUN apt-get update && apt-get -y full-upgrade && apt-get install -y --no-install-recommends /tmp/fips.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && rm /tmp/fips.deb

# Install the pinned Nostr Git runtime. The installer verifies the release
# archive before copying ngit and git-remote-nostr into /usr/bin.
COPY install-ngit.sh /tmp/install-ngit.sh
RUN chmod 0755 /tmp/install-ngit.sh && \
    /tmp/install-ngit.sh && \
    rm /tmp/install-ngit.sh

# Configure locale
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen

# Create archipelago user with password "archipelago"
# audio group: PipeWire runs under the lingering user manager (no logind seat
# session), so udev's seat ACLs on /dev/snd never apply — group access is the
# only way the kiosk's audio can open the hardware.
RUN useradd -m -s /bin/bash -G sudo,dialout,audio archipelago && \
    echo "archipelago:archipelago" | chpasswd && \
    echo "root:archipelago" | chpasswd && \
    echo "archipelago ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/archipelago
# Verify password hash was set (not locked)
RUN grep -q "^archipelago:$" /etc/shadow && echo "Password set OK" || echo "WARNING: password may not be set"

# Set hostname
RUN echo "archipelago" > /etc/hostname

# Configure SSH
RUN mkdir -p /etc/ssh && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true && \
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true

# Configure nginx for Archipelago
RUN rm -f /etc/nginx/sites-enabled/default
COPY nginx-archipelago.conf /etc/nginx/sites-available/archipelago
RUN ln -sf /etc/nginx/sites-available/archipelago /etc/nginx/sites-enabled/archipelago

# Install nginx snippets (PWA config, HTTPS app proxies)
COPY snippets/ /etc/nginx/snippets/

# The self-signed HTTPS keypair is NOT generated here (audit F-03).
#
# It used to be: this layer ran "openssl req" and baked one keypair into the
# shared image, which meant every node flashed from one ISO — and everyone who
# downloaded the ISO — held the same TLS private key. The strip layer at the
# end of this Dockerfile would delete it again anyway, so generating it here
# now only creates a SECOND piece of code that can mint a TLS key with its own
# accounting. There is exactly one producer of this keypair, and it is
# first-boot-secrets.sh, which retries and reports.
#
# The ssl directory is created so that producer's staging swap has somewhere
# to land.
RUN mkdir -p /etc/archipelago/ssl

# Fail the BUILD if the rootfs cannot generate per-device secrets.
#
# The one realistic way first-boot generation fails on every retry is a missing
# generator binary, and that failure is deterministic, not transient — retries
# and reboots will never fix it. A node in the field must not be where we
# discover it. openssl and openssh-server are both in the package list above
# (and openssh-server hard-depends openssh-client, which ships ssh-keygen), so
# today this assertion is cheap insurance rather than a fix. It earns its place
# by turning a silent fleet-wide brick into a loud build failure the first time
# anyone edits that package list.
RUN set -e; \
    for bin in /usr/bin/openssl /usr/bin/ssh-keygen; do \
        if [ ! -x "$bin" ]; then \
            echo "FATAL: $bin missing or not executable in the rootfs." >&2; \
            echo "first-boot-secrets.sh cannot generate per-device SSH host keys" >&2; \
            echo "or the TLS keypair without it, and that failure is permanent." >&2; \
            echo "Restore openssl / openssh-server in the package list above." >&2; \
            exit 1; \
        fi; \
    done; \
    echo "first-boot secret generators present: openssl, ssh-keygen"

# Create archipelago systemd service
COPY archipelago.service /etc/systemd/system/archipelago.service
COPY archipelago-update.service /etc/systemd/system/archipelago-update.service
COPY archipelago-update.timer /etc/systemd/system/archipelago-update.timer
COPY archipelago-doctor.service /etc/systemd/system/archipelago-doctor.service
COPY archipelago-doctor.timer /etc/systemd/system/archipelago-doctor.timer
COPY archipelago-tor-helper.service /etc/systemd/system/archipelago-tor-helper.service
COPY archipelago-tor-helper.path /etc/systemd/system/archipelago-tor-helper.path
COPY nostr-vpn.service /etc/systemd/system/nostr-vpn.service
COPY archipelago-wg.service /etc/systemd/system/archipelago-wg.service
COPY archipelago-wg-address.service /etc/systemd/system/archipelago-wg-address.service
COPY archipelago-fips.service /etc/systemd/system/archipelago-fips.service
COPY nostr-relay.service /etc/systemd/system/nostr-relay.service
COPY nostr-relay-config.toml /etc/archipelago/nostr-relay-config.toml

# WireGuard kernel module auto-load on boot
RUN echo "wireguard" >> /etc/modules-load.d/wireguard.conf

# Copy container doctor + reconcile scripts (referenced by services and the
# OTA update RPC; the reconcile systemd timer is gone as of Step 8a, but the
# script stays until Step 8b/c ports all manifests — update.rs still shells
# out to it during package updates).
RUN mkdir -p /home/archipelago/archy/scripts/lib
COPY container-doctor.sh /home/archipelago/archy/scripts/container-doctor.sh
COPY reconcile-containers.sh /home/archipelago/archy/scripts/reconcile-containers.sh
COPY container-specs.sh /home/archipelago/archy/scripts/container-specs.sh
COPY tor-helper.sh /opt/archipelago/scripts/tor-helper.sh
COPY lib/ /home/archipelago/archy/scripts/lib/
RUN chmod +x /home/archipelago/archy/scripts/*.sh /home/archipelago/archy/scripts/lib/*.sh /opt/archipelago/scripts/*.sh && \
    chown -R archipelago:archipelago /home/archipelago/archy

# Enable cgroup delegation for rootless podman (CPU/memory limits require this)
RUN mkdir -p /etc/systemd/system/user@.service.d && \
    printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > /etc/systemd/system/user@.service.d/delegate.conf

# Allow unprivileged ping inside rootless containers
RUN printf 'net.ipv4.ping_group_range=0 2147483647\n' > /etc/sysctl.d/90-podman-ping.conf

# Archipelago's web UI manages Wi-Fi through the backend service, not a local
# desktop seat. Allow the dedicated system user to control NetworkManager.
RUN mkdir -p /etc/polkit-1/rules.d && \
    printf '%s\n' \
      'polkit.addRule(function(action, subject) {' \
      '    if (subject.user == "archipelago" && action.id.indexOf("org.freedesktop.NetworkManager.") == 0) {' \
      '        return polkit.Result.YES;' \
      '    }' \
      '});' \
      > /etc/polkit-1/rules.d/49-archipelago-networkmanager.rules && \
    chmod 644 /etc/polkit-1/rules.d/49-archipelago-networkmanager.rules

# kdump + rasdaemon (#144, docs/kdump-rasdaemon-design.md): crash dumps and
# hardware-error capture on the host. Packages + config are baked in for fresh
# installs; the binary's host_fixups module delivers the identical end state to
# already-deployed nodes over OTA (idempotent no-op here once applied).
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends kdump-tools kexec-tools makedumpfile rasdaemon; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    CONF=/etc/default/kdump-tools; \
    sed -i 's|^#\?USE_KDUMP=.*|USE_KDUMP="1"|' "$CONF"; \
    grep -q '^KDUMP_COREDIR=' "$CONF" \
        && sed -i 's|^KDUMP_COREDIR=.*|KDUMP_COREDIR="/var/crash"|' "$CONF" \
        || printf '\nKDUMP_COREDIR="/var/crash"\n' >> "$CONF"; \
    grep -q '^CORE_COLLECTOR=' "$CONF" \
        && sed -i 's|^CORE_COLLECTOR=.*|CORE_COLLECTOR="makedumpfile -l --message-level 1 -d 31"|' "$CONF" \
        || printf '\nCORE_COLLECTOR="makedumpfile -l --message-level 1 -d 31"\n' >> "$CONF"; \
    printf '%s\n' \
        '# Archipelago kdump policy (#144). A wedged kiosk is useless until someone' \
        '# power-cycles it — capture the evidence, then reboot by itself. Dumps land in' \
        '# /var/crash (see docs/kdump-rasdaemon-design.md); keep-2 pruning is done by' \
        '# the host fixup pass, not a timer.' \
        'kernel.panic = 10' \
        'kernel.panic_on_oops = 1' \
        'kernel.hung_task_panic = 1' \
        'kernel.hardlockup_panic = 1' \
        > /etc/sysctl.d/99-archipelago-kdump.conf

# Enable services
RUN systemctl enable NetworkManager || true && \
    systemctl enable polkit || systemctl enable polkit.service || true && \
    systemctl enable ssh || true && \
    systemctl enable nginx || true && \
    systemctl enable avahi-daemon || true && \
    systemctl enable archipelago || true && \
    systemctl enable tor || true && \
    systemctl enable tailscaled || true && \
    systemctl enable chrony || true && \
    systemctl enable archipelago-update.timer || true && \
    systemctl enable archipelago-doctor.timer || true && \
    systemctl enable archipelago-tor-helper.path || true && \
    systemctl enable nostr-relay || true && \
    systemctl enable rasdaemon || true && \
    systemctl enable kdump-tools || true
# archipelago-fips.service + archipelago-wg.service + archipelago-wg-address.service
# stay installed and enabled. They all use `ConditionPathExists=` on their
# respective seed-derived key files, so on a fresh pre-onboarding boot
# systemd quietly skips them with no [FAILED] in the MOTD. Once the user
# completes the seed onboarding flow, archipelago writes the key files,
# the archipelago backend calls `systemctl start archipelago-fips.service`
# (see server.rs post-onboarding auto-activate block) and the WG setup
# path runs `archipelago-wg setup` directly. No masking, no user-facing
# "Activate" button — install → onboard → FIPS + WG are just running.
RUN systemctl enable archipelago-fips.service || true

# nostr-vpn is the legacy nostr-tunnel service — deprecated in favour of
# the upstream FIPS daemon. It still crash-loops on boot if left enabled
# (env file doesn't exist until onboarding) so we mask it outright.
# `systemctl mask` alone doesn't stick because the real .service file is
# already in place — explicit rm + /dev/null symlink is what sticks.
RUN rm -f /etc/systemd/system/nostr-vpn.service && \
    ln -sf /dev/null /etc/systemd/system/nostr-vpn.service

# Remove policy-rc.d so services can start on first boot
RUN rm -f /usr/sbin/policy-rc.d

# Create directories (including Cloud storage for FileBrowser)
RUN mkdir -p /var/lib/archipelago/data /var/lib/archipelago/config /var/lib/archipelago/containers /var/lib/archipelago/nostr-relay /var/lib/archipelago/nostr-vpn && \
    mkdir -p /etc/archipelago && \
    mkdir -p /opt/archipelago/bin /opt/archipelago/scripts /opt/archipelago/web-ui && \
    mkdir -p /var/lib/archipelago/data/cloud/Documents /var/lib/archipelago/data/cloud/Photos /var/lib/archipelago/data/cloud/Music /var/lib/archipelago/data/cloud/Videos /var/lib/archipelago/data/cloud/Downloads && \
    cp /etc/archipelago/nostr-relay-config.toml /var/lib/archipelago/nostr-relay/config.toml && \
    chown -R archipelago:archipelago /var/lib/archipelago /opt/archipelago

# Persist journalctl across reboots — without /var/log/journal systemd
# journal uses tmpfs and everything before the last boot is lost. We
# need the full history to diagnose first-boot / install / onboarding
# issues after the fact. Size cap keeps it from eating the disk, and the
# explicit rate limit stops a single chatty service (e.g. a container
# spamming conmon->journald during Bitcoin IBD) from drowning the journal.
# Keep this byte-identical to image-recipe/configs/journald-archipelago.conf —
# the backend self-heals the same file onto deployed nodes (bootstrap.rs).
RUN mkdir -p /var/log/journal && \
    systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true && \
    install -d -m 0755 /etc/systemd/journald.conf.d && \
    printf '[Journal]\nStorage=persistent\nSystemMaxUse=500M\nRuntimeMaxUse=100M\nForwardToSyslog=no\nRateLimitIntervalSec=30s\nRateLimitBurst=10000\n' > /etc/systemd/journald.conf.d/10-archipelago-persistent.conf

# Clean up
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ─── Strip fleet-shared identity material (audit finding F-03) ──────────────
#
# This image is exported to a tar and extracted VERBATIM onto every disk
# flashed from the resulting ISO, and the ISO is a published artefact. Anything
# identity-shaped left in here is therefore held by every node AND by every
# person who downloaded the ISO.
#
# NOTE: this heredoc is UNQUOTED, so backticks here are command substitution
# and would run at build time. Never put backticks in these comments.
#
# The TLS keypair is no longer generated in this Dockerfile at all (see the
# note where that layer used to be). What still gets baked without anyone
# asking for it is Debian's openssh-server postinst, which generates
# /etc/ssh/ssh_host_* at package install time — i.e. inside this container
# build — plus /etc/machine-id, which systemd populates during the build and
# which correlates every node flashed from one ISO. This layer removes both.
#
# archipelago-first-boot-secrets.service recreates all of it per device on
# first boot, retrying on a timer until it succeeds. The point of removing it
# HERE is to change what a generation failure costs: with the material
# stripped, a failure degrades to "no key, the service refuses to start"
# instead of "fleet-shared key, silently" — which is the whole of F-03. That
# makes fail-closed structural rather than procedural.
#
# This must stay the LAST layer: anything that installs packages after it can
# reintroduce host keys. The rm of the TLS keypair is kept as belt-and-braces
# even though nothing in this build creates one any more — if a future layer
# starts baking a cert, this catches it. Keep the /etc/archipelago/ssl
# directory itself so the first-boot script's staging swap has somewhere to
# land.
RUN rm -f /etc/ssh/ssh_host_* && \
    rm -f /etc/archipelago/ssl/archipelago.key /etc/archipelago/ssl/archipelago.crt && \
    mkdir -p /etc/archipelago/ssl && \
    : > /etc/machine-id && \
    { [ -L /var/lib/dbus/machine-id ] || rm -f /var/lib/dbus/machine-id ; } && \
    mkdir -p /opt/archipelago && \
    printf 'F-03 identity strip: this rootfs was built with the identity-strip layer.\nRemoved:\n  /etc/ssh/ssh_host_*\n  /etc/archipelago/ssl/archipelago.key\n  /etc/archipelago/ssl/archipelago.crt\nTruncated:\n  /etc/machine-id\nRecreated per device by archipelago-first-boot-secrets.service on first boot.\n' > /opt/archipelago/rootfs-identity-stripped
DOCKERFILE_TAIL

    # Copy nginx snippets for HTTPS (PWA, app proxies)
    if [ -d "$SCRIPT_DIR/../configs/snippets" ]; then
        mkdir -p "$WORK_DIR/snippets"
        cp "$SCRIPT_DIR/../configs/snippets/"*.conf "$WORK_DIR/snippets/" 2>/dev/null || true
        echo "   Using nginx snippets from configs/snippets/"
    else
        mkdir -p "$WORK_DIR/snippets"
        echo "   ⚠ No nginx snippets found, HTTPS features may not work"
    fi

    # Use nginx config from configs/ (includes app proxies for Nextcloud, Vaultwarden, etc.)
    if [ -f "$SCRIPT_DIR/../configs/nginx-archipelago.conf" ]; then
        cp "$SCRIPT_DIR/../configs/nginx-archipelago.conf" "$WORK_DIR/nginx-archipelago.conf"
        echo "   Using nginx config from configs/nginx-archipelago.conf"
    else
        echo "   ⚠ configs/nginx-archipelago.conf not found, using minimal config"
        cat > "$WORK_DIR/nginx-archipelago.conf" <<'NGINXCONF'
server {
    listen 80;
    server_name _;
    root /opt/archipelago/web-ui;
    index index.html;
    location / { try_files $uri $uri/ /index.html; }
    location /archipelago/ { proxy_pass http://127.0.0.1:5678; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /rpc/ { proxy_pass http://127.0.0.1:5678; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_connect_timeout 300s; proxy_send_timeout 300s; proxy_read_timeout 300s; }
    location /ws { proxy_pass http://127.0.0.1:5678; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_read_timeout 86400s; }
}
NGINXCONF
    fi

    # Copy udev rule for mesh radio stable naming
    if [ -f "$SCRIPT_DIR/../configs/99-mesh-radio.rules" ]; then
        cp "$SCRIPT_DIR/../configs/99-mesh-radio.rules" "$WORK_DIR/99-mesh-radio.rules"
        echo "   Using 99-mesh-radio.rules from configs/"
    fi

    # Copy update service and timer
    if [ -f "$SCRIPT_DIR/../configs/archipelago-update.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-update.service" "$WORK_DIR/archipelago-update.service"
        cp "$SCRIPT_DIR/../configs/archipelago-update.timer" "$WORK_DIR/archipelago-update.timer"
        echo "   Using archipelago-update.service + timer from configs/"
    fi

    # Copy container doctor timer + reconcile script (the reconcile systemd
    # timer is gone as of Step 8a — BootReconciler replaces it — but the
    # reconcile-containers.sh script stays, invoked by the OTA update RPC
    # until Step 8b/c ports all manifests to the Rust orchestrator).
    if [ -f "$SCRIPT_DIR/../configs/archipelago-doctor.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-doctor.service" "$WORK_DIR/archipelago-doctor.service"
        cp "$SCRIPT_DIR/../configs/archipelago-doctor.timer" "$WORK_DIR/archipelago-doctor.timer"
        # Copy the actual scripts the services / update RPC reference
        for s in container-doctor.sh reconcile-containers.sh container-specs.sh tor-helper.sh; do
            if [ -f "$SCRIPT_DIR/../../scripts/$s" ]; then
                cp "$SCRIPT_DIR/../../scripts/$s" "$WORK_DIR/$s"
            fi
        done
        # Copy shared script library (mem_limit etc.)
        if [ -d "$SCRIPT_DIR/../../scripts/lib" ]; then
            mkdir -p "$WORK_DIR/lib"
            cp "$SCRIPT_DIR/../../scripts/lib/"*.sh "$WORK_DIR/lib/" 2>/dev/null || true
        fi
        echo "   Using container doctor timer from configs/"
    fi

    # Copy Tor helper path-activated service (allows backend to manage Tor as non-root)
    if [ -f "$SCRIPT_DIR/../configs/archipelago-tor-helper.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-tor-helper.service" "$WORK_DIR/archipelago-tor-helper.service"
        cp "$SCRIPT_DIR/../configs/archipelago-tor-helper.path" "$WORK_DIR/archipelago-tor-helper.path"
        echo "   Using tor-helper path unit from configs/"
    fi

    # Copy NostrVPN system service (native mesh VPN, not a container)
    if [ -f "$SCRIPT_DIR/../configs/nostr-vpn.service" ]; then
        cp "$SCRIPT_DIR/../configs/nostr-vpn.service" "$WORK_DIR/nostr-vpn.service"
        echo "   Using nostr-vpn.service from configs/"
    fi

    if [ -f "$SCRIPT_DIR/../configs/archipelago-wg.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-wg.service" "$WORK_DIR/archipelago-wg.service"
        echo "   Using archipelago-wg.service from configs/"
    fi
    if [ -f "$SCRIPT_DIR/../configs/archipelago-wg-address.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-wg-address.service" "$WORK_DIR/archipelago-wg-address.service"
        echo "   Using archipelago-wg-address.service from configs/"
    fi
    if [ -f "$SCRIPT_DIR/../configs/archipelago-fips.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago-fips.service" "$WORK_DIR/archipelago-fips.service"
        echo "   Using archipelago-fips.service from configs/"
    fi

    # Copy private Nostr relay service (native, for NostrVPN signaling)
    if [ -f "$SCRIPT_DIR/../configs/nostr-relay.service" ]; then
        cp "$SCRIPT_DIR/../configs/nostr-relay.service" "$WORK_DIR/nostr-relay.service"
        echo "   Using nostr-relay.service from configs/"
    fi
    if [ -f "$SCRIPT_DIR/../configs/nostr-relay-config.toml" ]; then
        cp "$SCRIPT_DIR/../configs/nostr-relay-config.toml" "$WORK_DIR/nostr-relay-config.toml"
        echo "   Using nostr-relay-config.toml from configs/"
    fi

    if [ -f "$SCRIPT_DIR/../configs/install-ngit.sh" ]; then
        cp "$SCRIPT_DIR/../configs/install-ngit.sh" "$WORK_DIR/install-ngit.sh"
        echo "   Using pinned ngit installer from configs/"
    fi

    # Copy WireGuard helper script (privileged peer management)
    if [ -f "$SCRIPT_DIR/../../scripts/archipelago-wg" ]; then
        cp "$SCRIPT_DIR/../../scripts/archipelago-wg" "$WORK_DIR/archipelago-wg"
        echo "   Using archipelago-wg helper from scripts/"
    fi

    # Use archipelago.service from configs/ (User=root for Podman container access)
    if [ -f "$SCRIPT_DIR/../configs/archipelago.service" ]; then
        cp "$SCRIPT_DIR/../configs/archipelago.service" "$WORK_DIR/archipelago.service"
        echo "   Using archipelago.service from configs/"
    else
        cat > "$WORK_DIR/archipelago.service" <<'SYSTEMDSERVICE'
[Unit]
Description=Archipelago Backend
After=network-online.target archipelago-setup-tor.service
Wants=network-online.target

[Service]
Type=simple
User=archipelago
Environment="ARCHIPELAGO_BIND=127.0.0.1:5678"
Environment="XDG_RUNTIME_DIR=/run/user/1000"
ExecStartPre=/bin/bash -c 'mkdir -p /run/user/1000 && chown archipelago:archipelago /run/user/1000 && chmod 700 /run/user/1000'
ExecStart=/usr/local/bin/archipelago
Restart=on-failure
RestartSec=5
ProtectHome=no

[Install]
WantedBy=multi-user.target
SYSTEMDSERVICE
    fi

    echo "   Building $CONTAINER_CMD image (this may take a few minutes)..."
    $CONTAINER_CMD build --no-cache --platform $CONTAINER_PLATFORM -t archipelago-rootfs -f "$WORK_DIR/Dockerfile.rootfs" "$WORK_DIR"
    
    echo "   Exporting filesystem..."
    $CONTAINER_CMD rm -f archipelago-rootfs-tmp 2>/dev/null || true
    $CONTAINER_CMD create --platform $CONTAINER_PLATFORM --name archipelago-rootfs-tmp archipelago-rootfs
    $CONTAINER_CMD export archipelago-rootfs-tmp > "$ROOTFS_TAR"
    $CONTAINER_CMD rm archipelago-rootfs-tmp
    
    echo "$RECIPE_HASH" > "$ROOTFS_STAMP"
    echo "✅ Root filesystem created: $(du -h "$ROOTFS_TAR" | cut -f1)"
else
    echo "✅ Using cached root filesystem: $(du -h "$ROOTFS_TAR" | cut -f1)"
fi

# =============================================================================
# STEP 2: Build minimal installer environment (replaces Debian Live)
# =============================================================================
echo ""
echo "Step 2: Building minimal installer environment via debootstrap..."

INSTALLER_ISO="$WORK_DIR/installer-iso"
INSTALLER_SQUASHFS="$WORK_DIR/installer-squashfs"
rm -rf "$INSTALLER_ISO" "$INSTALLER_SQUASHFS"
mkdir -p "$INSTALLER_ISO/live" "$INSTALLER_ISO/archipelago"
mkdir -p "$INSTALLER_ISO/boot/grub" "$INSTALLER_ISO/isolinux"
mkdir -p "$INSTALLER_ISO/EFI/BOOT"

# Build the installer filesystem inside a container
# This creates: vmlinuz, initrd.img, filesystem.squashfs
# NOTE: the installer-env script is written to a file and bind-mounted into the
# container rather than passed via `bash -c '...'`. On some hosts, the inline
# form somehow interferes with debootstrap's dpkg-deb|tar extraction (repro'd
# on this box: bash -c fails at "Extracting apt...", bash /script.sh succeeds).
_INSTALLER_ENV_SCRIPT="$WORK_DIR/_installer-env.sh"
cat > "$_INSTALLER_ENV_SCRIPT" <<'INSTALLER_ENV_EOF'
set -e

# This build host (and its containers) blackhole IPv6: deb.debian.org
# answers AAAA first, wget tries v6 with long timeouts, and debootstrap's
# per-package fetch fails ("Couldn't download packages", repro'd twice on
# 2026-08-07). Force v4 for every retrieval tool this script drives.
APT_V4='-o Acquire::ForceIPv4=true'

apt-get $APT_V4 update -qq
apt-get $APT_V4 install -y -qq debootstrap squashfs-tools initramfs-tools dosfstools mtools \
    grub-efi-amd64-bin grub-pc-bin grub-common isolinux syslinux-common

# wget gets its v4 pin AFTER its package is installed — editing /etc/wgetrc
# beforehand makes dpkg's conffile prompt fatal on a non-interactive shell
# ("end of file on stdin at conffile prompt", repro'd on build #189).
echo 'inet4_only = on' >> /etc/wgetrc

echo "   [container] Running debootstrap --variant=minbase..."
# ifupdown + isc-dhcp-client added because live-boot's /init writes
# /etc/network/interfaces on the target — without ifupdown, /etc/network/
# doesn't exist and the initramfs throws a non-fatal but noisy
# "can't create /root/etc/network/interfaces: nonexistent directory".
debootstrap --variant=minbase --arch=${DEB_ARCH} \
    --include=systemd,systemd-sysv,udev,dbus,bash,coreutils,mount,util-linux,\
kmod,procps,iproute2,ca-certificates,gdisk,\
cryptsetup,cryptsetup-initramfs,parted,dosfstools,e2fsprogs,\
linux-image-${DEB_ARCH},grub-efi-${DEB_ARCH},grub-pc-bin,\
ifupdown,isc-dhcp-client,\
wpasupplicant,wireless-regdb,iw,rfkill,\
pciutils,usbutils,less,nano \
    trixie /installer http://deb.debian.org/debian

# Install live-boot via chroot — debootstrap minbase resolver cannot handle it.
# The chroot approach works (confirmed in CI run 90) — just needs proc/sys/dev mounts.
echo "   [container] Installing live-boot for squashfs root support..."
cp /etc/resolv.conf /installer/etc/resolv.conf 2>/dev/null || true
mount --bind /proc /installer/proc
mount --bind /sys /installer/sys
mount --bind /dev /installer/dev
# Same v6-blackhole discipline inside the chroot (its apt reads the
# chroot's own config, not the container's).
chroot /installer apt-get -o Acquire::ForceIPv4=true update -qq
chroot /installer apt-get -o Acquire::ForceIPv4=true -y -qq full-upgrade
chroot /installer apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends live-boot live-boot-initramfs-tools
chroot /installer apt-get clean
umount /installer/dev 2>/dev/null || true
umount /installer/sys 2>/dev/null || true
umount /installer/proc 2>/dev/null || true

# Verify live-boot hooks are in place (scripts/live is a FILE not a directory)
if [ -e /installer/usr/share/initramfs-tools/scripts/live ]; then
    echo "   [container] live-boot initramfs hooks: OK"
else
    echo "   [container] FATAL: live-boot hooks not found after install!"
    ls -la /installer/usr/share/initramfs-tools/scripts/ 2>/dev/null
    exit 1
fi

echo "   [container] Configuring installer environment..."

# Set hostname
echo "archipelago-installer" > /installer/etc/hostname

# Set root password
echo "root:archipelago" | chroot /installer chpasswd

# Auto-login on tty1
mkdir -p /installer/etc/systemd/system/getty@tty1.service.d
cat > /installer/etc/systemd/system/getty@tty1.service.d/autologin.conf <<GETTY
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
GETTY

# Auto-start installer via profile.d (runs after auto-login, no getty race)
# This is the same approach the working Debian Live build used.
mkdir -p /installer/etc/profile.d
cat > /installer/etc/profile.d/z99-archipelago-installer.sh <<PROFILE
#!/bin/bash
# Auto-start Archipelago installer on login — only run once
if [ -n "\$INSTALLER_STARTED" ]; then
    return 0 2>/dev/null || exit 0
fi
export INSTALLER_STARTED=1

sleep 1
clear
echo ""
echo -e "\033[38;5;208m  ▄▀█ █▀▄ █▀▀ █ █ █ █▀█ █▀▀ █   ▄▀█ █▀▀ █▀█\033[0m"
echo -e "\033[38;5;208m  █▀█ █▀▄ █   █▀█ █ █▀▀ ██▀ █   █▀█ █ █ █ █\033[0m"
echo -e "\033[38;5;208m  ▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀   ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀\033[0m"
echo -e "                              \033[38;5;130mbitcoin node os\033[0m"
echo ""

BOOT_MEDIA=""
for dev in /run/live/medium /lib/live/mount/medium /run/archiso /cdrom /media/cdrom /mnt/iso; do
    if [ -f "\$dev/archipelago/auto-install.sh" ]; then
        BOOT_MEDIA="\$dev"
        break
    fi
done

# If standard mount points failed, actively find and mount the boot device
if [ -z "\$BOOT_MEDIA" ]; then
    echo -e "  \033[37mSearching for boot device...\033[0m"
    mkdir -p /run/archiso 2>/dev/null
    for blk in /dev/sr0 /dev/sd[a-z] /dev/sd[a-z][0-9] /dev/nvme[0-9]n[0-9]p[0-9]; do
        [ -b "\$blk" ] || continue
        mount -o ro "\$blk" /run/archiso 2>/dev/null || continue
        if [ -f /run/archiso/archipelago/auto-install.sh ]; then
            BOOT_MEDIA="/run/archiso"
            break
        fi
        umount /run/archiso 2>/dev/null
    done
fi

if [ -n "\$BOOT_MEDIA" ]; then
    echo -e "  \033[37mFound installer at: \$BOOT_MEDIA\033[0m"
    echo ""
    echo -e "  Press Enter to install  |  \033[1;37mCtrl+C\033[0m for shell"
    read -s
    bash "\$BOOT_MEDIA/archipelago/auto-install.sh"
else
    echo -e "  \033[37mInstaller not found on boot media.\033[0m"
    echo ""
    echo -e "  \033[37mDebug info:\033[0m"
    ls -la /run/live/ 2>/dev/null || echo "    /run/live/ does not exist"
    mount | grep -E "iso9660|squashfs|overlay" 2>/dev/null
    echo ""
    echo -e "  \033[37mTry:  mount /dev/sdX /mnt/iso && bash /mnt/iso/archipelago/auto-install.sh\033[0m"
    echo ""
fi
PROFILE
chmod +x /installer/etc/profile.d/z99-archipelago-installer.sh

# Custom initramfs hook: mount ISO boot media at /run/archiso
mkdir -p /installer/etc/initramfs-tools/hooks
cat > /installer/etc/initramfs-tools/hooks/archipelago <<HOOK
#!/bin/sh
set -e
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
# Ensure mount helpers and filesystem tools are in initramfs
copy_exec /bin/mount
copy_exec /bin/umount
copy_exec /bin/findfs 2>/dev/null || true
copy_exec /sbin/blkid
manual_add_modules iso9660 vfat squashfs overlay
HOOK
chmod +x /installer/etc/initramfs-tools/hooks/archipelago

mkdir -p /installer/etc/initramfs-tools/scripts/local-bottom
cat > /installer/etc/initramfs-tools/scripts/local-bottom/archipelago-mount <<INITSCRIPT
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in prereqs) prereqs; exit 0;; esac

. /scripts/functions

# Try to find and mount the Archipelago boot media
mkdir -p /run/archiso
log_begin_msg "Searching for Archipelago boot media..."

# Try CD-ROM first, then USB partitions
for dev in /dev/sr0 /dev/sd??* /dev/nvme*p*; do
    [ -b "\$dev" ] 2>/dev/null || continue
    mount -o ro "\$dev" /run/archiso 2>/dev/null || continue
    if [ -d /run/archiso/archipelago ]; then
        log_end_msg 0
        echo "Found Archipelago media on \$dev"
        exit 0
    fi
    umount /run/archiso 2>/dev/null || true
done

log_end_msg 1
echo "Archipelago boot media not found (will retry from userspace)"
INITSCRIPT
chmod +x /installer/etc/initramfs-tools/scripts/local-bottom/archipelago-mount

# Strip docs and man pages from installer
rm -rf /installer/usr/share/man/* /installer/usr/share/doc/*
rm -rf /installer/var/lib/apt/lists/* /installer/var/cache/apt/*

# Extract kernel
KVER=$(ls /installer/lib/modules/ | sort -V | tail -1)
echo "   [container] Kernel version: $KVER"
cp /installer/boot/vmlinuz-$KVER /output/vmlinuz

# Mount virtual filesystems for proper initramfs generation
mount --bind /proc /installer/proc
mount --bind /sys /installer/sys
mount --bind /dev /installer/dev

# Build initramfs with live-boot hooks + our custom hooks
chroot /installer update-initramfs -c -k $KVER
cp /installer/boot/initrd.img-$KVER /output/initrd.img

# Cleanup mounts
umount /installer/dev 2>/dev/null || true
umount /installer/sys 2>/dev/null || true
umount /installer/proc 2>/dev/null || true

# Create squashfs
echo "   [container] Creating installer squashfs..."
mksquashfs /installer /output/filesystem.squashfs -comp xz -Xbcj x86 -noappend -quiet

# Build GRUB EFI image with embedded bootstrap config (grub-mkstandalone)
echo "   [container] Building GRUB EFI image..."
cat > /tmp/grub-embed.cfg <<GRUBEMBED
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod search
insmod search_label
insmod search_fs_file
insmod normal
insmod linux
insmod all_video

# Try label first (standard path)
search --no-floppy --set=root --label ARCHIPELAGO

# Fallback: search for a known file on the ISO
if [ -z "\$root" ]; then
    search --no-floppy --set=root --file /archipelago/auto-install.sh
fi

# Fallback: try configfile from the EFI partition path
if [ -z "\$root" ]; then
    set root=\$cmdpath
fi

set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg

# If configfile fails, try normal
normal
GRUBEMBED

grub-mkstandalone -O x86_64-efi \
    --modules="part_gpt part_msdos fat iso9660 search search_label search_fs_file normal linux all_video font gfxterm configfile echo cat ls test true loopback png" \
    --locales="" \
    --themes="" \
    --fonts="" \
    --output=/output/BOOTX64.EFI \
    "boot/grub/grub.cfg=/tmp/grub-embed.cfg"

# Create EFI FAT image (20MB — includes GRUB binary + grub.cfg)
dd if=/dev/zero of=/output/efi.img bs=1M count=20 2>/dev/null
mkfs.vfat /output/efi.img >/dev/null
mmd -i /output/efi.img ::/EFI ::/EFI/BOOT
mcopy -i /output/efi.img /output/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

# Copy ISOLINUX files for legacy BIOS boot
cp /usr/lib/ISOLINUX/isolinux.bin /output/isolinux.bin
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /output/ldlinux.c32
cp /usr/lib/syslinux/modules/bios/menu.c32 /output/menu.c32 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/vesamenu.c32 /output/vesamenu.c32 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libutil.c32 /output/libutil.c32 2>/dev/null || true
cp /usr/lib/syslinux/modules/bios/libcom32.c32 /output/libcom32.c32 2>/dev/null || true
cp /usr/lib/ISOLINUX/isohdpfx.bin /output/isohdpfx.bin

# Generate GRUB fonts for theme
echo "   [container] Generating GRUB fonts..."
apt-get install -y -qq fonts-dejavu-core grub-common >/dev/null 2>&1
mkdir -p /output/grub-fonts
grub-mkfont -s 12 -o /output/grub-fonts/dejavu_12.pf2 /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
grub-mkfont -s 14 -o /output/grub-fonts/dejavu_14.pf2 /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
grub-mkfont -s 16 -o /output/grub-fonts/dejavu_16.pf2 /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
grub-mkfont -s 24 -o /output/grub-fonts/dejavu_24.pf2 /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf

echo "   [container] Done!"
INSTALLER_ENV_EOF

$CONTAINER_CMD run --rm --privileged --platform $CONTAINER_PLATFORM \
    -v "$WORK_DIR:/output" \
    -v "$_INSTALLER_ENV_SCRIPT:/installer-env.sh:ro" \
    -e DEB_ARCH="$DEB_ARCH" \
    -e LIB_DIR="$LIB_DIR" \
    debian:trixie bash /installer-env.sh

# Verify artifacts
for artifact in vmlinuz initrd.img filesystem.squashfs BOOTX64.EFI efi.img isolinux.bin isohdpfx.bin; do
    if [ ! -f "$WORK_DIR/$artifact" ]; then
        echo "   FATAL: Missing build artifact: $artifact"
        exit 1
    fi
done

# Place artifacts into ISO directory structure
cp "$WORK_DIR/vmlinuz" "$INSTALLER_ISO/live/vmlinuz"
cp "$WORK_DIR/initrd.img" "$INSTALLER_ISO/live/initrd.img"
cp "$WORK_DIR/filesystem.squashfs" "$INSTALLER_ISO/live/filesystem.squashfs"
cp "$WORK_DIR/BOOTX64.EFI" "$INSTALLER_ISO/EFI/BOOT/BOOTX64.EFI"
cp "$WORK_DIR/efi.img" "$INSTALLER_ISO/boot/grub/efi.img"
cp "$WORK_DIR/isolinux.bin" "$INSTALLER_ISO/isolinux/isolinux.bin"
cp "$WORK_DIR/ldlinux.c32" "$INSTALLER_ISO/isolinux/ldlinux.c32"
cp "$WORK_DIR/menu.c32" "$INSTALLER_ISO/isolinux/menu.c32" 2>/dev/null || true
cp "$WORK_DIR/vesamenu.c32" "$INSTALLER_ISO/isolinux/vesamenu.c32" 2>/dev/null || true
cp "$WORK_DIR/libutil.c32" "$INSTALLER_ISO/isolinux/libutil.c32" 2>/dev/null || true
cp "$WORK_DIR/libcom32.c32" "$INSTALLER_ISO/isolinux/libcom32.c32" 2>/dev/null || true

# Install GRUB theme
THEME_SRC="$SCRIPT_DIR/branding/grub-theme"
THEME_DST="$INSTALLER_ISO/boot/grub/themes/archipelago"
mkdir -p "$THEME_DST"
if [ -f "$THEME_SRC/theme.txt" ]; then
    cp "$THEME_SRC/theme.txt" "$THEME_DST/"
    echo "   Installed GRUB theme from branding/grub-theme/"
fi
# Install generated fonts
if [ -d "$WORK_DIR/grub-fonts" ]; then
    cp "$WORK_DIR/grub-fonts/"*.pf2 "$THEME_DST/"
    # Also copy unicode font for GRUB to load
    cp "$WORK_DIR/grub-fonts/dejavu_16.pf2" "$INSTALLER_ISO/boot/grub/font.pf2"
fi
# Copy GRUB background image (static asset or generate if missing)
GRUB_BG="$SCRIPT_DIR/branding/grub-theme/background.png"
if [ -f "$GRUB_BG" ]; then
    cp "$GRUB_BG" "$THEME_DST/background.png"
    echo "   Installed GRUB background"
elif [ -f "$SCRIPT_DIR/branding/generate-grub-background.py" ]; then
    echo "   Generating GRUB background..."
    python3 "$SCRIPT_DIR/branding/generate-grub-background.py" "$THEME_DST/background.png" 2>/dev/null || \
        echo "   WARNING: Could not generate GRUB background"
fi

echo "   Installer squashfs: $(du -h "$INSTALLER_ISO/live/filesystem.squashfs" | cut -f1)"
echo "   Kernel: $(du -h "$INSTALLER_ISO/live/vmlinuz" | cut -f1)"
echo "   Initrd: $(du -h "$INSTALLER_ISO/live/initrd.img" | cut -f1)"
echo "   Step 2 complete (custom minimal base, no Debian Live)"

# =============================================================================
# STEP 3: Add Archipelago components
# =============================================================================
echo ""
echo "📦 Step 3: Adding Archipelago components..."

ARCH_DIR="$INSTALLER_ISO/archipelago"
mkdir -p "$ARCH_DIR"
mkdir -p "$ARCH_DIR/bin"
mkdir -p "$ARCH_DIR/scripts"

# netavark + aardvark-dns are installed in the rootfs via Dockerfile.rootfs (Debian 13 packages).
# Do NOT copy from the build host — the host may run a different glibc version.
echo "   netavark + aardvark-dns: included in rootfs (Debian 13 packages)"

# Copy the pre-built rootfs
echo "   Including root filesystem..."
cp "$ROOTFS_TAR" "$ARCH_DIR/rootfs.tar"

# Ship the canonical systemd unit on the ISO. The rootfs tar is a cached
# artifact that can predate unit fixes (B17: RequiresMountsFor on the data
# volume — without it fresh installs boot-loop "[FAILED]" until the LUKS
# mount lands), so the installer overwrites the rootfs copy with this one.
mkdir -p "$ARCH_DIR/configs"
cp "$SCRIPT_DIR/../configs/archipelago.service" "$ARCH_DIR/configs/archipelago.service"
echo "   Using archipelago.service from configs/ (installer overrides rootfs copy)"

# Capture backend binary from live server
if [ "$BUILD_FROM_SOURCE" = "1" ]; then
    echo "   Building backend binary from source..."
else
    echo "   Capturing backend binary from live server..."
fi

# Try to get backend binary: local release build → local install → remote → container build
BACKEND_CAPTURED=0

# The captured binary MUST report the same version as the checked-out
# core/archipelago/Cargo.toml, otherwise we're shipping a stale binary
# from an earlier version bump (which is what happened with the 14:40
# ISO — it grabbed an Apr-18 1.4.0 binary and the fleet rejected the
# fips.yaml it wrote out on Activate). The expected version is the one
# compiled into this build run.
EXPECTED_VERSION="$(grep '^version' "$(cd "$SCRIPT_DIR/../.." && pwd)/core/archipelago/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
echo "   Expected backend version (from Cargo.toml): $EXPECTED_VERSION"

verify_backend_version() {
    local bin="$1"
    # CARGO_PKG_VERSION is compiled into the binary as a string literal.
    # `strings` output concatenates adjacent printable bytes, so the
    # version rarely sits on its own line — a fixed-string substring
    # match is the right tool. The version is specific enough (e.g.
    # "1.5.0-alpha") that accidental collisions with unrelated data
    # are vanishingly unlikely.
    if strings "$bin" 2>/dev/null | grep -qF "$EXPECTED_VERSION"; then
        echo "   ✅ Version match: binary contains $EXPECTED_VERSION"
        return 0
    fi
    echo "   ⚠️  Captured binary does NOT contain expected version $EXPECTED_VERSION — it is stale"
    return 1
}

# Check for local release binary first (works for both BUILD_FROM_SOURCE and normal mode)
LOCAL_RELEASE="$(cd "$SCRIPT_DIR/../.." && pwd)/core/target/release/archipelago"
if [ -f "$LOCAL_RELEASE" ]; then
    if verify_backend_version "$LOCAL_RELEASE"; then
        cp "$LOCAL_RELEASE" "$ARCH_DIR/bin/archipelago"
        chmod +x "$ARCH_DIR/bin/archipelago"
        echo "   ✅ Backend from local release build ($(du -h "$ARCH_DIR/bin/archipelago" | cut -f1))"
        BACKEND_CAPTURED=1
    else
        echo "   Skipping stale local release binary; trying next source"
    fi
fi

if [ "$BACKEND_CAPTURED" = "0" ] && [ "$BUILD_FROM_SOURCE" != "1" ]; then
    # Direct copy from ARCHIPELAGO_BIN env or local install
    BIN="${ARCHIPELAGO_BIN:-/usr/local/bin/archipelago}"
    if [ -f "$BIN" ] && verify_backend_version "$BIN"; then
        cp "$BIN" "$ARCH_DIR/bin/archipelago"
        chmod +x "$ARCH_DIR/bin/archipelago"
        echo "   ✅ Backend captured from local system ($(du -h "$ARCH_DIR/bin/archipelago" | cut -f1))"
        BACKEND_CAPTURED=1
    fi
    # Remote copy via SCP if local failed
    if [ "$BACKEND_CAPTURED" = "0" ] && [ "$DEV_SERVER" != "localhost" ] && [ "$DEV_SERVER" != "127.0.0.1" ]; then
        if scp "$DEV_SERVER:/usr/local/bin/archipelago" "$ARCH_DIR/bin/archipelago" 2>/dev/null && verify_backend_version "$ARCH_DIR/bin/archipelago"; then
            chmod +x "$ARCH_DIR/bin/archipelago"
            echo "   ✅ Backend captured from remote server ($(du -h "$ARCH_DIR/bin/archipelago" | cut -f1))"
            BACKEND_CAPTURED=1
        else
            rm -f "$ARCH_DIR/bin/archipelago"
        fi
    fi
fi

# Bundle the Reticulum RNode daemon alongside the backend. install-to-disk
# copies everything in archipelago/bin/ to /usr/local/bin, and the mesh
# listener spawns /usr/local/bin/archy-reticulum-daemon for RNode radios —
# a node imaged without it can never connect a Reticulum stick
# (a test node, 2026-07-22: silent connect failures until hand-copied).
RETICULUM_DAEMON="${ARCHY_RETICULUM_DAEMON:-/usr/local/bin/archy-reticulum-daemon}"
if [ -f "$RETICULUM_DAEMON" ]; then
    cp "$RETICULUM_DAEMON" "$ARCH_DIR/bin/archy-reticulum-daemon"
    chmod +x "$ARCH_DIR/bin/archy-reticulum-daemon"
    echo "   ✅ Reticulum daemon bundled ($(du -h "$ARCH_DIR/bin/archy-reticulum-daemon" | cut -f1))"
else
    echo "   ⚠️  archy-reticulum-daemon not found at $RETICULUM_DAEMON — ISO nodes won't support RNode radios until it's sideloaded"
fi

# archy-rnodeconf drives the in-app "Flash LoRa" flow for RNode firmware
# (mesh/flash.rs spawns /usr/local/bin/archy-rnodeconf --autoinstall). A node
# imaged without it fails every RNode flash with "No such file or directory"
# (a test node, 2026-07-29, v1.7.117).
RNODECONF="${ARCHY_RNODECONF:-/usr/local/bin/archy-rnodeconf}"
if [ -f "$RNODECONF" ]; then
    cp "$RNODECONF" "$ARCH_DIR/bin/archy-rnodeconf"
    chmod +x "$ARCH_DIR/bin/archy-rnodeconf"
    echo "   ✅ rnodeconf bundled ($(du -h "$ARCH_DIR/bin/archy-rnodeconf" | cut -f1))"
else
    echo "   ⚠️  archy-rnodeconf not found at $RNODECONF — ISO nodes can't flash RNode firmware until it's sideloaded"
fi

# Mandatory offline flasher: cached rootfs images may lack system esptool.
ESPTOOL_BUNDLE="${ARCHY_ESPTOOL:-$SCRIPT_DIR/../../reticulum-daemon/dist/archy-esptool}"
if [ ! -x "$ESPTOOL_BUNDLE" ]; then
    echo "ERROR: packaged archy-esptool missing; build reticulum-daemon/build-esptool.sh" >&2
    exit 1
fi
"$ESPTOOL_BUNDLE" --archy-self-test || exit 1
install -m 755 "$ESPTOOL_BUNDLE" "$ARCH_DIR/bin/archy-esptool"

if [ "$BACKEND_CAPTURED" = "0" ]; then
    if [ "$BUILD_FROM_SOURCE" != "1" ]; then
        echo "   ⚠️  Could not capture from live server, building from source..."
    fi
    BACKEND_DOCKERFILE="$WORK_DIR/Dockerfile.backend"
    cat > "$BACKEND_DOCKERFILE" <<'BACKENDFILE'
FROM rust:1.99-trixie as builder
WORKDIR /build
COPY core ./core
# runtime.rs include_str!s ../../../../../../apps/nginx-proxy-manager/manifest.yml,
# i.e. six levels up out of core/, so apps/ must be in the build context or the
# compile dies with "couldn't read .../manifest.yml".
COPY apps ./apps
COPY scripts ./scripts
COPY image-recipe/configs ./image-recipe/configs
RUN cd core && cargo build --release --bin archipelago
BACKENDFILE

    BACKEND_IMAGE="localhost/archipelago-backend:iso"
    if $CONTAINER_CMD build --platform $CONTAINER_PLATFORM -t "$BACKEND_IMAGE" -f "$BACKEND_DOCKERFILE" "$SCRIPT_DIR/../.."; then
        echo "   Extracting backend binary..."
        BACKEND_CONTAINER=$($CONTAINER_CMD create --platform $CONTAINER_PLATFORM "$BACKEND_IMAGE")
        $CONTAINER_CMD cp "$BACKEND_CONTAINER:/build/core/target/release/archipelago" "$ARCH_DIR/bin/" && \
            echo "   ✅ Backend binary built ($(du -h "$ARCH_DIR/bin/archipelago" | cut -f1))"
        $CONTAINER_CMD rm "$BACKEND_CONTAINER"
    else
        echo "   ❌ Backend build failed and server capture failed"
        exit 1
    fi
fi

# NostrVPN (the native `nvpn` mesh-VPN daemon) has been removed from the
# product — the active VPN path is WireGuard/Tailscale (see core vpn.rs). Its
# service is already masked below (ln -sf /dev/null nostr-vpn.service) and the
# binary is never spawned at runtime, so we no longer extract it. The
# nostr-vpn image was deleted from the registry, which is why hard-requiring
# it here bricked the build. Intentionally left out; do not re-add without
# restoring the daemon.

# Extract nostr-rs-relay binary from container image (native system service for VPN signaling)
echo "   Extracting nostr-rs-relay binary..."
RELAY_IMAGE="$($CONTAINER_CMD images -q source.archipelago-foundation.org/lfg2025/nostr-rs-relay:0.9.0 2>/dev/null)"
if [ -z "$RELAY_IMAGE" ]; then
    $CONTAINER_CMD pull source.archipelago-foundation.org/lfg2025/nostr-rs-relay:0.9.0 2>/dev/null || true
fi
RELAY_CONTAINER=$($CONTAINER_CMD create source.archipelago-foundation.org/lfg2025/nostr-rs-relay:0.9.0 2>/dev/null) || true
if [ -n "$RELAY_CONTAINER" ]; then
    # The relay image builds to its WORKDIR /usr/src/app and execs
    # ./nostr-rs-relay from there (not /usr/local/bin — that path was from an
    # older image build and silently broke extraction once the image was
    # rebuilt to the standard layout).
    $CONTAINER_CMD cp "$RELAY_CONTAINER:/usr/src/app/nostr-rs-relay" "$ARCH_DIR/bin/nostr-rs-relay" 2>/dev/null && \
        chmod +x "$ARCH_DIR/bin/nostr-rs-relay" && \
        echo "   ✅ nostr-rs-relay binary extracted ($(du -h "$ARCH_DIR/bin/nostr-rs-relay" | cut -f1))"
    $CONTAINER_CMD rm "$RELAY_CONTAINER" 2>/dev/null || true
else
    echo "   ⚠  nostr-rs-relay image not available — relay binary will be missing"
fi

# A missing nostr-rs-relay used to be a warning, and the resulting ISO shipped
# an enabled nostr-relay unit that crash-looped on every install. Refuse to
# produce that ISO unless explicitly overridden. (nvpn is intentionally no
# longer required — NostrVPN was removed; see the note above.)
MISSING_VPN_BINARIES=""
[ -f "$ARCH_DIR/bin/nostr-rs-relay" ] || MISSING_VPN_BINARIES="$MISSING_VPN_BINARIES nostr-rs-relay"
if [ -n "$MISSING_VPN_BINARIES" ]; then
    if [ "${ALLOW_MISSING_VPN_BINARIES:-0}" = "1" ]; then
        echo "   ⚠  Building WITHOUT:$MISSING_VPN_BINARIES (ALLOW_MISSING_VPN_BINARIES=1)"
    else
        echo "   ❌ Required binaries not extracted:$MISSING_VPN_BINARIES"
        echo "      The registry (source.archipelago-foundation.org) must be reachable and hold the images,"
        echo "      or set ALLOW_MISSING_VPN_BINARIES=1 to ship without VPN signaling."
        exit 1
    fi
fi

# Copy WireGuard helper script
if [ -f "$WORK_DIR/archipelago-wg" ]; then
    cp "$WORK_DIR/archipelago-wg" "$ARCH_DIR/bin/archipelago-wg"
    chmod +x "$ARCH_DIR/bin/archipelago-wg"
    echo "   ✅ WireGuard helper script included"
fi

# Copy NostrVPN UI dashboard for nginx serving
if [ -d "$SCRIPT_DIR/../../docker/nostr-vpn-ui" ]; then
    mkdir -p "$ARCH_DIR/web-ui/nostr-vpn"
    cp "$SCRIPT_DIR/../../docker/nostr-vpn-ui/index.html" "$ARCH_DIR/web-ui/nostr-vpn/"
    echo "   ✅ NostrVPN UI dashboard included"
fi

# Capture web UI from live server
if [ "$BUILD_FROM_SOURCE" = "1" ]; then
    echo "   Building web UI from source..."
else
    echo "   Capturing web UI from live server..."
fi
mkdir -p "$ARCH_DIR/web-ui"

# Try to get from live server first (unless BUILD_FROM_SOURCE=1)
WEBUI_CAPTURED=0
if [ -n "${ARCHIPELAGO_WEB_UI:-}" ]; then
    # Release builds supply the qualified payload explicitly. Never substitute
    # a running node's cached runtime files or an older installed dashboard.
    if [ ! -f "$ARCHIPELAGO_WEB_UI/index.html" ] || \
       [ ! -f "$ARCHIPELAGO_WEB_UI/aiui/index.html" ] || \
       [ ! -f "$ARCHIPELAGO_WEB_UI/aiui/BUILD-INFO" ]; then
        echo "ERROR: ARCHIPELAGO_WEB_UI must contain the qualified dashboard and AIUI"
        exit 1
    fi
    cp -r "$ARCHIPELAGO_WEB_UI/." "$ARCH_DIR/web-ui/"
    WEBUI_CAPTURED=1
fi
if [ "$WEBUI_CAPTURED" = "0" ] && [ "$BUILD_FROM_SOURCE" != "1" ]; then
    # Direct copy from local filesystem (when running on target with sudo)
    if [ -d "/opt/archipelago/web-ui" ] && [ "$(ls -A /opt/archipelago/web-ui 2>/dev/null)" ]; then
        cp -r /opt/archipelago/web-ui/* "$ARCH_DIR/web-ui/"
        echo "   ✅ Web UI captured from local system ($(du -sh "$ARCH_DIR/web-ui" | cut -f1))"
        WEBUI_CAPTURED=1
    fi
    # Remote copy via rsync if local failed
    if [ "$WEBUI_CAPTURED" = "0" ] && [ "$DEV_SERVER" != "localhost" ] && [ "$DEV_SERVER" != "127.0.0.1" ]; then
        if rsync -az "$DEV_SERVER:/opt/archipelago/web-ui/" "$ARCH_DIR/web-ui/" 2>/dev/null && [ "$(ls -A "$ARCH_DIR/web-ui")" ]; then
            echo "   ✅ Web UI captured from remote server ($(du -sh "$ARCH_DIR/web-ui" | cut -f1))"
            WEBUI_CAPTURED=1
        fi
    fi
fi

if [ "$WEBUI_CAPTURED" = "0" ]; then
    if [ "$BUILD_FROM_SOURCE" != "1" ]; then
        echo "   ⚠️  Could not capture from live server, building from source..."
    fi
    cd "$SCRIPT_DIR/../../neode-ui"
    echo "   Installing frontend dependencies..."
    npm ci --prefer-offline 2>&1 | tail -3
    if npm run build 2>&1 | tail -5; then
        if [ -d "$SCRIPT_DIR/../../web/dist/neode-ui" ]; then
            echo "   Including web UI from web/dist/neode-ui..."
            cp -r "$SCRIPT_DIR/../../web/dist/neode-ui/"* "$ARCH_DIR/web-ui/"
            echo "   ✅ Web UI built ($(du -sh "$ARCH_DIR/web-ui" | cut -f1))"
        fi
    else
        echo "   ⚠️  Web UI build failed"
        # Try to use existing build
        if [ -d "$SCRIPT_DIR/../../web/dist/neode-ui" ]; then
            echo "   Using existing web UI build..."
            cp -r "$SCRIPT_DIR/../../web/dist/neode-ui/"* "$ARCH_DIR/web-ui/"
        elif [ -d "$SCRIPT_DIR/../../neode-ui/dist" ]; then
            echo "   Using neode-ui/dist..."
            cp -r "$SCRIPT_DIR/../../neode-ui/dist/"* "$ARCH_DIR/web-ui/"
        else
            echo "   ❌ No web UI available"
            exit 1
        fi
    fi
    cd "$SCRIPT_DIR"
fi

# Include AIUI web app (Claude chat interface)
AIUI_INCLUDED=0
# Pick the NEWEST valid AIUI build across the candidate locations, not the
# first: demo/aiui is the checked-in fallback so fresh clones can build an
# ISO, but on a dev box it is older than the tree's dist and silently won —
# 2026-08-07's RC1 shipped an index.html pointing at the stale demo bundle
# while the fresh one sat unused beside it. The merge also needs --delete,
# or yesterday's hashed assets linger next to today's forever.
AIUI_SRC=""
AIUI_NEWEST=0
if [ -n "${ARCHIPELAGO_WEB_UI:-}" ]; then
    AIUI_SRC="$ARCHIPELAGO_WEB_UI/aiui"
else
for AIUI_DIR in \
    "$SCRIPT_DIR/../../aiui/packages/app/dist" \
    "$SCRIPT_DIR/../../AIUI/packages/app/dist" \
    "$HOME/AIUI/packages/app/dist" \
    "/home/archipelago/AIUI/packages/app/dist" \
    "/opt/archipelago/web-ui/aiui" \
    "/home/archipelago/archy/AIUI/packages/app/dist" \
    "$SCRIPT_DIR/../../demo/aiui"; do
    if [ -d "$AIUI_DIR" ] && [ -f "$AIUI_DIR/index.html" ]; then
        m="$(stat -c %Y "$AIUI_DIR/index.html" 2>/dev/null || echo 0)"
        if [ "$m" -gt "$AIUI_NEWEST" ]; then
            AIUI_NEWEST="$m"
            AIUI_SRC="$AIUI_DIR"
        fi
    fi
done
fi
if [ -n "$AIUI_SRC" ]; then
    echo "   Including AIUI from $AIUI_SRC (newest of the candidates)..."
    mkdir -p "$ARCH_DIR/web-ui/aiui"
    # Use rsync to handle same-file (CI workspace == /opt/archipelago) gracefully
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$AIUI_SRC/" "$ARCH_DIR/web-ui/aiui/"
    else
        rm -rf "${ARCH_DIR:?}/web-ui/aiui"
        mkdir -p "$ARCH_DIR/web-ui/aiui"
        cp -r "$AIUI_SRC/"* "$ARCH_DIR/web-ui/aiui/" 2>/dev/null || true
    fi
    echo "   ✅ AIUI included ($(du -sh "$ARCH_DIR/web-ui/aiui" | cut -f1))"
    AIUI_INCLUDED=1
fi
if [ "$AIUI_INCLUDED" = "0" ]; then
    echo "   ⚠️  AIUI not found — build it first:"
    echo "      cd aiui/packages/app && VITE_BASE_PATH=/aiui/ npx vite build"
    echo "   Searched: aiui/packages/app/dist, AIUI/packages/app/dist, ~/AIUI, /opt/archipelago/web-ui/aiui, demo/aiui"
fi

# Copy app manifests
if [ -d "$SCRIPT_DIR/../../apps" ]; then
    echo "   Including app manifests..."
    cp -r "$SCRIPT_DIR/../../apps" "$ARCH_DIR/"
fi

# Copy Plymouth theme files for installation on target
PLYMOUTH_SRC="$SCRIPT_DIR/branding/plymouth-theme"
if [ -d "$PLYMOUTH_SRC" ]; then
    mkdir -p "$ARCH_DIR/plymouth-theme"
    cp "$PLYMOUTH_SRC/"* "$ARCH_DIR/plymouth-theme/"
    echo "   Included Plymouth theme"
fi

# =============================================================================
# STEP 3b: Bundle container images for offline installation
# =============================================================================
echo ""

if [ "$UNBUNDLED" = "1" ]; then
    echo "📦 Step 3b: Bundling core containers only (UNBUNDLED mode)"
    echo "   Optional apps will be downloaded on-demand from the Marketplace after install."
    # Marker file: first-boot-containers.sh checks this to skip app creation
    touch "$ARCH_DIR/.unbundled"
    IMAGES_DIR="$ARCH_DIR/container-images"
    # Clean stale images from previous builds (e.g. bundled build tars leaking into unbundled)
    rm -rf "$IMAGES_DIR"
    mkdir -p "$IMAGES_DIR"
    # Core baseline apps created by first-boot-containers.sh even in
    # unbundled mode — their images must ride on the ISO so a fresh install
    # works with no internet: FileBrowser (Cloud file manager) and fmcd
    # (fedimint-clientd, ecash/sats out of the box).
    # Shipped zstd-compressed: podman load auto-detects compression, and an
    # uncompressed fmcd.tar alone added ~220MB to the ISO (RC9 size regression).
    CORE_BUNDLE="
${FILEBROWSER_IMAGE} filebrowser.tar.zst
${FMCD_IMAGE} fmcd.tar.zst
"
    echo "$CORE_BUNDLE" | while read -r CORE_IMAGE CORE_FILE; do
        [ -n "$CORE_IMAGE" ] || continue
        if [ -f "$IMAGES_DIR/$CORE_FILE" ]; then
            echo "   ✅ Using cached: $CORE_FILE"
        else
            echo "   Pulling $CORE_IMAGE ($CONTAINER_PLATFORM)..."
            if container_pull "$CORE_IMAGE"; then
                RAW_TAR="$IMAGES_DIR/${CORE_FILE%.zst}"
                if $CONTAINER_CMD save "$CORE_IMAGE" -o "$RAW_TAR" 2>/dev/null && \
                    zstd -q -T0 -15 --rm "$RAW_TAR" -o "$IMAGES_DIR/$CORE_FILE"; then
                    echo "   ✅ Saved core: $CORE_FILE ($(du -h "$IMAGES_DIR/$CORE_FILE" | cut -f1))"
                else
                    rm -f "$RAW_TAR" "$IMAGES_DIR/$CORE_FILE"
                    echo "   ⚠️  Failed to save $CORE_IMAGE"
                fi
            else
                echo "   ⚠️  Failed to pull $CORE_IMAGE — baseline app won't work offline"
            fi
        fi
    done
else
echo "📦 Step 3b: Bundling container images for offline use..."

IMAGES_DIR="$ARCH_DIR/container-images"
mkdir -p "$IMAGES_DIR"

# When DEV_SERVER is set (and not localhost), try to capture images from live server
# so the ISO includes the same set as the dev server (including custom UIs: bitcoin-ui, lnd-ui).
IMAGES_CAPTURED_FROM_SERVER=0
if [ -n "$DEV_SERVER" ] && [ "$DEV_SERVER" != "localhost" ] && [ "$DEV_SERVER" != "127.0.0.1" ]; then
    echo "   Capturing container images from live server ($DEV_SERVER)..."
    # Patterns match against `podman images` repository names (not container names)
    CAPTURE_PATTERNS="bitcoin-ui bitcoinknots lnd lnd-ui electrs-ui filebrowser mempool backend frontend electrs tailscale homeassistant home-assistant btcpayserver nbxplorer postgres alpine-tor nostr-rs-relay strfry fedimintd gatewayd dwn-server vaultwarden searxng mariadb valkey nginx-alpine portainer nginx-proxy-manager"
    REMOTE_TMP="/tmp/archipelago-image-capture-$$"
    SAVED_LIST=$(ssh "$DEV_SERVER" "mkdir -p $REMOTE_TMP && for p in $CAPTURE_PATTERNS; do img=\$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i \"\$p\" | head -1); [ -n \"\$img\" ] && podman save -o \"$REMOTE_TMP/\$p.tar\" \"\$img\" 2>/dev/null && echo \"\$p\"; done" 2>/dev/null) || true
    for p in $SAVED_LIST; do
        if [ -n "$p" ] && scp "$DEV_SERVER:$REMOTE_TMP/$p.tar" "$IMAGES_DIR/$p.tar" 2>/dev/null; then
            echo "   ✅ Captured from server: $p.tar"
            IMAGES_CAPTURED_FROM_SERVER=1
        fi
    done
    ssh "$DEV_SERVER" "rm -rf $REMOTE_TMP" 2>/dev/null || true
    if [ "$IMAGES_CAPTURED_FROM_SERVER" = "0" ]; then
        echo "   ⚠️  No images captured from server, will use registry pull fallback"
    fi
fi

# Define images to bundle for fallback (when not from server or missing). Includes filebrowser.
# bitcoin-ui and lnd-ui are custom and normally captured from server or built separately.
# Alpha: core Bitcoin/Lightning stack + essential apps. Others pulled on-demand from Marketplace.
CONTAINER_IMAGES="
${BITCOIN_KNOTS_IMAGE} bitcoin-knots.tar
${LND_IMAGE} lnd.tar
${HOMEASSISTANT_IMAGE} homeassistant.tar
${BTCPAY_IMAGE} btcpayserver.tar
${NBXPLORER_IMAGE} nbxplorer.tar
${POSTGRES_IMAGE} postgres-btcpay.tar
${MEMPOOL_BACKEND_IMAGE} mempool-backend.tar
${MEMPOOL_WEB_IMAGE} mempool-frontend.tar
${ELECTRUMX_IMAGE} electrumx.tar
${MARIADB_IMAGE} mariadb-mempool.tar
${FEDIMINT_IMAGE} fedimint.tar
${FEDIMINT_GATEWAY_IMAGE} fedimint-gateway.tar
${FMCD_IMAGE} fmcd.tar
${FILEBROWSER_IMAGE} filebrowser.tar
${ALPINE_TOR_IMAGE} alpine-tor.tar
${NGINX_ALPINE_IMAGE} nginx-alpine.tar
${DWN_SERVER_IMAGE} dwn-server.tar
${GRAFANA_IMAGE} grafana.tar
${UPTIME_KUMA_IMAGE} uptime-kuma.tar
${VAULTWARDEN_IMAGE} vaultwarden.tar
${SEARXNG_IMAGE} searxng.tar
${PORTAINER_IMAGE} portainer.tar
${TAILSCALE_IMAGE} tailscale.tar
${JELLYFIN_IMAGE} jellyfin.tar
${PHOTOPRISM_IMAGE} photoprism.tar
${NEXTCLOUD_IMAGE} nextcloud.tar
${NPM_IMAGE} nginx-proxy-manager.tar
${ONLYOFFICE_IMAGE} onlyoffice.tar
"

# Pull and save each image (force target arch) only if not already present
echo "$CONTAINER_IMAGES" | while read -r image filename; do
    [ -z "$image" ] && continue
    tarpath="$IMAGES_DIR/$filename"

    if [ -f "$tarpath" ]; then
        echo "   ✅ Using cached: $filename"
    else
        echo "   Pulling $image ($CONTAINER_PLATFORM)..."
        if container_pull "$image"; then
            echo "   Saving $filename..."
            if $CONTAINER_CMD save "$image" -o "$tarpath" 2>/dev/null; then
                echo "   ✅ Saved: $(du -h "$tarpath" | cut -f1)"
            else
                echo "   ⚠️  Failed to save $image (zstd/format issue) - skipping"
                rm -f "$tarpath"
            fi
        else
            echo "   ⚠️  Failed to pull $image - skipping"
        fi
    fi
done
fi  # end UNBUNDLED check

# Create first-boot service to load images into Podman
echo "   Creating first-boot image loader service..."
cat > "$WORK_DIR/archipelago-load-images.service" <<'LOADSERVICE'
[Unit]
Description=Load Archipelago Container Images
After=network.target podman.service
ConditionPathExists=/opt/archipelago/container-images
ConditionPathExists=!/var/lib/archipelago/.images-loaded

[Service]
Type=oneshot
ExecStart=/opt/archipelago/scripts/load-container-images.sh
ExecStartPost=/usr/bin/touch /var/lib/archipelago/.images-loaded
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
LOADSERVICE

cat > "$WORK_DIR/load-container-images.sh" <<'LOADSCRIPT'
#!/bin/bash
# Load pre-bundled container images into Podman
#
# CRITICAL: all Archipelago containers run ROOTLESS as the archipelago user.
# This script runs as root (systemd oneshot), so a plain `podman load` here
# puts the images into root's storage where the rootless runtime can never
# see them — containers then silently depend on registry pulls, and a fresh
# install without internet gets no apps at all. Always load into the
# archipelago user's storage.

IMAGES_DIR="/opt/archipelago/container-images"
LOG_FILE="/var/log/archipelago-images.log"

echo "$(date): Starting container image load" >> "$LOG_FILE"

if [ ! -d "$IMAGES_DIR" ]; then
    echo "$(date): No images directory found" >> "$LOG_FILE"
    exit 0
fi

ARCH_UID=$(id -u archipelago)
# Linger gives the archipelago user a runtime dir (/run/user/UID) at boot,
# before any login — required for rootless podman.
loginctl enable-linger archipelago 2>/dev/null || true
for _ in $(seq 1 30); do
    [ -d "/run/user/$ARCH_UID" ] && break
    sleep 1
done
PODMAN="runuser -u archipelago -- env XDG_RUNTIME_DIR=/run/user/$ARCH_UID podman"
$PODMAN system migrate >> "$LOG_FILE" 2>&1 || true

for tarfile in "$IMAGES_DIR"/*.tar "$IMAGES_DIR"/*.tar.zst; do
    if [ -f "$tarfile" ]; then
        echo "$(date): Loading $(basename "$tarfile")..." >> "$LOG_FILE"
        $PODMAN load -i "$tarfile" >> "$LOG_FILE" 2>&1 && \
            echo "$(date): Successfully loaded $(basename "$tarfile")" >> "$LOG_FILE" || \
            echo "$(date): Failed to load $(basename "$tarfile")" >> "$LOG_FILE"
    fi
done

# Ensure archy-net exists for mempool stack (db, api, frontend)
$PODMAN network create archy-net 2>/dev/null || true

echo "$(date): Container image load complete" >> "$LOG_FILE"
echo "$(date): Available images:" >> "$LOG_FILE"
$PODMAN images >> "$LOG_FILE" 2>&1
LOADSCRIPT

chmod +x "$WORK_DIR/load-container-images.sh"

# Copy scripts to ISO
mkdir -p "$ARCH_DIR/scripts"
cp "$WORK_DIR/load-container-images.sh" "$ARCH_DIR/scripts/"
cp "$WORK_DIR/archipelago-load-images.service" "$ARCH_DIR/scripts/"

# First-boot per-device secrets: the squashfs bakes one TLS key and one set
# of SSH host keys at build time, so every device flashed from the same image
# would share them. Regenerate both on the installed system's first boot,
# before the network-facing services come up.
echo "   Creating first-boot secrets regeneration service..."
cat > "$WORK_DIR/archipelago-first-boot-secrets.service" <<'SECRETSSERVICE'
[Unit]
Description=Regenerate per-device secrets (TLS key, SSH host keys)
DefaultDependencies=no
After=local-fs.target
# No random-seed file is baked into the rootfs today (verified by the entropy
# audit's C-4 tar listing), so this ordering is a no-op right now. It is here
# so that if one is ever introduced, the pool is credited before this unit —
# the first consumer of entropy on a freshly-flashed machine — draws from it.
After=systemd-random-seed.service
Before=ssh.service nginx.service archipelago.service
# There is deliberately NO ConditionPathExists=!.secrets-regenerated here.
#
# It used to short-circuit the unit once the marker existed, which meant a node
# that had completed generation could never be re-examined. That is fine while
# the only question is "do the keys exist", and wrong as soon as the question
# is "are they still trustworthy" — a cert minted under a wrong clock succeeds
# at generation and is only detectable afterwards. Skipping the unit is exactly
# how such a node stays broken forever.
#
# The script owns the decision instead: it exits within milliseconds when the
# material is present and correctly dated. One place decides, and it is the
# place that can see the whole picture.

[Service]
Type=oneshot
ExecStart=/opt/archipelago/scripts/first-boot-secrets.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SECRETSSERVICE

# Self-heal timer. Fail-closed governs SERVING (never present a key we did not
# generate); this timer governs RECOVERING (never dead-end a node).
#
# Without it, a node whose generators failed all their in-boot retries would sit
# with no SSH host key and no TLS key until somebody walked to it with a
# keyboard. With it, a transient cause that later clears — a full disk that gets
# freed, a pool that eventually seeds — repairs the node unattended.
#
# The service's own ConditionPathExists=! is what stops this: once the marker
# exists, every subsequent trigger is a no-op that systemd records as success,
# so the timer costs nothing on a healthy node and needs no separate teardown.
# This uses systemd's own facilities on purpose; a sleep loop inside the script
# would hold a oneshot open for hours and hide the failure from systemctl.
cat > "$WORK_DIR/archipelago-first-boot-secrets.timer" <<'SECRETSTIMER'
[Unit]
Description=Retry per-device secret generation until it succeeds
Documentation=man:archipelago-first-boot-secrets.service(8)

[Timer]
# First retry shortly after boot has settled — by then the disk, the entropy
# pool and any late-mounting filesystem have had a chance to become healthy.
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=30s
Unit=archipelago-first-boot-secrets.service

[Install]
WantedBy=timers.target
SECRETSTIMER

cat > "$WORK_DIR/first-boot-secrets.sh" <<'SECRETSSCRIPT'
#!/bin/bash
# Create this device's own TLS keypair and SSH host keys on first boot.
#
# ── FAIL CLOSED — read this before changing anything below (audit F-03) ──
#
# The rootfs tar is byte-identical on every node flashed from one ISO, and the
# ISO is a published artefact. It therefore no longer carries any identity
# material: the rootfs Dockerfile in STEP 1 of this builder strips the SSH
# host keys, the TLS keypair and machine-id out of the shared image. THIS
# SCRIPT IS THE ONLY THING THAT CREATES THEM. That is deliberate.
#
# SINGLE PRODUCER. gen_tls() below is the only code anywhere in the ISO build
# that creates /etc/archipelago/ssl/archipelago.{key,crt}; gen_ssh() is the only
# code that creates /etc/ssh/ssh_host_*. The Dockerfile no longer bakes a
# keypair and the installer's old "ensure SSL cert exists" fallback is gone.
# That is the actual lesson of F-03: the bug was never "a second attempt to
# create a key exists", it was that failure was silent and the marker lied
# about it. A second producer is dangerous precisely because it has its own
# accounting — its own idea of success, its own (absent) retry policy, its own
# (absent) failure record. One producer means one place that can fail, one
# place that retries, one place that reports.
#
# FAIL CLOSED applies to SERVING: if generation fails, no key exists, so sshd
# and the nginx TLS listener refuse to start. They never come up on a
# placeholder, a zero-length file, or a key from anywhere else. gen_tls swaps
# into place only after openssl has parsed both halves back, so a truncated or
# corrupt artefact is never what a service reads.
#
# SELF-HEAL applies to RECOVERING, and it is a different thing: a failure must
# never dead-end the node. Three attempts with backoff inside the boot, then
# archipelago-first-boot-secrets.timer retries every 15 minutes, and every
# subsequent boot retries too — all because the marker is never written on
# failure. A transient cause that later clears (a full disk that gets freed, a
# pool that eventually seeds) repairs the node with nobody at a console. On
# success the script restarts whatever refused to start, so recovery is
# complete rather than pending-a-reboot.
#
# The only failure that survives all of that is a deterministic one — a missing
# generator binary — and the rootfs build asserts openssl and ssh-keygen are
# present and executable, so the build fails rather than the fleet.
#
# What this replaces was worse in every direction: log a warning, set the
# completion marker anyway, never retry, and run forever on the SSH host key and
# TLS private key that every downloader of the ISO also holds — undetectable
# host impersonation and transparent MITM of the web UI, on a node whose
# operator has no idea.
#
# Testability seam: FIRST_BOOT_SECRETS_ROOT prefixes every absolute path. It is
# unset in production — the expansion is empty and behaviour is identical to a
# script with the paths hard-coded — and set to a temp dir by
# tests/first-boot-secrets/run-tests.sh, which is what makes the fail-closed
# property assertable instead of merely claimed.
set -u

ROOT="${FIRST_BOOT_SECRETS_ROOT:-}"

# Waits between attempts at one generator. The attempt count is the number of
# entries; the wait after the final attempt is skipped, because a failed last
# attempt is terminal and there is nothing left to wait for. With the default
# 3-entry list that means 3 attempts at t=0s, t=2s and t=10s, and the trailing
# 20 is the ceiling that applies if the list is ever lengthened. Tests override
# this with zeros so the suite does not sleep.
BACKOFF="${FIRST_BOOT_SECRETS_BACKOFF:-2 8 20}"

LOG="$ROOT/var/log/archipelago-first-boot-secrets.log"
MARKER="$ROOT/var/lib/archipelago/.secrets-regenerated"
FAILED="$ROOT/var/lib/archipelago/first-boot-secrets.failed"
CONSOLE="$ROOT/dev/console"
SSL_DIR="$ROOT/etc/archipelago/ssl"
SSH_DIR="$ROOT/etc/ssh"

# Clock plausibility window. A node cannot legitimately believe it is running
# before this software existed, and one that thinks it is decades ahead is just
# as broken. Used to decide whether the clock can be trusted to date a
# certificate — see the CLOCK section below.
CLOCK_FLOOR_EPOCH=1767225600   # 2026-01-01T00:00:00Z
CLOCK_CEIL_EPOCH=2713910400    # 2056-01-01T00:00:00Z
# How far back to date notBefore, so ordinary skew between this node and a
# client cannot make a freshly minted cert "not yet valid".
BACKDATE_SECONDS=86400

mkdir -p "$ROOT/var/lib/archipelago" "$ROOT/var/log"
NODE_NAME=$(hostname 2>/dev/null || echo archipelago)

log() { echo "$(date): $*" >> "$LOG"; }

# Test seam, same idea as FIRST_BOOT_SECRETS_ROOT: unset in production this is
# the real clock. A wrong clock is the whole subject of the CLOCK section and
# cannot be exercised otherwise.
now_epoch() { echo "${FIRST_BOOT_SECRETS_NOW:-$(date -u +%s)}"; }

# A terminal failure must be impossible to miss: journal, console and stderr,
# on top of the durable on-disk record. Every channel is guarded so that a
# missing /dev/console (test root, or an early boot without one) cannot itself
# make the failure path fail.
shout() {
    log "$*"
    if command -v logger >/dev/null 2>&1; then
        logger -t archipelago-first-boot-secrets "$*" 2>/dev/null || true
    fi
    if [ -w "$CONSOLE" ]; then
        printf '%s\n' "$*" | tee -a "$CONSOLE" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$*" >&2
}

# retry <label> <command...> — run the command up to N times with backoff.
retry() {
    local label="$1"; shift
    local -a waits
    # shellcheck disable=SC2206
    waits=($BACKOFF)
    local n=${#waits[@]}
    local i=1
    while [ "$i" -le "$n" ]; do
        if "$@"; then
            [ "$i" -gt 1 ] && log "$label succeeded on attempt $i of $n"
            return 0
        fi
        log "$label attempt $i of $n failed"
        if [ "$i" -lt "$n" ]; then
            sleep "${waits[$((i-1))]}" 2>/dev/null || true
        fi
        i=$((i+1))
    done
    return 1
}

# ── CLOCK ────────────────────────────────────────────────────────────────
#
# The failure fail-closed cannot catch, because generation SUCCEEDS.
#
# This unit runs very early (DefaultDependencies=no, Before=ssh/nginx), long
# before chrony has corrected the clock. `openssl req -x509` stamps notBefore
# from whatever the clock says. On a node with a dead RTC or a flat CMOS
# battery — routine on cheap SBCs — that can be years off:
#   - clock ahead  -> notBefore in the future -> clients reject the cert as
#                     "not yet valid", which is a harder failure than the usual
#                     self-signed warning;
#   - clock behind -> notAfter already in the past once time syncs -> expired.
# Either way the old code would have set the completion marker and never
# revisited it: a node permanently serving a certificate nothing accepts.
#
# NOT fixed by ordering After=time-sync.target. This image syncs time with
# chrony (installed and enabled), and chrony-wait.service — the unit that is
# Before=time-sync.target — is NOT enabled, so that target is inert here and
# the ordering would buy nothing. Enabling chrony-wait to make it meaningful
# would stall boot behind NTP on a node with no network, and these nodes are
# routinely offline at first boot. Not deadlocking boot outranks cert-date
# elegance, so ordering is left alone.
#
# Fixed instead by two cheap, local rules:
#   1. Backdate notBefore by BACKDATE_SECONDS so ordinary skew between this
#      node and a client cannot invalidate a fresh cert. Costs nothing: a
#      self-signed cert's notBefore is not a security control here.
#   2. Refuse to BLESS a cert minted under an implausible clock. The keypair is
#      still installed (the node stays usable and sshd comes up), but the
#      completion marker is withheld, so the self-heal timer revisits it and
#      regenerates once chrony has fixed the clock.
#
# Anti-spin, which is the thing to get right: a date-driven regeneration only
# happens when the clock is CURRENTLY plausible. A node whose clock is still
# wrong re-checks and does nothing — it never mints a fresh bad cert every 15
# minutes. See needs_tls().
clock_plausible() {
    local now; now=$(now_epoch)
    [ "$now" -ge "$CLOCK_FLOOR_EPOCH" ] && [ "$now" -le "$CLOCK_CEIL_EPOCH" ]
}

# Epoch of a certificate's notBefore / notAfter, or empty if unreadable.
cert_date_epoch() {
    local crt="$1" field="$2" raw
    raw=$(openssl x509 -noout "-$field" -in "$crt" 2>/dev/null | cut -d= -f2-)
    [ -n "$raw" ] || return 1
    date -u -d "$raw" +%s 2>/dev/null
}

# Is the installed cert dated sanely relative to the clock we trust now?
cert_dates_ok() {
    local crt="$1" nb na now
    [ -s "$crt" ] || return 1
    nb=$(cert_date_epoch "$crt" startdate) || return 1
    na=$(cert_date_epoch "$crt" enddate) || return 1
    [ -n "$nb" ] && [ -n "$na" ] || return 1
    now=$(now_epoch)
    # Minted before this software existed -> the clock was wrong when it was made.
    [ "$nb" -ge "$CLOCK_FLOOR_EPOCH" ] || return 1
    # Not yet valid, or already expired, against the clock we trust.
    [ "$nb" -le "$now" ] || return 1
    [ "$na" -gt "$now" ] || return 1
    return 0
}

# Do the key and the cert actually belong together?
#
# Parsing each half back proves each is well-formed; it does NOT prove they are
# a pair. A key from one generation beside a cert from another passes both
# individual checks, gets blessed, and then nginx refuses to start with a
# confusing error at the exact moment the marker claims everything succeeded.
# Extracting the public key from each half and comparing closes that: a stale
# cert can never be paired with a fresh key.
#
# Extraction subsumes parsing, so this replaces the separate -noout parse
# checks rather than adding to them. Note the asymmetry in the flags: `pkey`
# needs -pubout WITHOUT -noout (which would suppress the very output we want),
# while `x509` needs -noout WITH -pubkey.
#
# Kept deliberately identical in intent to regenerate_tls_cert() in
# core/archipelago/src/api/rpc/system/handlers.rs, which performs the same
# comparison on the running node.
tls_pair_matches() {
    local key="$1" crt="$2" kp cp
    kp=$(openssl pkey -in "$key" -pubout 2>> "$LOG") || return 1
    cp=$(openssl x509 -in "$crt" -noout -pubkey 2>> "$LOG") || return 1
    [ -n "$kp" ] || return 1
    [ "$kp" = "$cp" ]
}

# THE SINGLE PRODUCER of this node's first-boot TLS keypair, WITHIN THE ISO
# BUILD. No other code in the ISO build creates
# /etc/archipelago/ssl/archipelago.{key,crt}. Do not add one here; add a caller
# of this instead. tests/first-boot-secrets/run-tests.sh case 6 fails the test
# suite if a second producer appears in this builder.
#
# There IS a second, sanctioned producer at runtime:
# regenerate_tls_cert() in core/archipelago/src/api/rpc/system/handlers.rs
# re-mints the cert after `server.set-name`, so the SAN matches the node's new
# hostname. It is deliberately separate rather than unified with this function:
# unifying would mean either shipping an ISO build script as a runtime
# dependency of the RPC layer, or making a rename shell out to a build
# artefact. Two careful producers beat either of those.
#
# So if you are here to delete a "duplicate" — don't. What matters is that both
# producers stay careful and stay in step: stage to .new siblings, parse both
# halves back, prove they are a matching pair, then swap. Both emit rsa:2048
# for a self-signed LAN cert; do not let the key size or algorithm drift apart
# in one of them.
#
# Fresh keypair with this device's hostname in the SAN (server.set-name
# regenerates again if the node is renamed later). Generated to .new, PARSED
# BACK, and only then swapped in — so nginx can never be handed a truncated,
# zero-length or half-written artefact, which is the "never serve with a bogus
# key" half of fail-closed.
gen_tls() {
    mkdir -p "$SSL_DIR" || return 1
    rm -f "$SSL_DIR/archipelago.key.new" "$SSL_DIR/archipelago.crt.new"

    # Backdate notBefore when this openssl can. -not_before/-not_after arrived
    # in OpenSSL 3.5; the rootfs is debian:trixie, which ships 3.5, but this is
    # probed rather than assumed — guessing wrong would make every attempt fail
    # and brick the node, which is precisely the outcome all of this exists to
    # avoid. Without the flags we simply do not backdate; the plausibility rule
    # below still catches the dangerous case.
    local -a dateargs=(-days 3650)
    if openssl req -help 2>&1 | grep -q -- '-not_before'; then
        local now nb na
        now=$(now_epoch)
        nb=$(date -u -d "@$((now - BACKDATE_SECONDS))" +%Y%m%d%H%M%SZ 2>/dev/null || echo "")
        na=$(date -u -d "@$((now + 3650 * 86400))" +%Y%m%d%H%M%SZ 2>/dev/null || echo "")
        if [ -n "$nb" ] && [ -n "$na" ]; then
            dateargs=(-not_before "$nb" -not_after "$na")
        fi
    fi

    if openssl req -x509 -nodes "${dateargs[@]}" -newkey rsa:2048 \
        -keyout "$SSL_DIR/archipelago.key.new" \
        -out "$SSL_DIR/archipelago.crt.new" \
        -subj "/C=XX/ST=Bitcoin/L=Node/O=Archipelago/CN=${NODE_NAME}" \
        -addext "subjectAltName=DNS:${NODE_NAME},DNS:${NODE_NAME}.local,DNS:archipelago,DNS:archipelago.local,DNS:localhost,IP:127.0.0.1" \
        >> "$LOG" 2>&1 \
        && [ -s "$SSL_DIR/archipelago.key.new" ] \
        && [ -s "$SSL_DIR/archipelago.crt.new" ] \
        && tls_pair_matches "$SSL_DIR/archipelago.key.new" "$SSL_DIR/archipelago.crt.new"; then
        chmod 600 "$SSL_DIR/archipelago.key.new"
        if getent passwd archipelago >/dev/null 2>&1; then
            chgrp "$(id -gn archipelago)" "$SSL_DIR/archipelago.key.new" || return 1
            chmod 640 "$SSL_DIR/archipelago.key.new" || return 1
        fi
        mv "$SSL_DIR/archipelago.key.new" "$SSL_DIR/archipelago.key" \
            && mv "$SSL_DIR/archipelago.crt.new" "$SSL_DIR/archipelago.crt" || return 1
        # Keep staged permissions: nginx and the app gate both read this leaf.
        return 0
    fi
    rm -f "$SSL_DIR/archipelago.key.new" "$SSL_DIR/archipelago.crt.new"
    return 1
}

# THE SINGLE PRODUCER of this node's SSH host keys. Same rule as gen_tls: no
# second producer anywhere, add a caller instead.
#
# Generates a full fresh set in staging, then swaps.
gen_ssh() {
    local staging
    staging=$(mktemp -d) || return 1
    mkdir -p "$staging/etc/ssh"
    if ssh-keygen -A -f "$staging" >> "$LOG" 2>&1 \
        && ls "$staging"/etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
        mkdir -p "$SSH_DIR"
        rm -f "$SSH_DIR"/ssh_host_*
        mv "$staging"/etc/ssh/ssh_host_* "$SSH_DIR"/
        rm -rf "$staging"
        return 0
    fi
    rm -rf "$staging"
    return 1
}

# Hand the new material to whatever consumes it.
#
# Two different situations, and getting this wrong is what would turn the timer
# into theatre:
#   - First boot. We are ordered Before= these units, so they have not started
#     yet. try-reload-or-restart is a no-op on an inactive unit, which is
#     exactly right — they will start on their own moments later and read the
#     keys we just wrote.
#   - Self-heal, minutes or hours later. The unit already tried to start with no
#     key and is sitting in `failed`. try-reload-or-restart would be a no-op
#     there too, which would leave the node broken with valid keys on disk — the
#     recovery would be "complete" but the service still down. So a failed unit
#     is explicitly restarted.
# --no-block because on first boot we are inside a unit these services are
# ordered after; a blocking start could deadlock the boot transaction.
refresh_consumer() {
    local unit="$1"
    if systemctl is-failed --quiet "$unit" 2>/dev/null; then
        log "$unit is failed (it started without a key); restarting it"
        systemctl --no-block restart "$unit" >> "$LOG" 2>&1 || true
    else
        systemctl try-reload-or-restart "$unit" >> "$LOG" 2>&1 || true
    fi
}

# What needs generating right now?
#
# The marker means what it always meant: "this node has generated its own key
# material". Until it exists, whatever is on disk came from the shared image and
# MUST be replaced — that is F-03 and it outranks everything else here. Do not
# be tempted to make these functions purely content-based: a rootfs that still
# carried baked keys would then look "fine" and the fleet-shared key would
# survive first boot. That regression is caught by case 1, which prestages a
# baked key and asserts it was replaced.
needs_tls() {
    [ -f "$MARKER" ] || return 0
    [ -s "$SSL_DIR/archipelago.key" ] || return 0
    [ -s "$SSL_DIR/archipelago.crt" ] || return 0
    # Same pair check as before the swap, applied to what is actually installed.
    # A mismatched pair that reached disk some other way — an older build, a
    # half-finished manual edit — is repaired here instead of quietly breaking
    # nginx. One regeneration fixes it and the check then passes, so no spin.
    tls_pair_matches "$SSL_DIR/archipelago.key" "$SSL_DIR/archipelago.crt" || return 0
    # Bad dates are worth fixing ONLY when the clock can be trusted to do
    # better. This single condition is the entire anti-spin guard: a node whose
    # clock is still wrong re-checks and mints nothing.
    if clock_plausible && ! cert_dates_ok "$SSL_DIR/archipelago.crt"; then
        log "installed cert has implausible dates and the clock is now trustworthy; will regenerate"
        return 0
    fi
    return 1
}

needs_ssh() {
    [ -f "$MARKER" ] || return 0
    ls "$SSH_DIR"/ssh_host_*_key >/dev/null 2>&1 || return 0
    return 1
}

TLS_OK=1
SSH_OK=1

if needs_tls; then
    log "generating per-device TLS keypair"
    TLS_OK=0
    if retry "TLS keypair generation" gen_tls; then
        TLS_OK=1
        log "TLS keypair generated (CN=${NODE_NAME})"
        refresh_consumer nginx
    fi
fi

if needs_ssh; then
    log "generating per-device SSH host keys"
    SSH_OK=0
    if retry "SSH host key generation" gen_ssh; then
        SSH_OK=1
        log "SSH host keys generated"
        refresh_consumer ssh
    fi
fi

if [ "$TLS_OK" -eq 1 ] && [ "$SSH_OK" -eq 1 ]; then
    # The node now holds its own key material, so the marker goes down. It
    # means exactly what it has always meant — "generated locally, not the
    # image's" — and writing it here is what stops the next boot from
    # regenerating and churning the host key on every reboot.
    [ -f "$MARKER" ] || touch "$MARKER"

    # Separate question: can the clock that dated the cert be trusted? If not,
    # the material stays installed (the node is usable and sshd is up) but the
    # cert is flagged for regeneration once chrony fixes the clock. Silently
    # accepting it is how a node ends up permanently serving a cert nothing
    # accepts — generation SUCCEEDED, so fail-closed never sees it.
    if clock_plausible && cert_dates_ok "$SSL_DIR/archipelago.crt"; then
        # Clear any alarm left by an earlier run that failed and then recovered,
        # so a healthy node does not carry a stale record forever.
        rm -f "$FAILED"
        log "per-device secrets done"
        exit 0
    fi

    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
        echo "failed=cert-dates"
        echo "tls_ok=1"
        echo "ssh_ok=1"
        echo "clock_epoch=$(now_epoch)"
        echo "clock_plausible=$(clock_plausible && echo yes || echo no)"
        echo "detail=key material is installed and the node is usable, but the certificate was dated by a clock outside the plausible window; it will be regenerated automatically once time syncs"
    } > "$FAILED"
    log "clock not trustworthy ($(now_epoch)); cert flagged for regeneration once time syncs"
    # Deliberately exit 0: nothing failed, the node is serving, and we are
    # waiting on NTP. Failing the unit here would cry wolf on every boot of an
    # offline node and bury the real failures.
    exit 0
fi

# Fail closed on serving, self-heal on recovering.
#
# Deliberately NO marker. Its absence is the entire retry mechanism:
# archipelago-first-boot-secrets.timer re-runs this in 15 minutes and every
# subsequent boot re-runs it too. This is a failure, not a dead end — do not
# "fix" it by writing the marker.
WHICH=""
[ "$TLS_OK" -eq 0 ] && WHICH="TLS"
[ "$SSH_OK" -eq 0 ] && WHICH="${WHICH:+$WHICH and }SSH"
{
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    echo "failed=$WHICH"
    echo "tls_ok=$TLS_OK"
    echo "ssh_ok=$SSH_OK"
    echo "detail=per-device secret generation failed after all retries; the completion marker was NOT set, so archipelago-first-boot-secrets.timer retries in 15 minutes and every subsequent boot retries too"
} > "$FAILED"
shout "ARCHIPELAGO: could not generate this device's $WHICH key material. The affected services will NOT start rather than run on a key we did not generate. Retrying automatically every 15 minutes and on every boot. Record: $FAILED  Log: $LOG"
exit 1
SECRETSSCRIPT

chmod +x "$WORK_DIR/first-boot-secrets.sh"
cp "$WORK_DIR/first-boot-secrets.sh" "$ARCH_DIR/scripts/"
cp "$WORK_DIR/archipelago-first-boot-secrets.service" "$ARCH_DIR/scripts/"
cp "$WORK_DIR/archipelago-first-boot-secrets.timer" "$ARCH_DIR/scripts/"

# Ship the mesh-radio udev rule at the media root — the embedded installer
# searches "$BOOT_MEDIA/99-mesh-radio.rules" first, but nothing ever staged
# the rule into the ISO tree, so installed nodes never got /dev/mesh-radio
if [ -f "$SCRIPT_DIR/../configs/99-mesh-radio.rules" ]; then
    cp "$SCRIPT_DIR/../configs/99-mesh-radio.rules" "$INSTALLER_ISO/99-mesh-radio.rules"
fi

# Tor setup: copy torrc and create first-boot setup script
mkdir -p "$ARCH_DIR/scripts/tor"
if [ -f "$SCRIPT_DIR/../../scripts/tor/torrc.template" ]; then
    cp "$SCRIPT_DIR/../../scripts/tor/torrc.template" "$ARCH_DIR/scripts/tor/torrc"
fi

echo "   Creating first-boot Tor setup service..."
cat > "$WORK_DIR/archipelago-setup-tor.service" <<'TORSERVICE'
[Unit]
Description=Setup and start Archipelago Tor hidden services
After=archipelago-load-images.service network.target podman.service
ConditionPathExists=/opt/archipelago/scripts/setup-tor.sh

[Service]
Type=oneshot
ExecStart=/opt/archipelago/scripts/setup-tor.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
TORSERVICE

cat > "$WORK_DIR/setup-tor.sh" <<'TORSCRIPT'
#!/bin/bash
# Setup and start Tor hidden services (autoinstaller first-boot)
# Prefers system Tor (apt package) over container

ARCHY_TOR_DIR="/var/lib/archipelago/tor"
TOR_CONFIG_DIR="/var/lib/archipelago/tor-config"
TOR_DIR="/var/lib/tor"
LOG="/var/log/archipelago-tor.log"

mkdir -p "$ARCHY_TOR_DIR" "$TOR_CONFIG_DIR"

# First boot only: seed services.json + torrc. The unit runs on EVERY boot
# (oneshot, multi-user.target), and rewriting these unconditionally clobbered
# hidden services the backend added after app installs. Only the node's own
# service is pre-baked — apps get their hidden service created on install
# (auto_add_tor_service / tor.create-service), never pre-created for apps
# that may never be installed (issue #79).
if [ ! -f "$TOR_CONFIG_DIR/services.json" ]; then
cat > "$ARCHY_TOR_DIR/services.json" <<TORJSON
{
  "services": [
    {"name": "archipelago", "local_port": 80, "enabled": true}
  ]
}
TORJSON
echo "services.json created"
# Backend reads from tor-config/, not tor/
cp "$ARCHY_TOR_DIR/services.json" "$TOR_CONFIG_DIR/services.json"
chown -R archipelago:archipelago "$TOR_CONFIG_DIR" 2>/dev/null || true

# Generate torrc — use /var/lib/tor/ for hidden services (AppArmor-safe)
cat > /etc/tor/torrc <<TORRC
SocksPort 0.0.0.0:9050
SocksPolicy accept 10.89.0.0/16
SocksPolicy accept 127.0.0.0/8
SocksPolicy reject *
# ControlPort disabled for security

HiddenServiceDir $TOR_DIR/hidden_service_archipelago
HiddenServicePort 80 127.0.0.1:80

HiddenServiceDir $TOR_DIR/hidden_service_relay
HiddenServicePort 7777 127.0.0.1:7777
TORRC
else
    echo "$(date): tor already initialized — leaving services.json/torrc alone" >> "$LOG"
fi

# Create hidden service dirs with correct ownership and permissions (700, not 750)
# Tor refuses to start if permissions are too permissive
for svc in archipelago relay; do
    mkdir -p "$TOR_DIR/hidden_service_$svc"
    chown debian-tor:debian-tor "$TOR_DIR/hidden_service_$svc"
    chmod 700 "$TOR_DIR/hidden_service_$svc"
done

# Prefer system Tor (installed via apt)
if command -v tor >/dev/null 2>&1; then
    echo "$(date): Using system Tor daemon" >> "$LOG"
    systemctl enable tor 2>/dev/null
    systemctl restart tor@default 2>/dev/null
else
    # Fallback: use container
    echo "$(date): System Tor not found, using container" >> "$LOG"
    DOCKER=podman
    command -v podman >/dev/null 2>&1 || DOCKER=docker
    for c in $(sudo $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'archy-tor|^tor$'); do
        [ -n "$c" ] && sudo $DOCKER stop "$c" 2>/dev/null; sudo $DOCKER rm -f "$c" 2>/dev/null
    done
    if ! sudo $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -q archy-tor; then
        sudo $DOCKER run -d --name archy-tor --restart unless-stopped --network host \
            -v "$TOR_DIR:$TOR_DIR" \
            --entrypoint tor \
            ${ALPINE_TOR_IMAGE} \
            -f /etc/tor/torrc >> "$LOG" 2>&1
        echo "$(date): Tor container started" >> "$LOG"
    fi
fi

# Wait for Tor to create hostname files (~30-60s), then chmod so archipelago user can read
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 6
    if [ -f "$TOR_DIR/hidden_service_archipelago/hostname" ]; then
        chmod 750 "$TOR_DIR"/hidden_service_*/ 2>/dev/null || true
        for f in "$TOR_DIR"/hidden_service_*/hostname; do
            [ -f "$f" ] && chmod 640 "$f" && echo "$(date): chmod hostname $f" >> "$LOG"
        done
        echo "$(date): Tor hostname files readable by archipelago" >> "$LOG"
        break
    fi
done

# Sync hostnames to backend-readable directory
HOSTNAMES_DIR="/var/lib/archipelago/tor-hostnames"
mkdir -p "$HOSTNAMES_DIR"
for svc in archipelago relay; do
    if [ -f "$TOR_DIR/hidden_service_${svc}/hostname" ]; then
        cp "$TOR_DIR/hidden_service_${svc}/hostname" "$HOSTNAMES_DIR/$svc"
        echo "$(date): Synced hostname: $svc" >> "$LOG"
    fi
done
chown -R archipelago:archipelago "$HOSTNAMES_DIR" 2>/dev/null || true
echo "$(date): Hostnames synced: $(ls $HOSTNAMES_DIR 2>/dev/null | tr '\n' ' ')" >> "$LOG"
TORSCRIPT

chmod +x "$WORK_DIR/setup-tor.sh"
cp "$WORK_DIR/setup-tor.sh" "$ARCH_DIR/scripts/"
cp "$WORK_DIR/archipelago-setup-tor.service" "$ARCH_DIR/scripts/"

# First-boot: create core containers (bitcoin, mempool, btcpay, lnd, fedimint, homeassistant)
# Both bundled and unbundled builds use the full first-boot script.
# Unbundled mode pulls images from registry; bundled mode loads from tarballs.
if false && [ "$UNBUNDLED" = "1" ]; then
    echo "   Creating minimal first-boot service (UNBUNDLED: FileBrowser only)..."
    # DISABLED: minimal script doesn't create UI sidecars or write app configs.
    # The full first-boot-containers.sh handles both bundled and unbundled modes.
    cat > "$WORK_DIR/first-boot-containers-unbundled.sh" <<'FBUNBUNDLED'
#!/bin/bash
# Minimal first-boot: create FileBrowser container only (unbundled ISO)
set -e
LOG="/var/log/archipelago-first-boot.log"
echo "[$(date)] Starting minimal first-boot (unbundled)..." >> "$LOG"

# Source image versions (provides $FILEBROWSER_IMAGE etc.)
for f in /opt/archipelago/scripts/image-versions.sh /home/archipelago/archy/scripts/image-versions.sh; do
    if [ -f "$f" ]; then
        source "$f"
        echo "[$(date)] Sourced image versions from $f" >> "$LOG"
        break
    fi
done

if [ -z "$FILEBROWSER_IMAGE" ]; then
    echo "[$(date)] ERROR: FILEBROWSER_IMAGE not set — image-versions.sh missing or incomplete" >> "$LOG"
    exit 1
fi

# Create Cloud storage directories (as root, then fix ownership for rootless podman)
mkdir -p /var/lib/archipelago/filebrowser
mkdir -p /var/lib/archipelago/filebrowser-data
mkdir -p /var/lib/archipelago/data/cloud/{Documents,Photos,Music,Videos,Downloads}
# Container UID 0 maps to host UID 100000 under rootless podman (subuid mapping)
chown -R 100000:100000 /var/lib/archipelago/filebrowser
chown -R 100000:100000 /var/lib/archipelago/filebrowser-data
chown -R 100000:100000 /var/lib/archipelago/data

# Enable linger so rootless podman containers survive logout
loginctl enable-linger archipelago 2>/dev/null || true

# Enable podman-restart so containers with --restart=unless-stopped auto-start on boot
runuser -u archipelago -- bash -c 'export XDG_RUNTIME_DIR=/run/user/1000 && systemctl --user enable podman-restart.service' 2>>"$LOG" || true

# Ensure podman socket is active for archipelago user
runuser -u archipelago -- bash -c 'export XDG_RUNTIME_DIR=/run/user/1000 && systemctl --user enable --now podman.socket' 2>>"$LOG" || true

# Provision the same unique verified Cloud login used by app installation/OTA.
if ! runuser -u archipelago -- env XDG_RUNTIME_DIR=/run/user/1000 podman container exists filebrowser; then
    install -d -o 100000 -g 100000 /var/lib/archipelago/filebrowser /var/lib/archipelago/filebrowser-data
    install -d -o archipelago -g archipelago -m 700 /var/lib/archipelago/secrets/filebrowser
    runuser -u archipelago -- env XDG_RUNTIME_DIR=/run/user/1000 \
        python3 /opt/archipelago/scripts/filebrowser-credentials.py --image "$FILEBROWSER_IMAGE" >>"$LOG" 2>&1 || exit 1
    runuser -u archipelago -- env XDG_RUNTIME_DIR=/run/user/1000 podman run -d \
        --name filebrowser --restart unless-stopped \
        --cap-drop=ALL --cap-add=DAC_OVERRIDE --cap-add=NET_BIND_SERVICE \
        --security-opt=no-new-privileges:true \
        --tmpfs=/tmp:rw,noexec,nosuid,size=64m \
        --health-cmd='wget -q --spider http://localhost:80/health || exit 1' \
        --health-interval=30s --health-timeout=5s --health-retries=3 \
        --memory=256m -p 127.0.0.1:8083:80 \
        -v /var/lib/archipelago/filebrowser:/srv \
        -v /var/lib/archipelago/filebrowser-data:/data \
        -v /var/lib/archipelago/data/cloud:/srv/cloud \
        "$FILEBROWSER_IMAGE" --config /data/.filebrowser.json >>"$LOG" 2>&1 || exit 1
fi
echo "[$(date)] Minimal first-boot complete" >> "$LOG"
FBUNBUNDLED
    chmod +x "$WORK_DIR/first-boot-containers-unbundled.sh"
    cp "$WORK_DIR/first-boot-containers-unbundled.sh" "$ARCH_DIR/scripts/first-boot-containers.sh"

    # Copy shared script library (TUI animations for installer, shared utils)
    if [ -d "$SCRIPT_DIR/../../scripts/lib" ]; then
        mkdir -p "$ARCH_DIR/scripts/lib"
        cp "$SCRIPT_DIR/../../scripts/lib/"*.sh "$ARCH_DIR/scripts/lib/" 2>/dev/null || true
        echo "   Copied scripts/lib/ ($(ls "$ARCH_DIR/scripts/lib/" 2>/dev/null | wc -l) files)"
    fi

    cat > "$WORK_DIR/archipelago-first-boot-containers.service" <<'FBCSERVICE'
[Unit]
Description=Create core Archipelago containers on first boot
After=archipelago-load-images.service archipelago-setup-tor.service network-online.target podman.service
Wants=archipelago-load-images.service
ConditionPathExists=/opt/archipelago/scripts/first-boot-containers.sh
ConditionPathExists=!/var/lib/archipelago/.first-boot-containers-done

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=/opt/archipelago/scripts/first-boot-containers.sh
ExecStartPost=/usr/bin/touch /var/lib/archipelago/.first-boot-containers-done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FBCSERVICE
    cp "$WORK_DIR/archipelago-first-boot-containers.service" "$ARCH_DIR/scripts/"
else
    echo "   Creating first-boot container creation service..."
    # Copy shared script library
    if [ -d "$SCRIPT_DIR/../../scripts/lib" ]; then
        mkdir -p "$ARCH_DIR/scripts/lib"
        cp "$SCRIPT_DIR/../../scripts/lib/"*.sh "$ARCH_DIR/scripts/lib/" 2>/dev/null || true
    fi
    if [ -f "$SCRIPT_DIR/../../scripts/first-boot-containers.sh" ]; then
        cp "$SCRIPT_DIR/../../scripts/first-boot-containers.sh" "$ARCH_DIR/scripts/"
        chmod +x "$ARCH_DIR/scripts/first-boot-containers.sh"
        cat > "$WORK_DIR/archipelago-first-boot-containers.service" <<'FBCSERVICE'
[Unit]
Description=Create core Archipelago containers on first boot
After=archipelago-load-images.service archipelago-setup-tor.service network-online.target podman.service
Wants=archipelago-load-images.service
ConditionPathExists=/opt/archipelago/scripts/first-boot-containers.sh
ConditionPathExists=!/var/lib/archipelago/.first-boot-containers-done

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=/opt/archipelago/scripts/first-boot-containers.sh
ExecStartPost=/usr/bin/touch /var/lib/archipelago/.first-boot-containers-done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FBCSERVICE
        cp "$WORK_DIR/archipelago-first-boot-containers.service" "$ARCH_DIR/scripts/"
    fi
fi

# Bootstrap node config — new installs use this Bitcoin node during IBD
# so ElectrumX/LND/BTCPay/Mempool work immediately while local chain syncs
# Tries LAN first (fast), falls back to Tor (works from anywhere)
BOOTSTRAP_RPC_PASS=""
BOOTSTRAP_ONION=""
if [ -f /var/lib/archipelago/secrets/bitcoin-rpc-password ]; then
    BOOTSTRAP_RPC_PASS=$(cat /var/lib/archipelago/secrets/bitcoin-rpc-password 2>/dev/null)
fi
if [ -f /var/lib/archipelago/tor-hostnames/bitcoin ]; then
    BOOTSTRAP_ONION=$(cat /var/lib/archipelago/tor-hostnames/bitcoin 2>/dev/null)
fi
if [ -n "$BOOTSTRAP_RPC_PASS" ]; then
    DEV_IP="${DEV_SERVER:-192.0.2.10}"
    cat > "$ARCH_DIR/bootstrap.conf" <<BSTRAP
# Bootstrap Bitcoin node — used during Initial Block Download
# Services connect here until the local node is fully synced
# First-boot tries LAN, then Tor (works from any network)
BOOTSTRAP_LAN_HOST=${DEV_IP}
BOOTSTRAP_ONION=${BOOTSTRAP_ONION}
BOOTSTRAP_RPC_USER=archipelago
BOOTSTRAP_RPC_PASS=${BOOTSTRAP_RPC_PASS}
BSTRAP
    chmod 600 "$ARCH_DIR/bootstrap.conf"
    echo "   ✅ Bootstrap node config embedded (LAN: ${DEV_IP}, Tor: ${BOOTSTRAP_ONION:-none})"
else
    echo "   ⚠  No bootstrap config — no Bitcoin RPC password found on build host"
fi

# Bundle bootstrap switchover script + systemd timer
if [ -f "$SCRIPT_DIR/../../scripts/bootstrap-switchover.sh" ]; then
    cp "$SCRIPT_DIR/../../scripts/bootstrap-switchover.sh" "$ARCH_DIR/scripts/"
    chmod +x "$ARCH_DIR/scripts/bootstrap-switchover.sh"
    echo "   ✅ Bundled bootstrap switchover script"
fi

# Bundle E2E test script for post-install validation
if [ -f "$SCRIPT_DIR/../../scripts/run-e2e-tests.sh" ]; then
    cp "$SCRIPT_DIR/../../scripts/run-e2e-tests.sh" "$ARCH_DIR/scripts/"
    chmod +x "$ARCH_DIR/scripts/run-e2e-tests.sh"
    echo "   ✅ Bundled E2E test script for post-install validation"
fi
if [ -f "$SCRIPT_DIR/../../scripts/run-post-install-tests.sh" ]; then
    cp "$SCRIPT_DIR/../../scripts/run-post-install-tests.sh" "$ARCH_DIR/scripts/"
    chmod +x "$ARCH_DIR/scripts/run-post-install-tests.sh"
    echo "   ✅ Bundled post-install test suite"
fi

# Bundle self-update script and image-versions for update system
if [ -f "$SCRIPT_DIR/../../scripts/self-update.sh" ]; then
    cp "$SCRIPT_DIR/../../scripts/self-update.sh" "$ARCH_DIR/scripts/"
    chmod +x "$ARCH_DIR/scripts/self-update.sh"
    echo "   ✅ Bundled self-update script"
fi
if [ -f "$SCRIPT_DIR/../../scripts/image-versions.sh" ]; then
    cp "$SCRIPT_DIR/../../scripts/image-versions.sh" "$ARCH_DIR/scripts/"
    echo "   ✅ Bundled image-versions.sh"
fi

# Always overlay the current doctor, including when rootfs.tar is cached.
cp "$SCRIPT_DIR/../../scripts/container-doctor.sh" "$ARCH_DIR/scripts/"
cp "$SCRIPT_DIR/../configs/archipelago-doctor.service" "$ARCH_DIR/scripts/"
cp "$SCRIPT_DIR/../configs/archipelago-doctor.timer" "$ARCH_DIR/scripts/"
for npm_file in dashboard-public-guard.py npm-public-bridge.py sync-npm-public-hosts.sh filebrowser-credentials.py; do
    cp "$SCRIPT_DIR/../../scripts/$npm_file" "$ARCH_DIR/scripts/"
done
for npm_unit in archipelago-npm-bridge.service archipelago-npm-bridge.timer; do
    cp "$SCRIPT_DIR/../configs/$npm_unit" "$ARCH_DIR/scripts/"
done

# Build-source apps need their complete contexts even on unbundled ISOs.
# Keep this identical to the OTA runtime payload; a per-app allowlist silently
# omitted GitWorkshop, FIPS and Cuprate and made fresh installs fail at 70%.
DOCKER_UI_DIR="$SCRIPT_DIR/../../docker"
[ -d "$DOCKER_UI_DIR" ] || { echo "Missing docker build sources" >&2; exit 1; }
mkdir -p "$ARCH_DIR/docker"
cp -a "$DOCKER_UI_DIR/." "$ARCH_DIR/docker/"
python3 "$SCRIPT_DIR/../../scripts/check-app-build-contexts.py" "$ARCH_DIR"

if [ "$UNBUNDLED" = "1" ]; then
    echo "   ✅ Unbundled build ready (Tor setup included, no container images)"
else
    echo "   ✅ Container images bundled (including Tor + first-boot)"
fi

# =============================================================================
# STEP 4: Create auto-installer script
# =============================================================================
echo ""
echo "📦 Step 4: Creating auto-installer..."

cat > "$ARCH_DIR/auto-install.sh" <<'INSTALLER_SCRIPT'
#!/bin/bash
#
# Archipelago Auto-Installer
# Automatically installs to internal disk (StartOS-like experience)
#

set -e

# Log file — verbose command output goes here, TUI stays on console
INSTALL_LOG="/tmp/archipelago-install.log"
# Run commands quietly: redirect their stdout/stderr to log
# TUI functions (p, step, ok, etc.) print directly to console
run() { "$@" >> "$INSTALL_LOG" 2>&1; }
runq() { "$@" >>"$INSTALL_LOG" 2>&1 || true; }

# Detect architecture at install time
case "$(uname -m)" in
    x86_64|amd64)
        ARCH="x86_64"
        GRUB_TARGET="x86_64-efi"
        GRUB_BIOS_TARGET="i386-pc"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        GRUB_TARGET="arm64-efi"
        GRUB_BIOS_TARGET=""
        ;;
esac

# Colors — 256-color ANSI (works on Linux fbcon console)
ORANGE=$'\033[38;5;208m'
ORANGE_DIM=$'\033[38;5;130m'
ORANGE_BRIGHT=$'\033[38;5;214m'
RED=$'\033[31m'
GREEN=$'\033[32m'
WHITE=$'\033[1;37m'
DIM=$'\033[38;5;242m'
DIMMER=$'\033[38;5;238m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# Left-justified layout — 2-space indent, no centering
PADS="  "

p() { printf "%s%b\n" "$PADS" "$1"; }
hrule() { local hr=""; for i in $(seq 1 48); do hr="${hr}─"; done; p "${ORANGE_DIM}${hr}${NC}"; }

# Typewriter animation for key text
typewrite() {
    local text="$1" delay="${2:-0.02}"
    printf "%s" "$PADS"
    local i=0
    while [ $i -lt ${#text} ]; do
        printf "%s" "${text:$i:1}"
        i=$((i + 1))
        sleep "$delay"
    done
    printf "\n"
}

# Phase display
STEP=0
TOTAL_STEPS=8
step() {
    STEP=$((STEP + 1))
    echo ""
    p "${ORANGE}[$STEP/$TOTAL_STEPS]  $1${NC}"
}
ok() { p "  ${ORANGE_BRIGHT}✓ $1${NC}"; }
warn() { p "  ${ORANGE}⚠ $1${NC}"; }
fail() { p "  ${RED}✗ $1${NC}"; }
spinner() {
    local pid=$1 msg=$2
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s  %b%s %s%b" "$PADS" "$ORANGE" "${frames:i%10:1}" "$msg" "$NC"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r%s  %b✓ %s%b\n" "$PADS" "$ORANGE_BRIGHT" "$msg" "$NC"
}

# Source TUI library for install animations (graceful fallback if missing)
for _tui_path in \
    "$BOOT_MEDIA/archipelago/scripts/lib/install-tui.sh" \
    "/opt/archipelago/scripts/lib/install-tui.sh" \
    "$(dirname "$0")/../../scripts/lib/install-tui.sh"; do
    [ -f "$_tui_path" ] && { source "$_tui_path" 2>/dev/null; break; }
done

if [ "${TUI_AVAILABLE:-}" = "1" ]; then
    tui_welcome
    tui_enable_progress_spinner
else
    clear
    echo ""
    echo -e "${PADS}${ORANGE}▄▀█ █▀▄ █▀▀ █ █ █ █▀█ █▀▀ █   ▄▀█ █▀▀ █▀█${NC}"
    echo -e "${PADS}${ORANGE}█▀█ █▀▄ █   █▀█ █ █▀▀ ██▀ █   █▀█ █ █ █ █${NC}"
    echo -e "${PADS}${ORANGE}▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀   ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀${NC}"
    typewrite "$(echo -e "${ORANGE_DIM}bitcoin node os${NC}")" 0.04
    echo ""
fi

# Check required tools are present (should be bundled in ISO)
step "Checking tools"
MISSING=""
command -v parted >/dev/null 2>&1 || MISSING="parted $MISSING"
command -v mkfs.vfat >/dev/null 2>&1 || MISSING="mkfs.vfat $MISSING"
command -v mkfs.ext4 >/dev/null 2>&1 || MISSING="mkfs.ext4 $MISSING"

if [ -n "$MISSING" ]; then
    warn "Installing missing: $MISSING"
    if apt-get update -qq >/dev/null 2>&1; then
        apt-get install -y -qq parted dosfstools e2fsprogs >/dev/null 2>&1 && ok "Tools installed" || {
            fail "Failed to install required tools"
            exit 1
        }
    else
        fail "No network available and tools not bundled"
        exit 1
    fi
else
    ok "All tools present"
fi

# Find boot media
BOOT_MEDIA=""
for dev in /run/archiso /cdrom /media/cdrom /run/live/medium /lib/live/mount/medium /mnt/iso; do
    if [ -d "$dev/archipelago" ]; then
        BOOT_MEDIA="$dev"
        break
    fi
done

if [ -z "$BOOT_MEDIA" ]; then
    echo -e "${RED}❌ Boot media not found${NC}"
    exit 1
fi

ROOTFS_TAR="$BOOT_MEDIA/archipelago/rootfs.tar"
if [ ! -f "$ROOTFS_TAR" ]; then
    echo -e "${RED}❌ Root filesystem not found: $ROOTFS_TAR${NC}"
    exit 1
fi

# Find the boot USB device to exclude it
BOOT_DEV=$(findmnt -n -o SOURCE "$BOOT_MEDIA" 2>/dev/null | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
BOOT_DEV_NAME=$(basename "$BOOT_DEV" 2>/dev/null || echo "")

step "Detecting disks"
echo ""

# Find internal disk (prefer NVMe, then SATA, skip USB)
TARGET_DISK=""
TARGET_SIZE=""

# Check NVMe drives first
for disk in /dev/nvme*n1; do
    if [ -b "$disk" ]; then
        disk_name=$(basename "$disk")
        if [ "$disk_name" != "$BOOT_DEV_NAME" ]; then
            size=$(lsblk -dn -o SIZE "$disk" 2>/dev/null)
            model=$(cat /sys/block/$disk_name/device/model 2>/dev/null || echo "NVMe SSD")
            echo "   Found: $disk ($size) - $model"
            TARGET_DISK="$disk"
            TARGET_SIZE="$size"
            break
        fi
    fi
done

# If no NVMe, check SATA drives
if [ -z "$TARGET_DISK" ]; then
    for disk in /dev/sd[a-z]; do
        if [ -b "$disk" ]; then
            disk_name=$(basename "$disk")
            if [ "$disk_name" != "$BOOT_DEV_NAME" ]; then
                # Skip USB drives (check removable flag)
                removable=$(cat /sys/block/$disk_name/removable 2>/dev/null || echo "0")
                if [ "$removable" = "0" ]; then
                    size=$(lsblk -dn -o SIZE "$disk" 2>/dev/null)
                    model=$(cat /sys/block/$disk_name/device/model 2>/dev/null || echo "SATA Drive")
                    echo "   Found: $disk ($size) - $model"
                    TARGET_DISK="$disk"
                    TARGET_SIZE="$size"
                    break
                fi
            fi
        fi
    done
fi

if [ -z "$TARGET_DISK" ]; then
    echo ""
    echo -e "${RED}❌ No suitable internal disk found${NC}"
    echo "   Please ensure an internal drive is connected."
    exit 1
fi

ok "$TARGET_DISK ($TARGET_SIZE)"
echo ""
hrule
echo ""
p "${ORANGE}  ⚠  all data on $TARGET_DISK will be erased${NC}"
echo ""
p "${ORANGE_DIM}  press enter to install  |  ctrl+c to cancel${NC}"
read -s
echo ""

# Unmount any existing partitions
umount ${TARGET_DISK}* 2>/dev/null || true
umount ${TARGET_DISK}p* 2>/dev/null || true

# Create partition table — dual BIOS+UEFI boot + LUKS2 encrypted data
step "Creating partitions"
parted -s "$TARGET_DISK" mklabel gpt
# Partition 1: 1MB BIOS boot partition (for legacy BIOS GRUB on GPT disks)
parted -s "$TARGET_DISK" mkpart bios_boot 1MiB 2MiB
parted -s "$TARGET_DISK" set 1 bios_grub on
# Partition 2: 512MB EFI System Partition (for UEFI boot)
parted -s "$TARGET_DISK" mkpart efi fat32 2MiB 514MiB
parted -s "$TARGET_DISK" set 2 esp on
# Partition 3: Root filesystem (30GB — system, packages, container runtime)
parted -s "$TARGET_DISK" mkpart root ext4 514MiB 30GiB
# Partition 4: Encrypted data (LUKS2 — Bitcoin data, secrets, app volumes)
parted -s "$TARGET_DISK" mkpart data 30GiB 100%

sleep 2

# Determine partition names
if [[ "$TARGET_DISK" == *nvme* ]]; then
    BIOS_PART="${TARGET_DISK}p1"
    EFI_PART="${TARGET_DISK}p2"
    ROOT_PART="${TARGET_DISK}p3"
    DATA_PART="${TARGET_DISK}p4"
else
    BIOS_PART="${TARGET_DISK}1"
    EFI_PART="${TARGET_DISK}2"
    ROOT_PART="${TARGET_DISK}3"
    DATA_PART="${TARGET_DISK}4"
fi

# Format partitions
step "Formatting partitions"
# Zero out the BIOS boot partition to prevent FAT-fs read errors during boot
dd if=/dev/zero of="$BIOS_PART" bs=1M count=1 2>/dev/null || true
run mkfs.vfat -F32 -n EFI "$EFI_PART"
run mkfs.ext4 -F -L archipelago "$ROOT_PART"

# Mount root + extract rootfs (need cryptsetup from rootfs for LUKS)
ok "Partitions created"
echo ""
p "  ${ORANGE_DIM}Mounting filesystems...${NC}"
mkdir -p /mnt/target
mount "$ROOT_PART" /mnt/target
mkdir -p /mnt/target/boot/efi
mount "$EFI_PART" /mnt/target/boot/efi

step "Installing system"
run tar -xf "$ROOTFS_TAR" -C /mnt/target

# LUKS2 encryption for data partition
step "Encrypting data partition"

# Generate random 4KB key file
dd if=/dev/urandom of=/mnt/target/root/.luks-archipelago.key bs=4096 count=1 2>/dev/null
chmod 600 /mnt/target/root/.luks-archipelago.key

# Load dm_mod kernel module (required for device-mapper / LUKS)
modprobe dm_mod 2>/dev/null || true
modprobe dm_crypt 2>/dev/null || true

# Bind-mount /dev, /proc, /sys so cryptsetup works in chroot
mount --bind /dev /mnt/target/dev
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys

# Detect AES-NI support for cipher selection
if grep -q aes /proc/cpuinfo 2>/dev/null; then
    LUKS_CIPHER="aes-xts-plain64"
    echo "   AES-NI detected — using AES-256-XTS"
else
    LUKS_CIPHER="xchacha20,aes-adiantum-plain64"
    echo "   No AES-NI — using ChaCha20-Adiantum"
fi

# Format LUKS2 partition with key file
run chroot /mnt/target cryptsetup luksFormat --type luks2 \
    --key-file /root/.luks-archipelago.key \
    --cipher "$LUKS_CIPHER" --key-size 512 \
    --pbkdf argon2id --batch-mode \
    "$DATA_PART"

# Open the LUKS volume
run chroot /mnt/target cryptsetup open --type luks2 \
    --key-file /root/.luks-archipelago.key \
    "$DATA_PART" archipelago-data

# Unmount chroot bind mounts (will be re-mounted later for grub-install)
runq umount /mnt/target/sys
runq umount /mnt/target/proc
runq umount /mnt/target/dev

# Format the inner filesystem
run mkfs.ext4 -F -L archipelago-data /dev/mapper/archipelago-data

# Mount encrypted partition
mkdir -p /mnt/target/var/lib/archipelago
mount /dev/mapper/archipelago-data /mnt/target/var/lib/archipelago

# Recreate directory structure on encrypted partition
mkdir -p /mnt/target/var/lib/archipelago/{data,config,containers,secrets,tor,identities,lnd,nostr-relay,nostr-vpn,tor-hostnames,wireguard}
mkdir -p /mnt/target/var/lib/archipelago/containers/storage
mkdir -p /mnt/target/var/lib/archipelago/data/cloud/{Documents,Photos,Music,Videos,Downloads}
# Copy relay config from rootfs (LUKS mount hides what the Dockerfile put there)
if [ -f /mnt/target/etc/archipelago/nostr-relay-config.toml ]; then
  cp /mnt/target/etc/archipelago/nostr-relay-config.toml /mnt/target/var/lib/archipelago/nostr-relay/config.toml
fi
chown -R 1000:1000 /mnt/target/var/lib/archipelago

echo "   ✅ Data partition encrypted with LUKS2 ($LUKS_CIPHER)"

# Allocate swap space on the encrypted data partition. Without swap, large
# container image builds (immich, indeedhub) and brief memory spikes can
# OOM-kill containers or trigger cgroup cascades. Sized to RAM, capped at
# 8GB (above which swap is rarely useful), floored at 2GB so even
# constrained nodes have headroom. Lives on the LUKS partition so it's
# encrypted at rest.
step "Allocating swap"
RAM_MB=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024))
SWAP_MB=$RAM_MB
[ "$SWAP_MB" -lt 2048 ] && SWAP_MB=2048
[ "$SWAP_MB" -gt 8192 ] && SWAP_MB=8192
SWAPFILE=/mnt/target/var/lib/archipelago/swapfile
echo "   Allocating ${SWAP_MB}MB swap at /var/lib/archipelago/swapfile"
run dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=none
run chmod 600 "$SWAPFILE"
run mkswap "$SWAPFILE"
echo "   ✅ ${SWAP_MB}MB swap allocated"

# Configure auto-unlock via crypttab (key file on root partition)
step "Configuring system"
DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
echo "# LUKS2 encrypted data — auto-unlock with key file" > /mnt/target/etc/crypttab
echo "archipelago-data UUID=$DATA_UUID /root/.luks-archipelago.key luks,discard" >> /mnt/target/etc/crypttab

# Configure LUKS auto-unlock: three layers to ensure it works
# Layer 1: cryptsetup-initramfs config (tells update-initramfs to embed key)
mkdir -p /mnt/target/etc/cryptsetup-initramfs
cat > /mnt/target/etc/cryptsetup-initramfs/conf <<'CRYPTCONF'
KEYFILE_PATTERN="/root/.luks-*.key"
UMASK=0077
CRYPTCONF

# Layer 2: initramfs hook to force-copy key file
mkdir -p /mnt/target/etc/initramfs-tools/hooks
cat > /mnt/target/etc/initramfs-tools/hooks/archipelago-luks <<'LUKSHOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
if [ -f /root/.luks-archipelago.key ]; then
    mkdir -p "${DESTDIR}/root"
    cp /root/.luks-archipelago.key "${DESTDIR}/root/.luks-archipelago.key"
    chmod 600 "${DESTDIR}/root/.luks-archipelago.key"
fi
if [ -f /etc/crypttab ]; then
    mkdir -p "${DESTDIR}/etc"
    cp /etc/crypttab "${DESTDIR}/etc/crypttab"
fi
copy_exec /sbin/cryptsetup
LUKSHOOK
chmod +x /mnt/target/etc/initramfs-tools/hooks/archipelago-luks

# Layer 3: systemd service as fallback — unlocks LUKS early if initramfs missed it
cat > /mnt/target/etc/systemd/system/archipelago-luks-unlock.service <<'LUKSUNIT'
[Unit]
Description=Unlock Archipelago LUKS data partition
DefaultDependencies=no
Before=local-fs-pre.target
After=systemd-udevd.service
Wants=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  if [ -e /dev/mapper/archipelago-data ]; then exit 0; fi; \
  DATA_DEV=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1); \
  if [ -z "$DATA_DEV" ]; then exit 0; fi; \
  cryptsetup open --type luks2 --key-file /root/.luks-archipelago.key "$DATA_DEV" archipelago-data'

[Install]
WantedBy=local-fs-pre.target
LUKSUNIT
chroot /mnt/target systemctl enable archipelago-luks-unlock.service 2>/dev/null || \
    ln -sf /etc/systemd/system/archipelago-luks-unlock.service /mnt/target/etc/systemd/system/local-fs-pre.target.wants/archipelago-luks-unlock.service

# Create fstab
cat > /mnt/target/etc/fstab <<EOF
# Archipelago Bitcoin Node OS
UUID=$(blkid -s UUID -o value "$ROOT_PART")  /                    ext4  errors=remount-ro  0  1
UUID=$(blkid -s UUID -o value "$EFI_PART")   /boot/efi            vfat  umask=0077         0  1
/dev/mapper/archipelago-data                 /var/lib/archipelago  ext4  defaults,nofail,x-systemd.device-timeout=60  0  2
# Swap on encrypted data partition — activated after LUKS unlock
/var/lib/archipelago/swapfile                none                 swap  sw,nofail  0  0
EOF

# Configure hostname
echo "archipelago" > /mnt/target/etc/hostname
cat > /mnt/target/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   archipelago
::1         localhost ip6-localhost ip6-loopback
EOF
chmod 644 /mnt/target/etc/hosts

# Pre-create container storage dirs (ReadWritePaths needs these to exist)
mkdir -p /mnt/target/home/archipelago/.local/share/containers
mkdir -p /mnt/target/home/archipelago/.config/containers
chown -R 1000:1000 /mnt/target/home/archipelago/.local

# Redirect container storage to encrypted LUKS partition (not root filesystem)
# Without this, pulling images fills the 29GB root partition
cat > /mnt/target/home/archipelago/.config/containers/storage.conf <<'STORAGECONF'
[storage]
driver = "overlay"
graphroot = "/var/lib/archipelago/containers/storage"
runroot = "/run/user/1000/containers"
STORAGECONF

# Symlink for backward compat (some tools look in ~/.local/share/containers)
ln -sf /var/lib/archipelago/containers/storage /mnt/target/home/archipelago/.local/share/containers/storage 2>/dev/null || true

# Configure Archipelago app registries (primary + fallback)
cat > /mnt/target/home/archipelago/.config/containers/registries.conf <<'REGCONF'
unqualified-search-registries = ["docker.io"]

[[registry]]
location = "source.archipelago-foundation.org"
insecure = true

[[registry]]
location = "source.archipelago-foundation.org"
insecure = true
REGCONF
chown -R 1000:1000 /mnt/target/home/archipelago/.config

# Pre-create dynamic registry config for the backend (fallback registries)
mkdir -p /mnt/target/var/lib/archipelago/config
cat > /mnt/target/var/lib/archipelago/config/registries.json <<'DYNREG'
{
  "registries": [
    {"url": "source.archipelago-foundation.org/lfg2025", "name": "Archipelago Primary", "tls_verify": false, "enabled": true, "priority": 0},
    {"url": "source.archipelago-foundation.org/lfg2025", "name": "Archipelago Fallback", "tls_verify": true, "enabled": true, "priority": 10}
  ]
}
DYNREG
chown -R 1000:1000 /mnt/target/var/lib/archipelago/config

# Configure podman to use netavark backend (enables container DNS on archy-net).
# netavark + aardvark-dns binaries come from the rootfs (Debian 13 apt packages).
if [ -f /mnt/target/usr/lib/podman/netavark ]; then
    mkdir -p /mnt/target/home/archipelago/.config/containers
    cat > /mnt/target/home/archipelago/.config/containers/containers.conf <<'CONTAINERSCONF'
[network]
network_backend = "netavark"
default_rootless_network_cmd = "pasta"

[engine]
image_copy_tmp_dir = "/var/lib/archipelago/containers/tmp"
CONTAINERSCONF
    mkdir -p /mnt/target/var/lib/archipelago/containers/tmp
    chown -R 1000:1000 /mnt/target/var/lib/archipelago/containers/tmp
    chown -R 1000:1000 /mnt/target/home/archipelago/.config/containers
    echo "   Configured netavark backend (container DNS enabled)"
else
    echo "   WARNING: netavark not found in rootfs — container DNS will not work"
fi

# Laptop support: ignore lid close so server keeps running
mkdir -p /mnt/target/etc/systemd/logind.conf.d
cat > /mnt/target/etc/systemd/logind.conf.d/lid-ignore.conf <<'LIDCONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LIDCONF

# Kiosk appliance: a short press or accidental brush of the power button used
# to shut the node down instantly (confirmed on a Framework node — "Power key
# pressed short -> Powering off"). Ignore the short press; keep a deliberate
# long press (hold ~2s) as the intentional power-off, so the node isn't taken
# down by accident but can still be shut down on purpose without a keyboard.
cat > /mnt/target/etc/systemd/logind.conf.d/power-key.conf <<'PWRCONF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
PWRCONF

# Copy Archipelago binaries and files
if [ -d "$BOOT_MEDIA/archipelago/bin" ]; then
    cp -r "$BOOT_MEDIA/archipelago/bin/"* /mnt/target/usr/local/bin/ 2>/dev/null || true
    chmod +x /mnt/target/usr/local/bin/* 2>/dev/null || true
fi

# Required even when the cached rootfs never had esptool installed.
install -m 755 "$BOOT_MEDIA/archipelago/bin/archy-esptool" /mnt/target/usr/local/bin/archy-esptool || exit 1
chroot /mnt/target /usr/local/bin/archy-esptool --archy-self-test || exit 1

if [ -d "$BOOT_MEDIA/archipelago/web-ui" ]; then
    cp -r "$BOOT_MEDIA/archipelago/web-ui" /mnt/target/opt/archipelago/
fi

# Mark unbundled mode so first-boot only creates FileBrowser (user installs apps from Marketplace)
if [ -f "$BOOT_MEDIA/archipelago/.unbundled" ]; then
    touch /mnt/target/opt/archipelago/.unbundled
    echo "   Unbundled mode: apps install on-demand from Marketplace"
fi

if [ -d "$BOOT_MEDIA/archipelago/apps" ]; then
    cp -r "$BOOT_MEDIA/archipelago/apps" /mnt/target/etc/archipelago/
    # The backend loads disk manifests from /opt/archipelago/apps — copying
    # only to /etc/archipelago/apps left fresh installs with ZERO manifests,
    # so any app not covered by the signed catalog (e.g. netbird) could not
    # install at all. Ship them where the orchestrator actually looks.
    mkdir -p /mnt/target/opt/archipelago/apps
    cp -r "$BOOT_MEDIA/archipelago/apps/." /mnt/target/opt/archipelago/apps/
fi

# Copy pre-bundled container images
if [ -d "$BOOT_MEDIA/archipelago/container-images" ]; then
    echo "   Copying container images (this may take a moment)..."
    mkdir -p /mnt/target/opt/archipelago/container-images
    cp -r "$BOOT_MEDIA/archipelago/container-images/"*.tar* /mnt/target/opt/archipelago/container-images/ 2>/dev/null || true
    
    # Copy first-boot loader script and service
    mkdir -p /mnt/target/opt/archipelago/scripts
    if [ -f "$BOOT_MEDIA/archipelago/scripts/load-container-images.sh" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/load-container-images.sh" /mnt/target/opt/archipelago/scripts/
        chmod +x /mnt/target/opt/archipelago/scripts/load-container-images.sh
    fi
    
    if [ -f "$BOOT_MEDIA/archipelago/scripts/archipelago-load-images.service" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/archipelago-load-images.service" /mnt/target/etc/systemd/system/
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/first-boot-secrets.sh" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/first-boot-secrets.sh" /mnt/target/opt/archipelago/scripts/
        chmod +x /mnt/target/opt/archipelago/scripts/first-boot-secrets.sh
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-secrets.service" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-secrets.service" /mnt/target/etc/systemd/system/
    fi
    # The self-heal timer. Without it a node whose generators fail every in-boot
    # retry has no unattended way back — it would need someone at the console.
    if [ -f "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-secrets.timer" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-secrets.timer" /mnt/target/etc/systemd/system/
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/setup-tor.sh" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/setup-tor.sh" /mnt/target/opt/archipelago/scripts/
        chmod +x /mnt/target/opt/archipelago/scripts/setup-tor.sh
    fi
    if [ -d "$BOOT_MEDIA/archipelago/scripts/tor" ]; then
        mkdir -p /mnt/target/opt/archipelago/scripts/tor
        cp -r "$BOOT_MEDIA/archipelago/scripts/tor/"* /mnt/target/opt/archipelago/scripts/tor/ 2>/dev/null || true
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/archipelago-setup-tor.service" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/archipelago-setup-tor.service" /mnt/target/etc/systemd/system/
    fi
    # Copy shared script library
    if [ -d "$BOOT_MEDIA/archipelago/scripts/lib" ]; then
        mkdir -p /mnt/target/opt/archipelago/scripts/lib
        cp -r "$BOOT_MEDIA/archipelago/scripts/lib/"* /mnt/target/opt/archipelago/scripts/lib/ 2>/dev/null || true
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/first-boot-containers.sh" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/first-boot-containers.sh" /mnt/target/opt/archipelago/scripts/
        chmod +x /mnt/target/opt/archipelago/scripts/first-boot-containers.sh
    fi
    if [ -f "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-containers.service" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/archipelago-first-boot-containers.service" /mnt/target/etc/systemd/system/
    fi
    # Copy docker UI source files for first-boot container builds
    if [ -d "$BOOT_MEDIA/archipelago/docker" ]; then
        mkdir -p /mnt/target/opt/archipelago/docker
        cp -r "$BOOT_MEDIA/archipelago/docker/"* /mnt/target/opt/archipelago/docker/ 2>/dev/null || true
    fi

    echo "   ✅ Container images staged for first-boot loading"
fi

# Initialize backend data directories for seamless first boot
mkdir -p /mnt/target/var/lib/archipelago/tor-config
mkdir -p /mnt/target/var/lib/archipelago/identities
mkdir -p /mnt/target/var/lib/archipelago/lnd

# Copy test scripts for post-install validation
for test_script in run-e2e-tests.sh run-post-install-tests.sh; do
    if [ -f "$BOOT_MEDIA/archipelago/scripts/$test_script" ]; then
        cp "$BOOT_MEDIA/archipelago/scripts/$test_script" /mnt/target/opt/archipelago/scripts/
        chmod +x /mnt/target/opt/archipelago/scripts/$test_script
    fi
done

# BEGIN DOCTOR OVERLAY
# Replace both the active and historical script locations before first boot.
# A cached rootfs can contain the unsafe network recovery implementation.
mkdir -p /mnt/target/opt/archipelago/scripts /mnt/target/home/archipelago/archy/scripts
for doctor_dir in /mnt/target/opt/archipelago/scripts /mnt/target/home/archipelago/archy/scripts; do
    install -m 755 "$BOOT_MEDIA/archipelago/scripts/container-doctor.sh" "$doctor_dir/container-doctor.sh" || exit 1
done
for doctor_unit in archipelago-doctor.service archipelago-doctor.timer; do
    install -m 644 "$BOOT_MEDIA/archipelago/scripts/$doctor_unit" "/mnt/target/etc/systemd/system/$doctor_unit" || exit 1
done
for npm_file in dashboard-public-guard.py npm-public-bridge.py sync-npm-public-hosts.sh filebrowser-credentials.py; do
    install -m 755 "$BOOT_MEDIA/archipelago/scripts/$npm_file" "/mnt/target/opt/archipelago/scripts/$npm_file" || exit 1
done
for npm_unit in archipelago-npm-bridge.service archipelago-npm-bridge.timer; do
    install -m 644 "$BOOT_MEDIA/archipelago/scripts/$npm_unit" "/mnt/target/etc/systemd/system/$npm_unit" || exit 1
done
systemctl --root=/mnt/target enable archipelago-npm-bridge.timer || exit 1
# END DOCTOR OVERLAY

# Copy self-update script
if [ -f "$BOOT_MEDIA/archipelago/scripts/self-update.sh" ]; then
    cp "$BOOT_MEDIA/archipelago/scripts/self-update.sh" /mnt/target/opt/archipelago/scripts/
    chmod +x /mnt/target/opt/archipelago/scripts/self-update.sh
    # Also place in home for the update timer to find
    mkdir -p /mnt/target/home/archipelago/archy/scripts
    cp "$BOOT_MEDIA/archipelago/scripts/self-update.sh" /mnt/target/home/archipelago/archy/scripts/
    chmod +x /mnt/target/home/archipelago/archy/scripts/self-update.sh
fi

# Copy image-versions.sh (needed by first-boot-containers and updates)
if [ -f "$BOOT_MEDIA/archipelago/scripts/image-versions.sh" ]; then
    cp "$BOOT_MEDIA/archipelago/scripts/image-versions.sh" /mnt/target/opt/archipelago/scripts/
    chmod +x /mnt/target/opt/archipelago/scripts/image-versions.sh
    # Also place in home for container scripts to find
    mkdir -p /mnt/target/home/archipelago/archy/scripts
    cp "$BOOT_MEDIA/archipelago/scripts/image-versions.sh" /mnt/target/home/archipelago/archy/scripts/
fi

# Clone repo for git-based updates (first-boot will have network)
# Create a script that runs on first boot to clone the repo
cat > /mnt/target/opt/archipelago/scripts/setup-git-updates.sh <<'GITSETUP'
#!/bin/bash
# Clone the Archipelago repo for git-based self-updates
REPO_DIR="/home/archipelago/archy"
if [ -d "$REPO_DIR/.git" ]; then
    exit 0  # Already cloned
fi
echo "[update] Cloning Archipelago repo for self-updates..."
su - archipelago -c "git clone https://source.archipelago-foundation.org/lfg2025/archy $REPO_DIR" 2>/dev/null || {
    echo "[update] Git clone failed (network?). Updates will retry on next boot."
    exit 0
}
chown -R 1000:1000 "$REPO_DIR"
echo "[update] Repo cloned. Self-updates enabled."
GITSETUP
chmod +x /mnt/target/opt/archipelago/scripts/setup-git-updates.sh

# Ensure correct ownership (use numeric UID:GID 1000:1000 since we're outside chroot)
chown -R 1000:1000 /mnt/target/opt/archipelago 2>/dev/null || true
chown -R 1000:1000 /mnt/target/var/lib/archipelago 2>/dev/null || true

# Create welcome profile (nginx serves on port 80)
cat > /mnt/target/etc/profile.d/archipelago.sh <<'PROFILE'
#!/bin/bash
# Ensure /sbin and /usr/sbin are in PATH (needed for reboot, shutdown, etc.)
case ":$PATH:" in
    *:/sbin:*) ;; *) export PATH="$PATH:/sbin:/usr/sbin" ;;
esac
if [ -t 0 ] && [ -z "$ARCHIPELAGO_WELCOMED" ]; then
    export ARCHIPELAGO_WELCOMED=1

    # Wait for network (DHCP may not be ready yet on first boot).
    # The address shown must be one a LAN user can actually reach: the
    # default route's source address. `hostname -I` lists addresses in
    # interface order, so a node with WireGuard up advertised 10.44.0.1 —
    # its own tunnel address, present on EVERY node — as its "web ui",
    # which is unreachable off-tunnel and actively misleading after a
    # move to a new network (framework-pt, 2026-08-15).
    IP=""
    for i in 1 2 3 4 5; do
        IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)
        # Offline LAN (no default route): first address that is not a
        # tunnel (10.44/16 WireGuard), CGNAT (100.64/10 Tailscale), or
        # loopback one.
        [ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -vE '^(10\.44\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.)' | head -n1)
        [ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$IP" ] && break
        sleep 2
    done

    O='\033[38;5;208m'
    OD='\033[38;5;130m'
    W='\033[1;37m'
    N='\033[0m'

    # The logo uses UTF-8 block-drawing glyphs. Switching back from the kiosk
    # (Xorg on vt1) can leave the console VT out of UTF-8 mode, which renders
    # them as garbage bytes ("sometimes corrupt"). ESC % G forces the VT into
    # UTF-8 mode so the logo always draws correctly.
    printf '\033%%G' 2>/dev/null || true
    clear
    echo -e "  ${O}▄▀█ █▀▄ █▀▀ █ █ █ █▀█ █▀▀ █   ▄▀█ █▀▀ █▀█${N}"
    echo -e "  ${O}█▀█ █▀▄ █   █▀█ █ █▀▀ ██▀ █   █▀█ █ █ █ █${N}"
    echo -e "  ${O}▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀ ▀   ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀${N}"
    echo -e "                              ${OD}bitcoin node os${N}"
    if [ -n "$IP" ]; then
        echo -e "  ${W}web ui    http://$IP${N}"
        # The mDNS name survives any DHCP change — it is the address to
        # give people for a headless box that moves between networks.
        if systemctl is-active avahi-daemon >/dev/null 2>&1; then
            echo -e "  ${W}          http://$(hostname).local${N}"
        fi
        echo -e "  ${W}ssh       archipelago@$IP${N}"
        echo -e "  ${W}password  archipelago (SSH)${N}"
        echo -e "  ${OD}web ui asks you to create a password on first visit${N}"
    else
        echo -e "  ${OD}Waiting for network...${N}"
    fi
    if [ -b /dev/mapper/archipelago-data ] || [ -b /dev/mapper/archipelago_crypt ]; then
        echo -e "  ${OD}storage   LUKS2 encrypted${N}"
    fi
    # The kiosk's Xorg runs on vt1 (see archipelago-kiosk-launcher: "Xorg :0
    # vt1"), so Ctrl+Alt+F1 IS the kiosk and a terminal is on another VT (F2,
    # where systemd auto-spawns a getty). The old hints had these backwards —
    # they sent you to an empty black VT7 and there was no way back to the kiosk.
    if systemctl is-active archipelago-kiosk.service >/dev/null 2>&1; then
        echo -e "  ${OD}display   Kiosk active (Ctrl+Alt+F2 for terminal)${N}"
    else
        echo -e "  ${OD}display   Console (Ctrl+Alt+F1 for kiosk)${N}"
    fi
    echo ""
fi
PROFILE
chmod +x /mnt/target/etc/profile.d/archipelago.sh

# Force UTF-8 console with Terminus font (supports Unicode block chars for ASCII logo)
cat > /mnt/target/etc/default/console-setup <<'CONSOLESETUP'
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="Uni2"
FONTFACE="Terminus"
FONTSIZE="16"
CONSOLESETUP

# Suppress default Debian MOTD (our profile.d script handles the welcome)
echo -n > /mnt/target/etc/motd
rm -f /mnt/target/etc/motd.d/* 2>/dev/null || true

# Ensure reboot/shutdown work without sudo for the archipelago user
# profile.d only runs for login shells; .bashrc handles SSH interactive sessions
if ! grep -q '/sbin' /mnt/target/home/archipelago/.bashrc 2>/dev/null; then
    echo 'export PATH="$PATH:/sbin:/usr/sbin"' >> /mnt/target/home/archipelago/.bashrc
fi
# Power commands need sudo on SSH sessions (polkit denies without local seat)
if ! grep -q 'alias reboot' /mnt/target/home/archipelago/.bashrc 2>/dev/null; then
    cat >> /mnt/target/home/archipelago/.bashrc <<'ALIASES'
alias reboot='sudo systemctl reboot'
alias shutdown='sudo shutdown'
alias halt='sudo systemctl halt'
alias poweroff='sudo systemctl poweroff'
ALIASES
fi

# Systemd service: the canonical unit shipped on the ISO (archipelago/configs/)
# ALWAYS wins over the rootfs copy — the rootfs tar is a cached build artifact
# that can predate unit fixes (B17: without RequiresMountsFor=/var/lib/archipelago
# the service races the LUKS data mount on cold boot and "[FAILED]"-loops for
# minutes on every fresh install).
if [ -f "$BOOT_MEDIA/archipelago/configs/archipelago.service" ]; then
    cp "$BOOT_MEDIA/archipelago/configs/archipelago.service" /mnt/target/etc/systemd/system/archipelago.service
    echo "   Installed archipelago.service from ISO configs (overrides rootfs copy)"
elif [ ! -f /mnt/target/etc/systemd/system/archipelago.service ]; then
    echo "   WARNING: archipelago.service missing from rootfs and ISO configs"
fi

# Claude API proxy — middleware that injects max_tokens, strips invalid fields
# API key must be set after install via setup-aiui-server.sh or manually
cat > /mnt/target/opt/archipelago/claude-api-proxy.py <<'CLAUDEPROXY'
#!/usr/bin/env python3
import http.server, json, ssl, sys, os, urllib.request, urllib.error
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
PORT = 3142
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/health":
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
            self.wfile.write(b'{"status":"ok"}'); return
        cl = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(cl)
        try: data = json.loads(body)
        except: data = {}
        if "max_tokens" not in data: data["max_tokens"] = 8096
        for f in ["webSearch","web_search"]: data.pop(f, None)
        # Normalize model IDs — map short/dotted names to full API model IDs
        MODEL_MAP = {
            "claude-haiku-4.5": "claude-haiku-4-5-20251001",
            "claude-haiku-4-5": "claude-haiku-4-5-20251001",
            "claude-sonnet-4": "claude-sonnet-4-20250514",
            "claude-sonnet-4.5": "claude-sonnet-4-5-20250514",
            "claude-sonnet-4-5": "claude-sonnet-4-5-20250514",
            "claude-opus-4": "claude-opus-4-20250514",
        }
        m = data.get("model", "")
        if m in MODEL_MAP: data["model"] = MODEL_MAP[m]
        body = json.dumps(data).encode()
        if not API_KEY:
            err = json.dumps({"type":"error","error":{"type":"auth_error","message":"AIUI not configured. Set your Anthropic API key in Settings > AIUI to enable AI chat."}}).encode()
            self.send_response(401); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(err))); self.end_headers(); self.wfile.write(err); return
        headers = {"Content-Type":"application/json","x-api-key":API_KEY,"anthropic-version":"2023-06-01","anthropic-dangerous-direct-browser-access":"true"}
        for h in ["anthropic-version","anthropic-beta"]:
            if self.headers.get(h): headers[h] = self.headers[h]
        req = urllib.request.Request("https://api.anthropic.com"+self.path, data=body, headers=headers, method="POST")
        try:
            ctx = ssl.create_default_context()
            resp = urllib.request.urlopen(req, context=ctx, timeout=300)
            self.send_response(resp.status)
            is_stream = "text/event-stream" in (resp.headers.get("Content-Type","") or "")
            for k,v in resp.headers.items():
                if k.lower() not in ("transfer-encoding","connection"): self.send_header(k,v)
            if is_stream: self.send_header("Transfer-Encoding","chunked")
            self.end_headers()
            if is_stream:
                while True:
                    chunk = resp.read(4096)
                    if not chunk: break
                    self.wfile.write(b"%x\r\n" % len(chunk)); self.wfile.write(chunk); self.wfile.write(b"\r\n"); self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            else: self.wfile.write(resp.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(json.dumps({"error":str(e)}).encode())
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
        else: self.send_response(404); self.end_headers()
    def log_message(self, fmt, *args): pass
if not API_KEY: print("WARNING: ANTHROPIC_API_KEY not set — AIUI will return setup instructions")
server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
print(f"Claude API proxy on port {PORT}")
server.serve_forever()
CLAUDEPROXY
chmod +x /mnt/target/opt/archipelago/claude-api-proxy.py

# Claude API proxy systemd service (disabled by default — enabled after API key is configured)
cat > /mnt/target/etc/systemd/system/claude-api-proxy.service <<'CLAUDESVC'
[Unit]
Description=Claude API Proxy
After=network.target

[Service]
Type=simple
Environment=ANTHROPIC_API_KEY=
ExecStart=/usr/bin/python3 /opt/archipelago/claude-api-proxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
CLAUDESVC

INSTALLER_SCRIPT

# -----------------------------------------------------------------------------
# Kiosk launcher + systemd service: spliced into auto-install.sh at BUILD time
# from image-recipe/configs/ — the single source of truth (the same files are
# embedded in the Rust binary via include_str! in core/archipelago/src/bootstrap.rs
# and self-healed onto nodes by ensure_kiosk_hardened()).
#
# A previous inline heredoc copy here had silently diverged (unconditional
# --disable-gpu, no CPU/memory limits, VT7 scheme) and shipped stale kiosk
# behavior on fresh ISOs. Never re-inline these payloads.
# -----------------------------------------------------------------------------
KIOSK_LAUNCHER_SRC="$SCRIPT_DIR/../configs/archipelago-kiosk-launcher.sh"
KIOSK_SERVICE_SRC="$SCRIPT_DIR/../configs/archipelago-kiosk.service"
for _kiosk_src in "$KIOSK_LAUNCHER_SRC" "$KIOSK_SERVICE_SRC"; do
    if [ ! -f "$_kiosk_src" ]; then
        echo "ERROR: kiosk config file missing: $_kiosk_src" >&2
        echo "       The ISO must ship the maintained kiosk launcher/service from" >&2
        echo "       image-recipe/configs/ — refusing to build (no stale fallback)." >&2
        exit 1
    fi
done
# Guard: payloads must not contain the heredoc terminators we wrap them in.
if grep -qx 'KIOSKLAUNCHER' "$KIOSK_LAUNCHER_SRC" || grep -qx 'KIOSKSVC' "$KIOSK_SERVICE_SRC"; then
    echo "ERROR: kiosk config contains a reserved heredoc terminator line (KIOSKLAUNCHER/KIOSKSVC)" >&2
    exit 1
fi
{
    echo "# Kiosk mode — X11 + Chromium fullscreen on attached display"
    echo "# Not enabled by default; toggle via: sudo archipelago-kiosk enable/disable"
    echo "# Payloads spliced at ISO-build time from image-recipe/configs/ (source of truth)."
    echo "cat > /mnt/target/usr/local/bin/archipelago-kiosk-launcher <<'KIOSKLAUNCHER'"
    cat "$KIOSK_LAUNCHER_SRC"
    echo "KIOSKLAUNCHER"
    echo "chmod +x /mnt/target/usr/local/bin/archipelago-kiosk-launcher"
    echo ""
    echo "cat > /mnt/target/etc/systemd/system/archipelago-kiosk.service <<'KIOSKSVC'"
    cat "$KIOSK_SERVICE_SRC"
    echo "KIOSKSVC"
} >> "$ARCH_DIR/auto-install.sh"

# Audio router: same splice-from-configs/ pattern as the kiosk (single source
# of truth, also embedded in the binary for bootstrap self-heal). Keeps HDMI
# audio working: profile/default-sink routing + the ELD boot-race re-modeset.
AUDIO_ROUTER_SRC="$SCRIPT_DIR/../configs/archipelago-audio-router.sh"
AUDIO_SERVICE_SRC="$SCRIPT_DIR/../configs/archipelago-audio-router.service"
for _audio_src in "$AUDIO_ROUTER_SRC" "$AUDIO_SERVICE_SRC"; do
    if [ ! -f "$_audio_src" ]; then
        echo "ERROR: audio config file missing: $_audio_src" >&2
        exit 1
    fi
done
if grep -qx 'AUDIOROUTER' "$AUDIO_ROUTER_SRC" || grep -qx 'AUDIOSVC' "$AUDIO_SERVICE_SRC"; then
    echo "ERROR: audio config contains a reserved heredoc terminator line (AUDIOROUTER/AUDIOSVC)" >&2
    exit 1
fi
{
    echo ""
    echo "# Audio router — HDMI profile/default-sink follow + ELD boot-race heal."
    echo "# Payloads spliced at ISO-build time from image-recipe/configs/ (source of truth)."
    echo "cat > /mnt/target/usr/local/bin/archipelago-audio-router <<'AUDIOROUTER'"
    cat "$AUDIO_ROUTER_SRC"
    echo "AUDIOROUTER"
    echo "chmod +x /mnt/target/usr/local/bin/archipelago-audio-router"
    echo ""
    echo "cat > /mnt/target/etc/systemd/system/archipelago-audio-router.service <<'AUDIOSVC'"
    cat "$AUDIO_SERVICE_SRC"
    echo "AUDIOSVC"
} >> "$ARCH_DIR/auto-install.sh"

# Gamepad->keyboard bridge: same pattern (configs/ single source of truth,
# also self-healed via the binary). TV input for every app iframe.
GAMEPAD_SRC="$SCRIPT_DIR/../configs/archipelago-gamepad-keys.py"
GAMEPAD_SERVICE_SRC="$SCRIPT_DIR/../configs/archipelago-gamepad-keys.service"
for _pad_src in "$GAMEPAD_SRC" "$GAMEPAD_SERVICE_SRC"; do
    if [ ! -f "$_pad_src" ]; then
        echo "ERROR: gamepad config file missing: $_pad_src" >&2
        exit 1
    fi
done
if grep -qx 'GAMEPADPY' "$GAMEPAD_SRC" || grep -qx 'GAMEPADSVC' "$GAMEPAD_SERVICE_SRC"; then
    echo "ERROR: gamepad config contains a reserved heredoc terminator line (GAMEPADPY/GAMEPADSVC)" >&2
    exit 1
fi
{
    echo ""
    echo "# Gamepad->keyboard bridge — controller input inside every app iframe on the TV."
    echo "cat > /mnt/target/usr/local/bin/archipelago-gamepad-keys <<'GAMEPADPY'"
    cat "$GAMEPAD_SRC"
    echo "GAMEPADPY"
    echo "chmod +x /mnt/target/usr/local/bin/archipelago-gamepad-keys"
    echo ""
    echo "cat > /mnt/target/etc/systemd/system/archipelago-gamepad-keys.service <<'GAMEPADSVC'"
    cat "$GAMEPAD_SERVICE_SRC"
    echo "GAMEPADSVC"
} >> "$ARCH_DIR/auto-install.sh"

cat >> "$ARCH_DIR/auto-install.sh" <<'INSTALLER_SCRIPT'

# Toggle script: sudo archipelago-kiosk enable|disable|status
cat > /mnt/target/usr/local/bin/archipelago-kiosk <<'KIOSKTOGGLE'
#!/bin/bash
set -e

case "${1:-status}" in
    enable)
        echo "Enabling kiosk mode (X11 + Chromium on display)..."
        systemctl enable archipelago-kiosk.service
        systemctl start archipelago-kiosk.service 2>/dev/null || true
        echo "Kiosk mode ENABLED. Console login (tty1) is now disabled."
        echo "To access the server, use SSH or the web UI."
        ;;
    disable)
        echo "Disabling kiosk mode (restoring console login)..."
        systemctl stop archipelago-kiosk.service 2>/dev/null || true
        systemctl disable archipelago-kiosk.service
        systemctl restart getty@tty1.service 2>/dev/null || true
        echo "Kiosk mode DISABLED. Console login restored on tty1."
        ;;
    status)
        if systemctl is-active archipelago-kiosk.service >/dev/null 2>&1; then
            echo "Kiosk mode: ACTIVE (display showing web UI)"
        elif systemctl is-enabled archipelago-kiosk.service >/dev/null 2>&1; then
            echo "Kiosk mode: ENABLED (will start on next boot)"
        else
            echo "Kiosk mode: DISABLED (console login on tty1)"
        fi
        ;;
    toggle)
        if systemctl is-active archipelago-kiosk.service >/dev/null 2>&1; then
            systemctl stop archipelago-kiosk.service 2>/dev/null || true
            systemctl restart getty@tty1.service 2>/dev/null || true
            chvt 1 2>/dev/null || true
        else
            systemctl start archipelago-kiosk.service 2>/dev/null || true
        fi
        ;;
    *)
        echo "Usage: archipelago-kiosk [enable|disable|status|toggle]"
        echo "  enable  — Start kiosk (fullscreen web UI on display)"
        echo "  disable — Stop kiosk, restore console login"
        echo "  toggle  — Switch between kiosk and terminal"
        echo "  status  — Show current mode"
        echo ""
        echo "Keyboard shortcuts (from terminal):"
        echo "  Ctrl+Alt+F1  — Kiosk display (when enabled; console login when disabled)"
        echo "  Ctrl+Alt+F2  — Text console"
        exit 1
        ;;
esac
KIOSKTOGGLE
chmod +x /mnt/target/usr/local/bin/archipelago-kiosk

# Install GRUB
step "Installing bootloader"
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
mount --bind /run /mnt/target/run

# Set passwords reliably by directly editing /etc/shadow
# chpasswd fails silently in chroot due to missing PAM — use sed instead
echo "   Setting user passwords..."
# Pre-computed SHA-512 hash of "archipelago"
ARCHY_HASH='$6$archipelago.salt1$QpB5VPzGHOKRVKQ5cTfd4R7PYqmMH5MUx6MxFN7MbZkxWKR3WxFp.RV4tBVbJiv.6iWXfHeq3vDph7G.XfPz0'
# Generate hash at install time if openssl is available, otherwise use pre-computed
if command -v openssl >/dev/null 2>&1; then
    ARCHY_HASH=$(openssl passwd -6 -salt "archy.install" "archipelago")
fi
# Direct shadow file manipulation — works without PAM
sed -i "s|^archipelago:[^:]*:|archipelago:${ARCHY_HASH}:|" /mnt/target/etc/shadow
sed -i "s|^root:[^:]*:|root:${ARCHY_HASH}:|" /mnt/target/etc/shadow
# Verify the password was set (not locked/empty)
if grep -q "^archipelago:[!*]" /mnt/target/etc/shadow 2>/dev/null; then
    echo "   WARNING: Password still locked, trying chpasswd fallback..."
    chroot /mnt/target bash -c 'echo "archipelago:archipelago" | chpasswd' 2>/dev/null || true
fi
echo "   Passwords set for archipelago and root users"

# Remove shim-signed before grub-install to prevent hooks re-creating shim files
chroot /mnt/target dpkg --purge shim-signed shim-helpers-amd64-signed shim-helpers-arm64-signed 2>/dev/null || true

# UEFI boot: install to fallback path (/EFI/BOOT/BOOTX64.EFI) for maximum compatibility
echo "   Installing UEFI bootloader..."
if run chroot /mnt/target grub-install --target=${GRUB_TARGET} --efi-directory=/boot/efi --bootloader-id=archipelago --removable; then
    ok "UEFI bootloader installed (removable/fallback path)"
else
    warn "UEFI removable install failed, trying standard..."
    if run chroot /mnt/target grub-install --target=${GRUB_TARGET} --efi-directory=/boot/efi --bootloader-id=archipelago; then
        ok "UEFI bootloader installed (standard)"
    else
        fail "UEFI bootloader installation failed"
    fi
fi

# EFI boot: grub-install --removable places unsigned GRUB at /EFI/BOOT/BOOTX64.EFI
# No shim chain — Secure Boot must be disabled. shim-signed was removed from rootfs
# because it installs BOOTX64.CSV + shimx64.efi which cause "Failed to open \EFI\BOOT\"
# errors with garbled filenames on every boot.
echo "   Verifying EFI boot files..."
EFI_BOOT_DIR="/mnt/target/boot/efi/EFI/BOOT"
if [ "$ARCH" = "x86_64" ]; then
    EFI_BOOT_BINARY="BOOTX64.EFI"
else
    EFI_BOOT_BINARY="BOOTAA64.EFI"
fi
# Remove any residual shim chain files (from grub-efi-*-signed package hooks)
# These cause firmware to try loading garbled vendor paths before falling back
for shim_file in shimx64.efi mmx64.efi fbx64.efi BOOTX64.CSV shimaa64.efi mmaa64.efi fbaa64.efi BOOTAA64.CSV; do
    if [ -f "$EFI_BOOT_DIR/$shim_file" ] && [ "$shim_file" != "$EFI_BOOT_BINARY" ]; then
        rm -f "$EFI_BOOT_DIR/$shim_file"
        echo "   Removed shim artifact: $shim_file"
    fi
done
# Also remove vendor-specific EFI directory (shim creates /EFI/archipelago/)
rm -rf "/mnt/target/boot/efi/EFI/archipelago" 2>/dev/null || true
# Nuclear cleanup: remove everything except the GRUB binary from EFI/BOOT
if [ -d "$EFI_BOOT_DIR" ]; then
    for f in "$EFI_BOOT_DIR"/*; do
        [ "$(basename "$f")" = "$EFI_BOOT_BINARY" ] && continue
        [ "$(basename "$f")" = "grub.cfg" ] && continue
        rm -f "$f" 2>/dev/null && echo "   Removed: $(basename "$f")"
    done
fi
if [ -f "$EFI_BOOT_DIR/$EFI_BOOT_BINARY" ]; then
    echo "   ✅ UEFI boot binary present: $EFI_BOOT_DIR/$EFI_BOOT_BINARY"
    ls -la "$EFI_BOOT_DIR/"
else
    echo "   ❌ Missing $EFI_BOOT_DIR/$EFI_BOOT_BINARY — boot will fail!"
fi

# Legacy BIOS boot: only install if the installer booted in Legacy BIOS mode
# (if /sys/firmware/efi exists, the machine supports UEFI — no need for BIOS fallback)
if [ -n "${GRUB_BIOS_TARGET}" ] && [ ! -d /sys/firmware/efi ]; then
    echo "   Installing Legacy BIOS bootloader (machine booted in BIOS mode)..."
    if run chroot /mnt/target grub-install --target=${GRUB_BIOS_TARGET} "${TARGET_DISK}"; then
        ok "Legacy BIOS bootloader installed"
    else
        warn "Legacy BIOS bootloader failed (UEFI-only boot)"
    fi
elif [ -n "${GRUB_BIOS_TARGET}" ]; then
    echo "   Skipping Legacy BIOS bootloader (machine supports UEFI)"
fi

# Clean any stale live-boot artifacts (should not exist in the custom rootfs,
# but clean up defensively in case Docker base image pulled them in)
rm -f /mnt/target/etc/initramfs-tools/conf.d/live-boot* 2>/dev/null || true
rm -f /mnt/target/usr/share/initramfs-tools/scripts/live* 2>/dev/null || true
rm -f /mnt/target/usr/share/initramfs-tools/hooks/live* 2>/dev/null || true

# Brand GRUB as Archipelago (default says "Debian GNU/Linux")
sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Archipelago"/' /mnt/target/etc/default/grub
grep -q '^GRUB_DISTRIBUTOR' /mnt/target/etc/default/grub || echo 'GRUB_DISTRIBUTOR="Archipelago"' >> /mnt/target/etc/default/grub

# Suppress os-prober warning in GRUB
echo "GRUB_DISABLE_OS_PROBER=true" >> /mnt/target/etc/default/grub
# GFX fallback for hardware without graphical GRUB support
echo 'GRUB_GFXMODE=auto' >> /mnt/target/etc/default/grub
echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /mnt/target/etc/default/grub
echo 'GRUB_TERMINAL_OUTPUT=gfxterm' >> /mnt/target/etc/default/grub

# Install Archipelago GRUB theme on target system
if [ -d "$BOOT_MEDIA/boot/grub/themes/archipelago" ]; then
    mkdir -p /mnt/target/boot/grub/themes/archipelago
    cp "$BOOT_MEDIA/boot/grub/themes/archipelago/"* /mnt/target/boot/grub/themes/archipelago/
    echo 'GRUB_THEME="/boot/grub/themes/archipelago/theme.txt"' >> /mnt/target/etc/default/grub
    echo "   Installed Archipelago GRUB theme on target"
fi

# Install Archipelago Plymouth theme on target system
if [ -d "$BOOT_MEDIA/archipelago/plymouth-theme" ]; then
    PLYMOUTH_DIR="/mnt/target/usr/share/plymouth/themes/archipelago"
    mkdir -p "$PLYMOUTH_DIR"
    cp "$BOOT_MEDIA/archipelago/plymouth-theme/"* "$PLYMOUTH_DIR/"
    # Set as default Plymouth theme
    chroot /mnt/target plymouth-set-default-theme archipelago 2>/dev/null || \
        ln -sf /usr/share/plymouth/themes/archipelago/archipelago.plymouth \
            /mnt/target/etc/alternatives/default.plymouth 2>/dev/null || true
    # Configure clean boot: splash, suppress kernel noise, hide cursor
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0 rd.systemd.show_status=false vt.global_cursor_default=0 acpi=force crashkernel=256M"/' \
        /mnt/target/etc/default/grub 2>/dev/null || true
    # kdump-tools ships a grub.d snippet that appends crashkernel=512M-:192M
    # after this line. The later value silently wins on amd64, so neutralize
    # the package default and keep Archipelago's explicit fixed reservation.
    if [ -f /mnt/target/etc/default/grub.d/kdump-tools.cfg ]; then
        printf '%s\n' '# Archipelago owns crashkernel sizing in /etc/default/grub.' \
            > /mnt/target/etc/default/grub.d/kdump-tools.cfg
    fi
    echo "   Installed Archipelago Plymouth theme on target"
fi

# Regenerate initramfs — the one from Docker export is corrupt/incomplete
# (Docker builds have limited /proc, /sys, /dev so initramfs generation fails silently)
echo "   Regenerating initramfs..."
run chroot /mnt/target update-initramfs -u -k all

run chroot /mnt/target update-grub

# CRITICAL: Write EFI grub.cfg that finds the root filesystem and loads the full config.
# grub-install --removable creates a BOOTX64.EFI that looks for grub.cfg on the
# EFI FAT partition (/EFI/BOOT/grub.cfg). This stub must search for the root FS
# and then load the full /boot/grub/grub.cfg from ext4.
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
if [ -n "$ROOT_UUID" ] && [ -d "/mnt/target/boot/efi/EFI/BOOT" ]; then
    cat > /mnt/target/boot/efi/EFI/BOOT/grub.cfg <<EFICFG
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EFICFG
    echo "   Wrote EFI grub.cfg (root UUID=$ROOT_UUID)"
else
    echo "   WARNING: Could not write EFI grub.cfg (UUID=$ROOT_UUID)"
fi

# Install udev rule for mesh radio stable naming (/dev/mesh-radio)
MESH_RULES=""
for p in "$BOOT_MEDIA/99-mesh-radio.rules" /cdrom/99-mesh-radio.rules "$BOOT_MEDIA/archipelago/../configs/99-mesh-radio.rules"; do
    [ -f "$p" ] && MESH_RULES="$p" && break
done
if [ -n "$MESH_RULES" ]; then
  cp "$MESH_RULES" /mnt/target/etc/udev/rules.d/99-mesh-radio.rules
  echo "   Installed mesh radio udev rule"
fi

# First-boot diagnostics — runs once, captures system state for debugging
cat > /mnt/target/usr/local/bin/archipelago-diagnostics <<'DIAG'
#!/bin/bash
LOG="/var/log/archipelago-first-boot-diagnostics.log"
echo "=== Archipelago First Boot Diagnostics ===" > "$LOG"
echo "Date: $(date -u)" >> "$LOG"
echo "Kernel: $(uname -r)" >> "$LOG"
echo "Hostname: $(hostname)" >> "$LOG"
echo "IP: $(hostname -I 2>/dev/null)" >> "$LOG"
echo "" >> "$LOG"

echo "=== Disk ===" >> "$LOG"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE >> "$LOG" 2>&1
df -h >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== LUKS ===" >> "$LOG"
ls -la /dev/mapper/archipelago-data 2>&1 >> "$LOG"
cryptsetup status archipelago-data >> "$LOG" 2>&1 || echo "No LUKS" >> "$LOG"
echo "" >> "$LOG"

echo "=== Services ===" >> "$LOG"
for svc in nginx archipelago archipelago-kiosk archipelago-load-images \
           archipelago-first-boot-containers archipelago-first-boot-secrets \
           archipelago-setup-tor console-setup; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
    printf "  %-40s %s / %s\n" "$svc" "$STATUS" "$ENABLED" >> "$LOG"
done
echo "" >> "$LOG"

echo "=== Failed Services ===" >> "$LOG"
systemctl --failed --no-pager >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== Nginx ===" >> "$LOG"
nginx -t >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== EFI Boot ===" >> "$LOG"
ls -laR /boot/efi/EFI/ >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== SSL Cert ===" >> "$LOG"
ls -la /etc/archipelago/ssl/ >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== Podman ===" >> "$LOG"
su - archipelago -c "podman ps -a --format '{{.Names}} {{.Status}}'" >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== Memory ===" >> "$LOG"
free -h >> "$LOG" 2>&1
echo "" >> "$LOG"

echo "=== Journal Errors (last 50) ===" >> "$LOG"
journalctl -p err --no-pager -n 50 >> "$LOG" 2>&1

echo "Diagnostics saved to $LOG"
DIAG
chmod +x /mnt/target/usr/local/bin/archipelago-diagnostics

cat > /mnt/target/etc/systemd/system/archipelago-diagnostics.service <<'DIAGSVC'
[Unit]
Description=Archipelago First Boot Diagnostics
After=multi-user.target archipelago.service nginx.service
ConditionPathExists=!/var/log/archipelago-first-boot-diagnostics.log

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/usr/local/bin/archipelago-diagnostics
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DIAGSVC

# NO install-time TLS certificate is generated here, on purpose (audit F-03,
# phase 10 plan 10-03).
#
# There used to be an "ensure SSL cert exists for nginx HTTPS" block that ran
# its own "chroot /mnt/target openssl req ..." whenever the target had no cert.
# Before the identity strip it almost never fired; after the strip it would
# have fired on EVERY install.
#
# The problem with it was never that a second attempt to create a key existed.
# It was that it was a second PRODUCER: its own openssl invocation, its own idea
# of success, no retry policy, no failure record, no marker discipline. F-03 was
# a silent-failure bug, and a second producer with its own accounting is exactly
# how silent failures happen. So the fix is to unify, not to add another
# fallback and not to leave the node with no way back.
#
# What replaces it: archipelago-first-boot-secrets.service is the single
# producer of /etc/archipelago/ssl/archipelago.{key,crt}, exactly as it is the
# single producer of /etc/ssh/ssh_host_*, and it retries with backoff in-boot,
# on archipelago-first-boot-secrets.timer every 15 minutes, and on every boot
# until it succeeds. A machine that is merely busy repairs itself unattended; a
# machine that is genuinely broken says so loudly on the console and in
# /var/lib/archipelago/first-boot-secrets.failed instead of quietly serving a
# key nobody audited.
#
# The deterministic way this could never succeed — a missing openssl or
# ssh-keygen — is caught at BUILD time by the assertion layer in STEP 1, so it
# cannot reach a node at all.
#
# Do not reintroduce a producer here. If you need a key earlier, call the same
# generator. tests/first-boot-secrets/run-tests.sh case 6 fails if a second
# independent key-creating path appears in this file.

# Enable linger for rootless podman (containers survive logout)
mkdir -p /mnt/target/var/lib/systemd/linger
touch /mnt/target/var/lib/systemd/linger/archipelago

# Enable podman socket for archipelago user (activated on first login/boot)
mkdir -p /mnt/target/home/archipelago/.config/systemd/user/sockets.target.wants
ln -sf /usr/lib/systemd/user/podman.socket /mnt/target/home/archipelago/.config/systemd/user/sockets.target.wants/podman.socket 2>/dev/null || true
chown -R 1000:1000 /mnt/target/home/archipelago/.config 2>/dev/null || true

# Ensure /run/user/1000 is created at boot for podman socket
mkdir -p /mnt/target/etc/tmpfiles.d
echo 'd /run/user/1000 0700 archipelago archipelago -' > /mnt/target/etc/tmpfiles.d/archipelago-runtime.conf

# Pre-create /var/log/archipelago/ and container-installs.log so the
# backend (running as `archipelago`) can append to them without needing
# root. Logrotate rotates files in this directory daily.
cat > /mnt/target/etc/tmpfiles.d/archipelago-logs.conf <<'LOGSTMPFILES'
d /var/log/archipelago 0755 archipelago archipelago - -
f /var/log/archipelago/container-installs.log 0644 archipelago archipelago - -
LOGSTMPFILES

# Bootstrap switchover — checks when local Bitcoin finishes IBD and switches services
cat > /mnt/target/etc/systemd/system/archipelago-bootstrap-switchover.service <<'BSSERVICE'
[Unit]
Description=Switch Bitcoin-dependent services from bootstrap to local node
After=archipelago-first-boot-containers.service

[Service]
Type=oneshot
User=archipelago
ExecStart=/opt/archipelago/scripts/bootstrap-switchover.sh
BSSERVICE

cat > /mnt/target/etc/systemd/system/archipelago-bootstrap-switchover.timer <<'BSTIMER'
[Unit]
Description=Periodically check if local Bitcoin is synced and switch from bootstrap

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
BSTIMER

# Copy bootstrap config to install target
if [ -f "$BOOT_MEDIA/archipelago/bootstrap.conf" ]; then
    cp "$BOOT_MEDIA/archipelago/bootstrap.conf" /mnt/target/opt/archipelago/bootstrap.conf
    chmod 600 /mnt/target/opt/archipelago/bootstrap.conf
    chown root:root /mnt/target/opt/archipelago/bootstrap.conf
fi

# Copy bootstrap switchover script
if [ -f "$BOOT_MEDIA/archipelago/scripts/bootstrap-switchover.sh" ]; then
    cp "$BOOT_MEDIA/archipelago/scripts/bootstrap-switchover.sh" /mnt/target/opt/archipelago/scripts/
    chmod +x /mnt/target/opt/archipelago/scripts/bootstrap-switchover.sh
fi

# Enable services
chroot /mnt/target systemctl enable archipelago-bootstrap-switchover.timer 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago.service 2>/dev/null || true
chroot /mnt/target systemctl enable nginx.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-load-images.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-first-boot-secrets.service 2>/dev/null || true
# Self-heal timer: if this does not get enabled, a node whose secret generation
# fails every retry has no unattended way back. chroot systemctl enable can fail
# silently, so fall back to writing the symlink by hand rather than trusting
# `|| true` to have done anything.
chroot /mnt/target systemctl enable archipelago-first-boot-secrets.timer 2>/dev/null || \
  { mkdir -p /mnt/target/etc/systemd/system/timers.target.wants && \
    ln -sf /etc/systemd/system/archipelago-first-boot-secrets.timer \
           /mnt/target/etc/systemd/system/timers.target.wants/archipelago-first-boot-secrets.timer 2>/dev/null || true; }
chroot /mnt/target systemctl enable archipelago-setup-tor.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-first-boot-containers.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-kiosk.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-audio-router.service 2>/dev/null || true
chroot /mnt/target systemctl enable archipelago-gamepad-keys.service 2>/dev/null || true
chroot /mnt/target systemctl enable nostr-vpn.service 2>/dev/null || true
# Enable claude-api-proxy (create symlink manually — chroot systemctl can fail)
chroot /mnt/target systemctl enable claude-api-proxy.service 2>/dev/null || \
  ln -sf /etc/systemd/system/claude-api-proxy.service /mnt/target/etc/systemd/system/multi-user.target.wants/claude-api-proxy.service 2>/dev/null || true

# Fix console-setup: setupcon needs /tmp writable, add ordering dependency
mkdir -p /mnt/target/etc/systemd/system/console-setup.service.d
cat > /mnt/target/etc/systemd/system/console-setup.service.d/fix-tmp.conf <<'CONSOLEFIX'
[Unit]
After=tmp.mount systemd-tmpfiles-setup.service
Wants=tmp.mount

[Service]
ExecStartPre=/bin/mkdir -p /tmp
CONSOLEFIX

# Raise /tmp tmpfs cap above systemd's 50%-of-RAM default — PyInstaller-based
# daemons (e.g. the Reticulum mesh daemon) self-extract to /tmp on every launch
# and leak their extraction dir on abnormal exit; combined with release-build
# staging dirs this can exhaust the default cap and starve app installs/mesh.
mkdir -p /mnt/target/etc/systemd/system/tmp.mount.d
cat > /mnt/target/etc/systemd/system/tmp.mount.d/override.conf <<'TMPSIZE'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=75%,nr_inodes=1m
TMPSIZE

# Auto-login on tty1 — no password prompt on console
mkdir -p /mnt/target/etc/systemd/system/getty@tty1.service.d
cat > /mnt/target/etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin archipelago --noclear %I $TERM
AUTOLOGIN
chroot /mnt/target systemctl enable archipelago-diagnostics.service 2>/dev/null || true

# Post-install smoke test — runs Phase 1 (install verification) only on first boot
# Does NOT run onboarding or create passwords — lets user do that via the UI
cat > /mnt/target/etc/systemd/system/archipelago-post-install-tests.service <<'PITSERVICE'
[Unit]
Description=Archipelago Install Verification (first boot)
After=archipelago.service archipelago-first-boot-containers.service nginx.service
Wants=archipelago.service nginx.service
ConditionPathExists=!/var/lib/archipelago/.post-install-tests-done

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf http://127.0.0.1:5678/health >/dev/null 2>&1 && exit 0; sleep 2; done; exit 0'
ExecStart=/bin/bash -c '/opt/archipelago/scripts/run-post-install-tests.sh --phase1-only 2>&1 | tee /var/log/archipelago-post-install-tests.log; touch /var/lib/archipelago/.post-install-tests-done'
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
PITSERVICE
chroot /mnt/target systemctl enable archipelago-post-install-tests.service 2>/dev/null || true

# Install first-boot diagnostic script — runs once after first boot and logs system state
cat > /mnt/target/opt/archipelago/scripts/first-boot-diag.sh <<'DIAGSCRIPT'
#!/bin/bash
LOG="/var/log/archipelago-first-boot-diag.log"
exec > "$LOG" 2>&1
echo "=== Archipelago First Boot Diagnostics ==="
echo "Date: $(date -u)"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "IP: $(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "=== Build Info ==="
cat /opt/archipelago/build-info.txt 2>/dev/null || echo "No build-info.txt"
echo ""
echo "=== Services ==="
for svc in nginx archipelago archipelago-kiosk archipelago-load-images archipelago-first-boot-containers; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "missing")
  ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || echo "missing")
  printf "  %-45s active=%-10s enabled=%s\n" "$svc" "$STATUS" "$ENABLED"
done
echo ""
echo "=== Nginx Test ==="
nginx -t 2>&1
echo ""
echo "=== SSL Cert ==="
ls -la /etc/archipelago/ssl/ 2>/dev/null || echo "  No SSL directory"
echo ""
echo "=== EFI Boot ==="
ls -la /boot/efi/EFI/BOOT/ 2>/dev/null || echo "  No EFI/BOOT directory"
echo ""
echo "=== LUKS ==="
ls -la /dev/mapper/archipelago-data 2>/dev/null && echo "  LUKS volume open" || echo "  No LUKS volume"
cat /etc/crypttab 2>/dev/null
echo ""
echo "=== Podman ==="
podman --version 2>/dev/null || echo "  podman not found"
podman ps -a --format "{{.Names}} {{.Status}}" 2>/dev/null | head -20
echo ""
echo "=== Kiosk ==="
systemctl status archipelago-kiosk --no-pager 2>&1 | head -10
echo ""
echo "=== Console Setup ==="
systemctl status console-setup --no-pager 2>&1 | head -5
cat /etc/default/keyboard 2>/dev/null || echo "  No keyboard config"
echo ""
echo "=== Logind (Lid) ==="
cat /etc/systemd/logind.conf.d/lid-ignore.conf 2>/dev/null || echo "  No lid config"
echo ""
echo "=== Disk ==="
df -h / /boot/efi /var/lib/archipelago 2>/dev/null
echo ""
echo "=== Network ==="
ip addr show | grep -E "inet |link/" | head -10
echo ""
echo "=== Journal Errors (last boot) ==="
journalctl -b -p err --no-pager 2>/dev/null | tail -30
echo ""
echo "=== Done ==="
DIAGSCRIPT
chmod +x /mnt/target/opt/archipelago/scripts/first-boot-diag.sh
# v1.7.104 shipped installs where this script was missing while its unit was
# enabled (203/EXEC forever). Verify the write actually landed, loudly.
if [ ! -x /mnt/target/opt/archipelago/scripts/first-boot-diag.sh ]; then
    echo "ERROR: first-boot-diag.sh was not written to the target" >&2
fi

# Systemd oneshot service for first-boot diagnostics
cat > /mnt/target/etc/systemd/system/archipelago-diag.service <<'DIAGSVC'
[Unit]
Description=Archipelago First Boot Diagnostics
After=multi-user.target archipelago.service nginx.service
ConditionPathExists=!/var/log/archipelago-first-boot-diag.log
# Skip cleanly (instead of failing 203/EXEC) if the script is missing.
ConditionPathExists=/opt/archipelago/scripts/first-boot-diag.sh

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/opt/archipelago/scripts/first-boot-diag.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DIAGSVC
chroot /mnt/target systemctl enable archipelago-diag.service 2>/dev/null || true

# Write build info into the installed system
cat > /mnt/target/opt/archipelago/build-info.txt <<BUILDINFO
version=__BUILD_VERSION__
build=__BUILD_NUM__
commit=__GIT_SHORT__
date=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
type=unbundled
BUILDINFO

# Save install log BEFORE unmounting target
cp "$INSTALL_LOG" /mnt/target/var/log/archipelago-install.log 2>/dev/null || true

# Cleanup
sync
umount /mnt/target/run 2>/dev/null || true
umount /mnt/target/sys 2>/dev/null || true
umount /mnt/target/proc 2>/dev/null || true
umount /mnt/target/dev/pts 2>/dev/null || true
umount /mnt/target/dev 2>/dev/null || true
umount /mnt/target/boot/efi 2>/dev/null || true
umount /mnt/target/var/lib/archipelago 2>/dev/null || true
cryptsetup close archipelago-data 2>/dev/null || true
umount /mnt/target 2>/dev/null || true

echo ""
hrule
echo ""

# Celebration animation if TUI available
[ "${TUI_AVAILABLE:-}" = "1" ] && tui_complete

p "${ORANGE_BRIGHT}  ✓ Installation Complete${NC}"
echo ""
p "${ORANGE_DIM}  After reboot, access from any device:${NC}"
echo ""
p "${ORANGE}  http://<this machine's IP>${NC}"
echo ""
p "${WHITE}  SSH       ssh archipelago@<IP>${NC}"
p "${WHITE}  Password  archipelago${NC}"
p "${WHITE}  Web Login create your password on first visit${NC}"
echo ""
hrule
echo ""
# Suppress kernel messages on console (SquashFS errors when USB is pulled)
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

# Show completion message, unmount USB, then reboot
# All done inline — no separate script needed (avoids /bin/bash dependency on squashfs)

echo ""
if [ "${TUI_AVAILABLE:-}" = "1" ]; then
    tui_flash_remove_usb
else
    p "${ORANGE}>>> REMOVE THE USB DRIVE NOW <<<${NC}"
fi
echo ""
p "${ORANGE_DIM}Press Enter to reboot (or wait 30 seconds)${NC}"

# Suppress kernel messages (squashfs errors when USB is pulled)
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

# Lazy-unmount live filesystem
exec 2>/dev/null
umount -l /run/live/medium 2>/dev/null || true
umount -l /lib/live/mount/medium 2>/dev/null || true
umount -l /run/archiso 2>/dev/null || true
umount -l /cdrom 2>/dev/null || true
BOOT_DEV=$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null || findmnt -n -o SOURCE /cdrom 2>/dev/null || echo "")
if [ -n "$BOOT_DEV" ]; then
    BOOT_DISK=$(lsblk -no PKNAME "$BOOT_DEV" 2>/dev/null | head -1)
    [ -n "$BOOT_DISK" ] && eject "/dev/$BOOT_DISK" 2>/dev/null || true
fi
exec 2>&1

# Wait for Enter or timeout
read -t 30 -s 2>/dev/null || true

echo ""
p "${ORANGE_DIM}Rebooting...${NC}"
sleep 1

# Force reboot — multiple methods, first one that works wins
echo b > /proc/sysrq-trigger 2>/dev/null || \
/sbin/reboot -f 2>/dev/null || \
/usr/sbin/reboot -f 2>/dev/null || \
kill -9 1 2>/dev/null
INSTALLER_SCRIPT

# Inject build version into auto-install.sh (heredoc is single-quoted, can't expand variables)
sed -i "s|__BUILD_VERSION__|${BUILD_VERSION}|g" "$ARCH_DIR/auto-install.sh"
sed -i "s|__BUILD_NUM__|${BUILD_NUM}|g" "$ARCH_DIR/auto-install.sh"
sed -i "s|__GIT_SHORT__|${GIT_SHORT}|g" "$ARCH_DIR/auto-install.sh"

# For unbundled builds, patch the completion message to reflect no pre-loaded apps
if [ "$UNBUNDLED" = "1" ]; then
    sed -i 's/Pre-loaded apps (ready to start via Web UI):/Install apps from the Marketplace (internet required):/' "$ARCH_DIR/auto-install.sh"
    sed -i 's/• Bitcoin Knots  • LND  • Home Assistant/  Open the Web UI → Marketplace → Install any app/' "$ARCH_DIR/auto-install.sh"
    sed -i 's/• BTCPay Server  • Mempool  • Nostr Relays/  All apps download automatically via Podman    /' "$ARCH_DIR/auto-install.sh"
fi

chmod +x "$ARCH_DIR/auto-install.sh"

# =============================================================================
# STEP 5: Configure boot loader and ISO structure
# =============================================================================
echo ""
echo "Step 5: Configuring boot loaders..."

# The installer squashfs (from Step 2) already contains:
# - systemd service for auto-starting the installer
# - auto-login on tty1
# - custom initramfs hook for mounting boot media at /run/archiso
# - all partitioning tools (parted, mkfs.*, cryptsetup)
#
# Step 5 just needs to create the GRUB and ISOLINUX boot configs.

# Create GRUB configuration
echo "   Writing GRUB config..."
cat > "$INSTALLER_ISO/boot/grub/grub.cfg" <<'GRUBCFG'
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod all_video
insmod search
insmod search_label
insmod search_fs_file

# Find boot media — try label first, then known file fallback
search --no-floppy --set=root --label ARCHIPELAGO
if [ -z "$root" ]; then
    search --no-floppy --set=root --file /archipelago/auto-install.sh
fi

set timeout=5
set default=0

# Serial console for QEMU/headless testing
insmod serial
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

# Load font for graphical menu — fallback to text mode on hardware without gfxterm
if loadfont ($root)/boot/grub/font.pf2; then
    set gfxmode=auto
    set gfxpayload=keep
    insmod gfxterm
    insmod png
    terminal_output gfxterm serial
else
    terminal_output console serial
fi

# Archipelago GRUB theme
if [ -f ($root)/boot/grub/themes/archipelago/theme.txt ]; then
    loadfont ($root)/boot/grub/themes/archipelago/dejavu_12.pf2
    loadfont ($root)/boot/grub/themes/archipelago/dejavu_14.pf2
    loadfont ($root)/boot/grub/themes/archipelago/dejavu_16.pf2
    loadfont ($root)/boot/grub/themes/archipelago/dejavu_24.pf2
    set theme=($root)/boot/grub/themes/archipelago/theme.txt
else
    set menu_color_normal=light-gray/black
    set menu_color_highlight=white/dark-gray
fi

menuentry "Install Archipelago" --hotkey=i {
    linux ($root)/live/vmlinuz boot=live components quiet splash loglevel=0 rd.systemd.show_status=false vt.global_cursor_default=0 acpi=force console=ttyS0,115200 console=tty0
    initrd ($root)/live/initrd.img
}

menuentry "Install Archipelago (verbose)" --hotkey=v {
    linux ($root)/live/vmlinuz boot=live components loglevel=4 console=ttyS0,115200 console=tty0 acpi=force
    initrd ($root)/live/initrd.img
}

menuentry "Boot from local disk" --hotkey=b {
    set root=(hd0)
    chainloader +1
}
GRUBCFG

# Copy grub.cfg to EFI/BOOT on ISO filesystem AND into the FAT EFI image
# The embedded grub bootstrap does configfile "${cmdpath}/grub.cfg"
cp "$INSTALLER_ISO/boot/grub/grub.cfg" "$INSTALLER_ISO/EFI/BOOT/grub.cfg"
if [ -f "$WORK_DIR/efi.img" ]; then
    mcopy -oi "$WORK_DIR/efi.img" "$INSTALLER_ISO/boot/grub/grub.cfg" ::/EFI/BOOT/grub.cfg 2>/dev/null || \
        echo "   WARNING: Could not copy grub.cfg into efi.img (mtools required)"
fi

# Create ISOLINUX configuration (legacy BIOS boot)
echo "   Writing ISOLINUX config..."
# Copy background image for ISOLINUX graphical menu
ISOLINUX_BG="$SCRIPT_DIR/branding/grub-theme/background.png"
if [ -f "$ISOLINUX_BG" ]; then
    cp "$ISOLINUX_BG" "$INSTALLER_ISO/isolinux/splash.png"
fi

# Copy vesamenu.c32 for graphical menu (with background support)
if [ -f "$WORK_DIR/vesamenu.c32" ]; then
    cp "$WORK_DIR/vesamenu.c32" "$INSTALLER_ISO/isolinux/vesamenu.c32"
fi

cat > "$INSTALLER_ISO/isolinux/isolinux.cfg" <<'ISOCFG'
UI vesamenu.c32
PROMPT 0
TIMEOUT 0

MENU TITLE
MENU BACKGROUND splash.png
MENU RESOLUTION 1024 768
MENU VSHIFT 20
MENU HSHIFT 6
MENU WIDTH 68
MENU MARGIN 2
MENU ROWS 5
MENU TABMSG press tab to edit  |  archipelago.sh
MENU COLOR screen      37;40   #00000000 #00000000 none
MENU COLOR border      30;40   #00000000 #00000000 none
MENU COLOR title       1;37;40 #80888888 #00000000 none
MENU COLOR sel         7;37;40 #ffffffff #c0181818 std
MENU COLOR unsel       37;40   #ffaaaaaa #00000000 none
MENU COLOR hotkey      1;37;40 #fffb923c #00000000 none
MENU COLOR hotsel      1;37;40 #fffb923c #c0181818 std
MENU COLOR timeout_msg 37;40   #ff555555 #00000000 none
MENU COLOR timeout     1;37;40 #fffb923c #00000000 none
MENU COLOR tabmsg      37;40   #ff444444 #00000000 none
MENU COLOR cmdmark     37;40   #00000000 #00000000 none
MENU COLOR cmdline     37;40   #00000000 #00000000 none

DEFAULT install

LABEL install
    MENU LABEL Install Archipelago
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components quiet loglevel=0 rd.systemd.show_status=false vt.global_cursor_default=0 acpi=force
    MENU DEFAULT

LABEL install-verbose
    MENU LABEL Install (verbose output)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components loglevel=4 acpi=force

LABEL local
    MENU LABEL Boot from local disk
    LOCALBOOT 0x80
ISOCFG

echo "   Step 5 complete (GRUB + ISOLINUX configured)"

# =============================================================================
# STEP 6: Create final ISO
# =============================================================================
echo ""
echo "Step 6: Creating bootable ISO..."

# Release-candidate suffix: rebuilds of the SAME version used to overwrite
# the previous ISO under an identical filename, so a flashed stick was
# indistinguishable from a newer build. Auto-increment an RC counter per
# version (persists next to the build counter); override with RC=n env.
RC_COUNTER_FILE="/opt/archipelago/rc-counter-${BUILD_VERSION}"
if [ -n "${RC:-}" ]; then
    RC_NUM="$RC"
else
    if [ -f "$RC_COUNTER_FILE" ]; then
        RC_NUM=$(( $(cat "$RC_COUNTER_FILE") + 1 ))
    else
        RC_NUM=1
    fi
fi
echo "$RC_NUM" | sudo tee "$RC_COUNTER_FILE" > /dev/null 2>/dev/null || true
echo "   Release candidate: RC${RC_NUM}"

if [ "$UNBUNDLED" = "1" ]; then
    OUTPUT_ISO="$OUTPUT_DIR/archipelago-installer-${BUILD_VERSION}-unbundled-${ARCH}_RC${RC_NUM}.iso"
else
    OUTPUT_ISO="$OUTPUT_DIR/archipelago-installer-${BUILD_VERSION}-${ARCH}_RC${RC_NUM}.iso"
fi

# Use the proven MBR code for hybrid USB boot
# The ISOLINUX package's isohdpfx.bin (33 ed) doesn't boot on all hardware.
# We ship the Debian Live MBR (45 52) which is known to work with Balena Etcher.
ISOHDPFX="$SCRIPT_DIR/branding/isohdpfx.bin"
if [ ! -f "$ISOHDPFX" ]; then
    ISOHDPFX="$WORK_DIR/isohdpfx.bin"
fi
if [ ! -f "$ISOHDPFX" ]; then
    # Fallback to system-installed copy
    for path in \
        "/usr/lib/ISOLINUX/isohdpfx.bin" \
        "/usr/share/syslinux/isohdpfx.bin" \
        "/usr/local/share/syslinux/isohdpfx.bin"; do
        if [ -f "$path" ]; then
            ISOHDPFX="$path"
            echo "   Using system isohdpfx.bin: $path"
            break
        fi
    done
fi

# EFI boot image — embedded inside ISO (same approach as the working main ISO)
# The efi.img must be copied into the ISO directory in Step 2 artifact placement
EFI_IMG="$INSTALLER_ISO/boot/grub/efi.img"

if [ ! -f "$EFI_IMG" ]; then
    echo "   WARNING: No EFI boot image — ISO will only support Legacy BIOS boot"
    xorriso -as mkisofs -o "$OUTPUT_ISO" \
        -volid "ARCHIPELAGO" \
        -iso-level 3 \
        -J -joliet-long -R \
        -isohybrid-mbr "$ISOHDPFX" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -partition_offset 16 \
        "$INSTALLER_ISO"
else
    # UEFI fix: append efi.img as a real EFI System Partition (ESP) in GPT
    # instead of embedding it as "basic data". Strict UEFI firmware requires
    # the correct ESP type GUID (C12A7328-F81F-11D2-BA4B-00A0C93EC93B).
    # This is the same approach used by Arch Linux ISOs.
    xorriso -as mkisofs -o "$OUTPUT_ISO" \
        -volid "ARCHIPELAGO" \
        -iso-level 3 \
        -J -joliet-long -R \
        -isohybrid-mbr "$ISOHDPFX" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -appended_part_as_gpt \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$WORK_DIR/efi.img" \
        -partition_offset 16 \
        "$INSTALLER_ISO"
fi

# Checksums: emit next to the ISO so releases can be verified and the
# release ceremony can sign them (publish step signs; the build host
# never holds the release key)
(
    cd "$(dirname "$OUTPUT_ISO")" || exit 0
    ISO_NAME=$(basename "$OUTPUT_ISO")
    sha256sum "$ISO_NAME" > "$ISO_NAME.sha256"
    echo "   Checksum: $(cat "$ISO_NAME.sha256")"
)

echo ""
if [ "$UNBUNDLED" = "1" ]; then
    echo "UNBUNDLED AUTO-INSTALLER ISO CREATED"
    echo ""
    echo "  Output: $OUTPUT_ISO"
    echo "  Size:   $(du -h "$OUTPUT_ISO" | cut -f1)"
    echo ""
    echo "  Lightweight installer -- apps downloaded on-demand from Marketplace"
else
    echo "AUTO-INSTALLER ISO CREATED"
    echo ""
    echo "  Output: $OUTPUT_ISO"
    echo "  Size:   $(du -h "$OUTPUT_ISO" | cut -f1)"
    echo ""
    echo "  Full installer with pre-bundled container apps"
fi
echo "To create USB:"
echo "  1. Flash with: sudo dd if=$OUTPUT_ISO of=/dev/rdiskX bs=4m"
echo "     Or use Balena Etcher"
echo "  2. Boot from USB"
echo "  3. Press Enter to install"
echo "  4. Remove USB and reboot"
echo ""
