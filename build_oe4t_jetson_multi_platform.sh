#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# build_oe4t_jetson_multi_v12.sh
#
# OE4T / Yocto build setup for:
#   1. Jetson Orin Nano Super Developer Kit
#   2. Jetson Orin NX
#   3. Jetson AGX Thor Developer Kit
#
# Default:
#   TARGET_PLATFORM=orin-super-nano
#
# Supported TARGET_PLATFORM values:
#   orin-super-nano
#   orin-nx
#   thor
#
# Build one platform:
#   ./build_oe4t_jetson_multi_v12.sh
#   TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_v12.sh
#   TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_v12.sh
#
# Build all three platforms:
#   BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_v12.sh
#
# Smaller image:
#   TARGET_IMAGE=demo-image-base ./build_oe4t_jetson_multi_v12.sh
#
# Clean one platform build directory:
#   CLEAN_BUILD=1 ./build_oe4t_jetson_multi_v12.sh
#
# Production-ish build without permissive dev login:
#   DEV_LOGIN_FEATURES=0 ./build_oe4t_jetson_multi_v12.sh
#
# Important:
#   This script intentionally does NOT force IMAGE_FSTYPES.
#   Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.
#
# v12 fixes:
#   - Fixes the local compatibility layer's Yocto series declaration for OE4T
#     branches whose core layer currently reports blacksail/wrynose. v11 used
#     a static newer-series list, so bitbake-layers rejected the generated
#     meta-jetson-builder-fixes layer before parsing could continue.
#   - Dynamically reads LAYERSERIES_COMPAT_core from the checked-out OE4T core
#     layer and emits a matching compatibility list for the generated local
#     fix layer.
#
# v11 fixes retained:
#   - Adds a small local Yocto layer with a linux-firmware bbappend to keep
#     Ubuntu 24.04 / current OE4T builds from failing on buildpaths QA in
#     third-party binary firmware blobs that are not part of the Jetson path.
#   - Keeps the fix recipe-scoped to linux-firmware instead of disabling
#     buildpaths QA globally.
#
# v10 fixes retained:
#   - Adds Ubuntu 24.04 AppArmor/user-namespace preflight and automatic fix
#     for BitBake's user namespace sanity check.
#   - Persists the user namespace compatibility sysctls by default.
#   - Makes the meta-openembedded layer hint check understand sublayers.
#
# v9 fixes retained:
#   - Wraps the primary image build command with "time".
#   - Prints clean elapsed build time per platform.
#
# v8 fixes retained:
#   - Handles both *.tegraflash.tar.zst and *.tegraflash-tar.zst outputs.
#   - Adds perl-native single-thread workaround.
#   - Keeps rpcsvc-proto-native and openssl-native single-thread workarounds.
#   - Makes clock synchronization check stricter before BitBake starts.
###############################################################################

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OE4T_REPO="${OE4T_REPO:-https://github.com/OE4T/tegra-demo-distro.git}"

TARGET_PLATFORM="${TARGET_PLATFORM:-orin-super-nano}"
TARGET_IMAGE="${TARGET_IMAGE:-demo-image-full}"
TARGET_DISTRO="${TARGET_DISTRO:-tegrademo}"

BUILD_ALL_PLATFORMS="${BUILD_ALL_PLATFORMS:-0}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"

DEV_LOGIN_FEATURES="${DEV_LOGIN_FEATURES:-1}"

HOST_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
BB_THREADS="${BB_THREADS:-$HOST_CPUS}"
MAKE_THREADS="${MAKE_THREADS:--j$HOST_CPUS}"

MIN_FREE_GB="${MIN_FREE_GB:-150}"

# Ubuntu 24.04 enables AppArmor restrictions on unprivileged user namespaces.
# BitBake needs user namespaces for its sanity checks and some isolation paths.
# Keep this enabled by default so Noble hosts work out of the box.
AUTO_FIX_UBUNTU_USERNS="${AUTO_FIX_UBUNTU_USERNS:-1}"
PERSIST_UBUNTU_USERNS_FIX="${PERSIST_UBUNTU_USERNS_FIX:-1}"


# Optional exact workspace override for single-platform builds.
# If unset, each platform gets a workspace beside this script.
WORKSPACE="${WORKSPACE:-}"

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '\nWARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

format_seconds_hms() {
    local total_seconds="$1"
    printf '%02d:%02d:%02d' \
        "$((total_seconds / 3600))" \
        "$(((total_seconds % 3600) / 60))" \
        "$((total_seconds % 60))"
}

platform_machine() {
    case "$1" in
        orin-super-nano)
            echo "p3768-0000-p3767-0003"
            ;;
        orin-nx)
            # Common OE4T machine for Jetson Orin NX module on Xavier NX / P3509 carrier.
            # Override with TARGET_MACHINE if your carrier/module combination differs.
            echo "p3509-a02-p3767-0000"
            ;;
        thor)
            echo "jetson-agx-thor-devkit"
            ;;
        *)
            die "Unsupported TARGET_PLATFORM=$1. Use: orin-super-nano, orin-nx, or thor."
            ;;
    esac
}

platform_branch() {
    case "$1" in
        orin-super-nano|orin-nx)
            echo "master"
            ;;
        thor)
            echo "master-l4t-r38.2.x"
            ;;
        *)
            die "Unsupported TARGET_PLATFORM=$1. Use: orin-super-nano, orin-nx, or thor."
            ;;
    esac
}

platform_workspace() {
    local platform="$1"

    if [ -n "$WORKSPACE" ] && [ "$BUILD_ALL_PLATFORMS" != "1" ]; then
        echo "$WORKSPACE"
        return
    fi

    case "$platform" in
        orin-super-nano)
            echo "$SCRIPT_DIR/oe4t-orin-nano-super"
            ;;
        orin-nx)
            echo "$SCRIPT_DIR/oe4t-orin-nx"
            ;;
        thor)
            echo "$SCRIPT_DIR/oe4t-thor"
            ;;
        *)
            die "Unsupported TARGET_PLATFORM=$platform."
            ;;
    esac
}

print_platform_help() {
    cat <<EOF

Supported platforms:

  orin-super-nano
    Default MACHINE:
      p3768-0000-p3767-0003
    Default OE4T branch:
      master

  orin-nx
    Default MACHINE:
      p3509-a02-p3767-0000
    Default OE4T branch:
      master
    Note:
      Override TARGET_MACHINE if your Orin NX module/carrier combination differs.

  thor
    Default MACHINE:
      jetson-agx-thor-devkit
    Default OE4T branch:
      master-l4t-r38.2.x
    Note:
      Thor / JetPack 7 support is on a different OE4T branch than Orin / JetPack 6.

Examples:

  ./build_oe4t_jetson_multi_v12.sh

  TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_v12.sh

  TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_v12.sh

  BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_v12.sh

EOF
}

append_once_block() {
    local file="$1"
    local platform="$2"
    local machine="$3"
    local downloads_dir="$4"
    local sstate_dir="$5"
    local hashserve_db_dir="$6"

    # Remove generated blocks from previous script versions.
    sed -i '/^# BEGIN generated by build_oe4t_orin_nano_super_v2.sh$/,/^# END generated by build_oe4t_orin_nano_super_v2.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_orin_nano_super_v3.sh$/,/^# END generated by build_oe4t_orin_nano_super_v3.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_orin_nano_super_v4.sh$/,/^# END generated by build_oe4t_orin_nano_super_v4.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_orin_nano_super_v5.sh$/,/^# END generated by build_oe4t_orin_nano_super_v5.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_orin_nano_super_v5.sh dev login$/,/^# END generated by build_oe4t_orin_nano_super_v5.sh dev login$/d' "$file"

    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v6.sh$/,/^# END generated by build_oe4t_jetson_multi_v6.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v6.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v6.sh dev login$/d' "$file"

    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v7.sh$/,/^# END generated by build_oe4t_jetson_multi_v7.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v7.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v7.sh dev login$/d' "$file"

    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v8.sh$/,/^# END generated by build_oe4t_jetson_multi_v8.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v8.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v8.sh dev login$/d' "$file"

    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v9.sh$/,/^# END generated by build_oe4t_jetson_multi_v9.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v9.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v9.sh dev login$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v10.sh$/,/^# END generated by build_oe4t_jetson_multi_v10.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v10.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v10.sh dev login$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v12.sh$/,/^# END generated by build_oe4t_jetson_multi_v12.sh$/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_v12.sh dev login$/,/^# END generated by build_oe4t_jetson_multi_v12.sh dev login$/d' "$file"

    # Remove stray old debug-tweaks lines from previous manual/script attempts.
    sed -i '/debug-tweaks/d' "$file"

    cat >> "$file" <<EOF

# BEGIN generated by build_oe4t_jetson_multi_v12.sh

# Platform selected by script.
# Platform: $platform
# Machine:  $machine

# Shared Yocto caches for this platform workspace.
DL_DIR ?= "$downloads_dir"
SSTATE_DIR ?= "$sstate_dir"

# Keep hash equivalency database with the shared sstate cache.
BB_HASHSERVE_DB_DIR ?= "$hashserve_db_dir"

# Parallelism.
BB_NUMBER_THREADS ?= "$BB_THREADS"
PARALLEL_MAKE ?= "$MAKE_THREADS"

# Workaround: rpcsvc-proto-native can race during parallel make/config.status.
# Keep this native recipe single-threaded while preserving global parallelism.
PARALLEL_MAKE:pn-rpcsvc-proto-native = "-j1"

# Workaround: openssl-native can fail during parallel build/install on some hosts,
# especially after clock skew or partially rebuilt native workdirs.
PARALLEL_MAKE:pn-openssl-native = "-j1"
PARALLEL_MAKEINST:pn-openssl-native = "-j1"

# Workaround: perl-native can rebuild generated Makefiles during parallel make,
# especially when host clock skew creates future timestamps.
PARALLEL_MAKE:pn-perl-native = "-j1"

# Some NVIDIA / multimedia packages may carry commercial license flags.
LICENSE_FLAGS_ACCEPTED += "commercial"

# Useful package tooling on target.
IMAGE_INSTALL:append = " openssh-sftp-server"

# Do NOT force IMAGE_FSTYPES here.
# Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.
# Forcing tegraflash.tar.zst can trigger:
#   No CONVERSION_CMD defined for subtype "tar"

# END generated by build_oe4t_jetson_multi_v12.sh
EOF

    if [ "$DEV_LOGIN_FEATURES" = "1" ]; then
        cat >> "$file" <<EOF

# BEGIN generated by build_oe4t_jetson_multi_v12.sh dev login

# Development convenience.
# These replace the older "debug-tweaks" feature, which is not valid in this tree.
# Remove or set DEV_LOGIN_FEATURES=0 for production images.
EXTRA_IMAGE_FEATURES:append = " ssh-server-openssh allow-empty-password empty-root-password allow-root-login"

# END generated by build_oe4t_jetson_multi_v12.sh dev login
EOF
    else
        cat >> "$file" <<EOF

# BEGIN generated by build_oe4t_jetson_multi_v12.sh dev login

# Development login features disabled by DEV_LOGIN_FEATURES=0.
EXTRA_IMAGE_FEATURES:append = " ssh-server-openssh"

# END generated by build_oe4t_jetson_multi_v12.sh dev login
EOF
    fi
}

print_next_steps() {
    local platform="$1"
    local machine="$2"
    local branch="$3"
    local workspace="$4"
    local build_dir_name="$5"
    local deploy_dir="$6"
    local latest_tegraflash="$7"
    local elapsed_hms="$8"

    cat <<EOF

===============================================================================
BUILD COMPLETE: $platform
===============================================================================

Platform:
  $platform

OE4T branch:
  $branch

Machine:
  $machine

Target image:
  $TARGET_IMAGE

Build elapsed time:
  $elapsed_hms

Workspace:
  $workspace

Build directory:
  $workspace/tegra-demo-distro/$build_dir_name

Image deploy directory:
  $deploy_dir

Primary flashing package:
  $latest_tegraflash

Other useful outputs are in the same deploy directory, usually including:
  *.ext4
  *.manifest
  *.spdx.json
  *.testdata.json
  *.tegraflash.tar.zst
  *.tegraflash-tar.zst
  boot.img
  Image*.bin
  tegra-espimage*.esp
  tegra-initrd-flash-initramfs*.cpio.gz.cboot
  tos-*.img
  uefi_*.bin

===============================================================================
WHAT TO EXECUTE NEXT
===============================================================================

To enter the build environment again later:

  cd "$workspace/tegra-demo-distro"
  . ./setup-env "$build_dir_name"

To rebuild the same image:

  bitbake "$TARGET_IMAGE"

To build a smaller validation image:

  bitbake demo-image-base

===============================================================================
FLASHING PROCEDURE
===============================================================================

1. Install host-side flashing helpers if missing:

  sudo apt-get install -y zstd tar usbutils

2. Create a clean flashing directory:

  mkdir -p "$workspace/tegraflash-${machine}"
  cd "$workspace/tegraflash-${machine}"

3. Extract the tegraflash package from a terminal:

  tar --use-compress-program=unzstd -xf "$latest_tegraflash"

If your tar does not support that option:

  unzstd --stdout "$latest_tegraflash" | tar -xf -

4. Put the Jetson into force-recovery mode.

Typical developer kit flow:
  - Power off the Jetson.
  - Connect USB-C from the Jetson recovery/programming port to the Ubuntu host.
  - Hold Force Recovery, or short the recovery pins depending on carrier.
  - Apply power or press reset while recovery is asserted.
  - Release recovery.

5. Confirm the Ubuntu host sees the Jetson:

  lsusb | grep -i nvidia

6. Flash.

Preferred if present:

  sudo ./initrd-flash

If initrd-flash is not present but doexternal.sh is present:

  sudo ./doexternal.sh

For internal/default flashing, if supported by the generated package:

  sudo ./doflash.sh

7. After flashing:
  - Power off the Jetson.
  - Remove recovery jumper / release recovery wiring.
  - Boot normally.
  - Use serial console or HDMI/keyboard for first boot.
  - This is a development image if DEV_LOGIN_FEATURES=1.

===============================================================================
EOF
}

install_host_prereqs() {
    if command -v apt-get >/dev/null 2>&1; then
        log "Installing common Ubuntu/Debian Yocto and Jetson flashing prerequisites"
        sudo apt-get update
        sudo apt-get install -y \
            gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio \
            python3 python3-pip python3-pexpect python3-git python3-jinja2 python3-subunit \
            xz-utils debianutils iputils-ping file locales zstd lz4 util-linux \
            libsdl1.2-dev xterm bmap-tools tar usbutils rsync
    else
        warn "apt-get not found. Install Yocto host dependencies manually for your distro."
    fi

    log "Ensuring UTF-8 locale is available"
    if command -v locale-gen >/dev/null 2>&1; then
        sudo locale-gen en_US.UTF-8 || true
    fi

    export LANG="${LANG:-en_US.UTF-8}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
}

check_clock_sync() {
    if command -v timedatectl >/dev/null 2>&1; then
        log "Checking host clock synchronization"

        sudo timedatectl set-ntp true || true

        if ! timedatectl | grep -q "System clock synchronized: yes"; then
            timedatectl || true
            die "Host clock is not synchronized. Fix NTP/time sync first; clock skew can break native Yocto builds."
        fi
    else
        warn "timedatectl not found; cannot verify host clock synchronization."
    fi
}

userns_selftest() {
    # BitBake's sanity check needs unprivileged user namespaces.  This is the
    # smallest direct host-side probe for the same kernel/AppArmor capability.
    unshare -Ur true >/dev/null 2>&1
}

persist_sysctl_setting() {
    local key="$1"
    local value="$2"
    local file="/etc/sysctl.d/99-yocto-bitbake-userns.conf"

    if [ "$PERSIST_UBUNTU_USERNS_FIX" != "1" ]; then
        return
    fi

    log "Persisting $key=$value in $file"
    sudo mkdir -p /etc/sysctl.d
    if [ -f "$file" ]; then
        sudo sed -i "/^${key}[[:space:]]*=.*/d" "$file"
    fi
    printf '%s = %s\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
}

ensure_bitbake_userns_usable() {
    log "Checking BitBake user namespace support"

    if userns_selftest; then
        log "User namespace self-test passed."
        return
    fi

    warn "User namespace self-test failed before applying host compatibility fixes."

    if [ "$AUTO_FIX_UBUNTU_USERNS" != "1" ]; then
        cat <<EOF >&2

BitBake cannot use unprivileged user namespaces on this host.
On Ubuntu 24.04 this is commonly caused by AppArmor's unprivileged user
namespace restriction.

Automatic fix is disabled because AUTO_FIX_UBUNTU_USERNS=$AUTO_FIX_UBUNTU_USERNS.
Run either:

  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

or rerun this script with:

  AUTO_FIX_UBUNTU_USERNS=1 $0

EOF
        die "BitBake user namespace support is unavailable."
    fi

    local changed="0"

    if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
        local current_apparmor_userns
        current_apparmor_userns="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo unknown)"
        if [ "$current_apparmor_userns" != "0" ]; then
            log "Disabling Ubuntu AppArmor unprivileged user namespace restriction for BitBake"
            sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
            persist_sysctl_setting kernel.apparmor_restrict_unprivileged_userns 0
            changed="1"
        fi
    fi

    if [ -r /proc/sys/kernel/unprivileged_userns_clone ]; then
        local current_userns_clone
        current_userns_clone="$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo unknown)"
        if [ "$current_userns_clone" != "1" ]; then
            log "Enabling unprivileged user namespace clone support for BitBake"
            sudo sysctl -w kernel.unprivileged_userns_clone=1
            persist_sysctl_setting kernel.unprivileged_userns_clone 1
            changed="1"
        fi
    fi

    if [ "$changed" = "0" ]; then
        warn "No known user namespace sysctl required changing, but the self-test still failed."
    fi

    if userns_selftest; then
        log "User namespace self-test passed after host compatibility fix."
        return
    fi

    cat <<EOF >&2

BitBake user namespaces are still unavailable after applying the known Ubuntu
24.04 compatibility settings.

Diagnostics:
  uname: $(uname -a)
  apparmor_restrict_unprivileged_userns: $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo not-present)
  unprivileged_userns_clone: $(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo not-present)
  unshare test: unshare -Ur true

Try manually checking AppArmor policy, container/VM restrictions, and whether the
host permits unprivileged user namespaces at all.

EOF
    die "BitBake user namespace support is unavailable."
}


ensure_builder_fix_layer() {
    local distro_dir="$1"
    local bblayers_conf="$2"

    local fix_layer
    fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"

    local core_layer_conf
    core_layer_conf="$distro_dir/layers/meta/conf/layer.conf"

    local compat_series
    compat_series="$(sed -n 's/^LAYERSERIES_COMPAT_core[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$core_layer_conf" 2>/dev/null | head -n 1 || true)"

    if [ -z "$compat_series" ]; then
        warn "Could not read LAYERSERIES_COMPAT_core from $core_layer_conf; using broad local-layer compatibility list."
        compat_series="blacksail wrynose scarthgap styhead walnascar whinlatter master"
    else
        log "Detected Yocto core layer compatibility series: $compat_series"
    fi

    # Include common OE4T/current-series aliases as a harmless fallback. The key
    # requirement is that the generated layer includes the exact series exposed
    # by the checked-out core layer, such as blacksail/wrynose on current OE4T.
    local fallback_series
    for fallback_series in blacksail wrynose scarthgap styhead walnascar whinlatter master; do
        case " $compat_series " in
            *" $fallback_series "*) ;;
            *) compat_series="$compat_series $fallback_series" ;;
        esac
    done

    log "Creating/updating local Yocto compatibility fix layer"

    mkdir -p "$fix_layer/conf" "$fix_layer/recipes-kernel/linux-firmware"

    cat > "$fix_layer/conf/layer.conf" <<EOF
# Local fixes generated by build_oe4t_jetson_multi_platform_v12.sh.
# This layer is intentionally small and recipe-scoped.
BBPATH .= ":\${LAYERDIR}"
BBFILES += "\${LAYERDIR}/recipes-*/*/*.bbappend"
BBFILE_COLLECTIONS += "jetson-builder-fixes"
BBFILE_PATTERN_jetson-builder-fixes = "^\${LAYERDIR}/"
BBFILE_PRIORITY_jetson-builder-fixes = "99"
LAYERDEPENDS_jetson-builder-fixes = "core"
LAYERSERIES_COMPAT_jetson-builder-fixes = "$compat_series"
EOF

    cat > "$fix_layer/recipes-kernel/linux-firmware/linux-firmware_%.bbappend" <<'EOF'
# linux-firmware ships opaque vendor binary firmware blobs. Current upstream
# linux-firmware includes qcom/qcs6490/radxa/dragon-q6a *.mbn blobs whose
# payload strings can match the build host HOME/TMPDIR and trip Yocto's
# buildpaths QA check, even though these blobs are not produced by this build
# and are not part of the Jetson boot path.
#
# Keep the workaround scoped to linux-firmware rather than disabling buildpaths
# QA globally for the whole image.
ERROR_QA:remove = "buildpaths"
WARN_QA:append = " buildpaths"

# Also skip buildpaths QA explicitly on the packages observed to fail. The
# exact package names come from linux-firmware's qcom packaging split.
INSANE_SKIP:${PN}-qcom-qcs6490-radxa-dragon-q6a-audio += "buildpaths"
INSANE_SKIP:${PN}-qcom-qcs6490-radxa-dragon-q6a-compute += "buildpaths"
EOF

    if grep -qF "$fix_layer" "$bblayers_conf"; then
        log "Local compatibility fix layer already present in bblayers.conf"
        return
    fi

    if command -v bitbake-layers >/dev/null 2>&1; then
        log "Adding local compatibility fix layer with bitbake-layers"
        bitbake-layers add-layer "$fix_layer"
    else
        log "Adding local compatibility fix layer directly to bblayers.conf"
        python3 - "$bblayers_conf" "$fix_layer" <<'PYINNER'
from pathlib import Path
import sys
path = Path(sys.argv[1])
layer = sys.argv[2]
text = path.read_text()
if layer in text:
    raise SystemExit(0)
lines = text.splitlines()
for i, line in enumerate(lines):
    if line.strip() == '"' and i > 0 and 'BBLAYERS' in '\n'.join(lines[:i]):
        lines.insert(i, f"  {layer} \\")
        path.write_text('\n'.join(lines) + '\n')
        raise SystemExit(0)
with path.open('a') as f:
    f.write(f'\nBBLAYERS += "{layer}"\n')
PYINNER
    fi
}

build_one_platform() {
    local platform="$1"

    local machine
    local branch
    local workspace
    local downloads_dir
    local sstate_dir
    local hashserve_db_dir
    local build_dir_name
    local build_start_epoch
    local build_end_epoch
    local build_elapsed_seconds
    local build_elapsed_hms

    machine="${TARGET_MACHINE:-$(platform_machine "$platform")}"
    branch="${OE4T_BRANCH:-$(platform_branch "$platform")}"
    workspace="$(platform_workspace "$platform")"

    downloads_dir="${DOWNLOADS_DIR:-$workspace/downloads}"
    sstate_dir="${SSTATE_DIR:-$workspace/sstate-cache}"
    hashserve_db_dir="${HASHSERVE_DB_DIR:-$sstate_dir/hashserv}"
    build_dir_name="${BUILD_DIR_NAME:-build-${machine}}"

    log "Checking available disk space for $platform"
    mkdir -p "$workspace"

    local free_gb
    free_gb="$(df -BG "$workspace" | awk 'NR == 2 { gsub(/G/, "", $4); print $4 }')"

    if [ "${free_gb:-0}" -lt "$MIN_FREE_GB" ]; then
        die "Only ${free_gb}GB free in $workspace. For $TARGET_IMAGE, free at least ${MIN_FREE_GB}GB."
    fi

    log "Preparing workspace for $platform"
    mkdir -p "$workspace" "$downloads_dir" "$sstate_dir" "$hashserve_db_dir"
    cd "$workspace"

    if [ ! -d tegra-demo-distro/.git ]; then
        log "Cloning OE4T tegra-demo-distro branch for $platform: $branch"
        git clone --branch "$branch" "$OE4T_REPO" tegra-demo-distro
    else
        log "Updating existing tegra-demo-distro checkout for $platform"
        cd tegra-demo-distro
        git fetch origin
        git checkout "$branch"
        git pull --ff-only origin "$branch"
        cd "$workspace"
    fi

    cd "$workspace/tegra-demo-distro"

    log "Initializing and updating OE4T submodules for $platform"
    git submodule update --init --recursive

    if [ "$CLEAN_BUILD" = "1" ]; then
        log "Removing existing build directory because CLEAN_BUILD=1"
        rm -rf "$workspace/tegra-demo-distro/$build_dir_name"
    fi

    log "Verifying requested machine exists for $platform: $machine"

    if ! find -L . -path '*/conf/machine/*.conf' -name "${machine}.conf" | grep -q .; then
        echo
        echo "Machine $machine was not found for platform $platform on branch $branch."
        echo
        echo "Available machine names that may be relevant:"
        find -L . -path '*/conf/machine/*.conf' \
            \( -name '*orin*.conf' -o -name '*thor*.conf' -o -name 'p3768-0000-p3767-*.conf' -o -name 'p3509-a02-p3767-*.conf' \) \
            -print \
            | sed 's#.*/##; s#\.conf$##' \
            | sort
        die "Choose a listed machine with TARGET_MACHINE=<name>."
    fi

    log "Creating/updating OE4T build environment for $platform"

    set +u
    . ./setup-env --machine "$machine" --distro "$TARGET_DISTRO" "$build_dir_name"
    set -u

    local build_abs_dir
    local local_conf
    local bblayers_conf

    build_abs_dir="$workspace/tegra-demo-distro/$build_dir_name"
    local_conf="$build_abs_dir/conf/local.conf"
    bblayers_conf="$build_abs_dir/conf/bblayers.conf"

    [ -f "$local_conf" ] || die "local.conf was not created at $local_conf"
    [ -f "$bblayers_conf" ] || die "bblayers.conf was not created at $bblayers_conf"

    log "Applying local.conf settings for $platform"
    append_once_block "$local_conf" "$platform" "$machine" "$downloads_dir" "$sstate_dir" "$hashserve_db_dir"

    ensure_builder_fix_layer "$workspace/tegra-demo-distro" "$bblayers_conf"

    log "Checking required layers are present in bblayers.conf for $platform"

    for layer_hint in \
        "openembedded-core/meta" \
        "meta-tegra" \
        "meta-tegrademo" \
        "meta-virtualization"
    do
        if ! grep -q "$layer_hint" "$bblayers_conf"; then
            warn "Layer hint not found in bblayers.conf for $platform: $layer_hint"
        fi
    done

    if ! grep -Eq 'meta-openembedded/(meta-oe|meta-python|meta-networking|meta-filesystems|meta-multimedia|meta)' "$bblayers_conf"; then
        warn "Layer hint not found in bblayers.conf for $platform: meta-openembedded sublayers"
    fi

    log "Build configuration for $platform"
    cat <<EOF
  SCRIPT_NAME:         $SCRIPT_NAME
  SCRIPT_DIR:          $SCRIPT_DIR
  TARGET_PLATFORM:     $platform
  TARGET_MACHINE:      $machine
  TARGET_DISTRO:       $TARGET_DISTRO
  TARGET_IMAGE:        $TARGET_IMAGE
  OE4T_REPO:           $OE4T_REPO
  OE4T_BRANCH:         $branch
  WORKSPACE:           $workspace
  BUILD_DIR:           $build_abs_dir
  DOWNLOADS_DIR:       $downloads_dir
  SSTATE_DIR:          $sstate_dir
  HASHSERVE_DB_DIR:    $hashserve_db_dir
  BB_THREADS:          $BB_THREADS
  MAKE_THREADS:        $MAKE_THREADS
  DEV_LOGIN_FEATURES:  $DEV_LOGIN_FEATURES
  AUTO_FIX_USERNS:     $AUTO_FIX_UBUNTU_USERNS
  PERSIST_USERNS_FIX:  $PERSIST_UBUNTU_USERNS_FIX
EOF

    ensure_bitbake_userns_usable

    log "Running BitBake parse sanity check for $platform"
    bitbake -p

    log "Starting image build for $platform: bitbake $TARGET_IMAGE"

    build_start_epoch="$(date +%s)"

    time bitbake "$TARGET_IMAGE"

    build_end_epoch="$(date +%s)"
    build_elapsed_seconds="$((build_end_epoch - build_start_epoch))"
    build_elapsed_hms="$(format_seconds_hms "$build_elapsed_seconds")"

    log "Build elapsed time for $platform: $build_elapsed_hms"

    local deploy_dir
    deploy_dir="$build_abs_dir/tmp/deploy/images/$machine"

    [ -d "$deploy_dir" ] || die "Expected deploy directory not found: $deploy_dir"

    local latest_tegraflash

    latest_tegraflash="$(
        find "$deploy_dir" -maxdepth 1 -type f \
            \( -name "${TARGET_IMAGE}-${machine}.rootfs*.tegraflash.tar.zst" -o -name "${TARGET_IMAGE}-${machine}.rootfs*.tegraflash-tar.zst" \) \
            -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }'
    )"

    if [ -z "$latest_tegraflash" ]; then
        latest_tegraflash="$(
            find "$deploy_dir" -maxdepth 1 -type f \
                \( -name "*${TARGET_IMAGE}*.tegraflash.tar.zst" -o -name "*${TARGET_IMAGE}*.tegraflash-tar.zst" \) \
                -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr \
                | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }'
        )"
    fi

    if [ -z "$latest_tegraflash" ]; then
        warn "No tegraflash archive found for $platform. Listing deploy artifacts instead:"
        find "$deploy_dir" -maxdepth 1 -type f -printf '  %f\n' | sort
        die "Build finished for $platform, but flashing package was not found."
    fi

    log "Listing key deploy artifacts for $platform"

    find "$deploy_dir" -maxdepth 1 -type f \
        \( -name "*${TARGET_IMAGE}*" -o -name "boot.img" -o -name "Image*.bin" -o -name "kernel_*.dtb" -o -name "tegra-espimage*.esp" -o -name "tegra-initrd-flash-initramfs*.cpio.gz.cboot" -o -name "tos-*.img" -o -name "uefi_*.bin" \) \
        -printf '  %f\n' \
        | sort

    print_next_steps "$platform" "$machine" "$branch" "$workspace" "$build_dir_name" "$deploy_dir" "$latest_tegraflash" "$build_elapsed_hms"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    print_platform_help
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    die "Do not run Yocto/OE4T builds as root. Run as a normal user."
fi

need_cmd git
need_cmd awk
need_cmd sed
need_cmd df
need_cmd find
need_cmd sort
need_cmd python3

install_host_prereqs
check_clock_sync

if [ "$BUILD_ALL_PLATFORMS" = "1" ]; then
    if [ -n "${TARGET_MACHINE:-}" ]; then
        die "TARGET_MACHINE override is not supported with BUILD_ALL_PLATFORMS=1."
    fi

    for platform in orin-super-nano orin-nx thor; do
        build_one_platform "$platform"
    done
else
    build_one_platform "$TARGET_PLATFORM"
fi
