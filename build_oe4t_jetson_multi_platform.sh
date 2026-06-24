#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# build_oe4t_jetson_multi_platform_v33.sh
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
#   ./build_oe4t_jetson_multi_platform_v33.sh
#   TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform_v33.sh
#   TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform_v33.sh
#
# Build all three platforms:
#   BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_platform_v33.sh
#
# Smaller image:
#   TARGET_IMAGE=demo-image-base ./build_oe4t_jetson_multi_platform_v33.sh
#
# Clean one platform build directory:
#   CLEAN_BUILD=1 ./build_oe4t_jetson_multi_platform_v33.sh
#
# Production-ish build without permissive dev login:
#   DEV_LOGIN_FEATURES=0 ./build_oe4t_jetson_multi_platform_v33.sh
#
# Important:
#   This script intentionally does NOT force IMAGE_FSTYPES.
#   Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.
#
# v33 fixes:
#   - Treats the Thor CUDA duplicate header as a producer-manifest problem, not
#     a local.conf overlap-whitelist problem. Current OE-Core detects duplicate
#     sysroot files from dependency manifests before copying files, so deleting
#     the physical header alone is too late.
#   - Forces cuda-nvcc-native and cuda-nvcc-headers-native populate_sysroot,
#     then surgically prunes cuda-nvcc-native CUDA include entries from the
#     actual sstate/sysroot manifests and component directories before testing
#     cuda-compiler-native:do_prepare_recipe_sysroot.
#   - Keeps only SSTATE_ALLOW_OVERLAP_FILES as a harmless extra guard and
#     removes obsolete SSTATE_DUPWHITELIST lines from local.conf.
#   - Bumps the Thor CUDA clean/repair stamp to v33 so this runs even if v28
#     already created stamps.
#   - Adds the FreeImage 3.18.0 -fPIC bbappend only after BitBake confirms
#     that a freeimage recipe is active. This avoids failing fresh Thor setup
#     when the recipe is not present in the checked-out layer tree yet.
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

AUTO_FIX_UBUNTU_USERNS="${AUTO_FIX_UBUNTU_USERNS:-1}"
PERSIST_UBUNTU_USERNS_FIX="${PERSIST_UBUNTU_USERNS_FIX:-1}"
WORKSPACE="${WORKSPACE:-}"

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

format_seconds_hms() {
    local total_seconds="$1"
    printf '%02d:%02d:%02d' \
        "$((total_seconds / 3600))" \
        "$(((total_seconds % 3600) / 60))" \
        "$((total_seconds % 60))"
}

platform_machine() {
    case "$1" in
        orin-super-nano) echo "p3768-0000-p3767-0003" ;;
        orin-nx) echo "p3509-a02-p3767-0000" ;;
        thor) echo "jetson-agx-thor-devkit" ;;
        *) die "Unsupported TARGET_PLATFORM=$1. Use: orin-super-nano, orin-nx, or thor." ;;
    esac
}

platform_branch() {
    case "$1" in
        orin-super-nano|orin-nx) echo "master" ;;
        thor) echo "master-l4t-r38.2.x" ;;
        *) die "Unsupported TARGET_PLATFORM=$1. Use: orin-super-nano, orin-nx, or thor." ;;
    esac
}

platform_workspace() {
    local platform="$1"
    if [ -n "$WORKSPACE" ] && [ "$BUILD_ALL_PLATFORMS" != "1" ]; then
        echo "$WORKSPACE"
        return
    fi
    case "$platform" in
        orin-super-nano) echo "$SCRIPT_DIR/oe4t-orin-nano-super" ;;
        orin-nx) echo "$SCRIPT_DIR/oe4t-orin-nx" ;;
        thor) echo "$SCRIPT_DIR/oe4t-thor" ;;
        *) die "Unsupported TARGET_PLATFORM=$platform." ;;
    esac
}

print_platform_help() {
    cat <<EOF_HELP

Supported platforms:

  orin-super-nano
    Default MACHINE: p3768-0000-p3767-0003
    Default OE4T branch: master

  orin-nx
    Default MACHINE: p3509-a02-p3767-0000
    Default OE4T branch: master

  thor
    Default MACHINE: jetson-agx-thor-devkit
    Default OE4T branch: master-l4t-r38.2.x

Examples:

  ./build_oe4t_jetson_multi_platform_v33.sh
  TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform_v33.sh
  TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform_v33.sh
  BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_platform_v33.sh

EOF_HELP
}

append_once_block() {
    local file="$1"
    local platform="$2"
    local machine="$3"
    local downloads_dir="$4"
    local sstate_dir="$5"
    local hashserve_db_dir="$6"

    for old in \
        build_oe4t_orin_nano_super_v2.sh \
        build_oe4t_orin_nano_super_v3.sh \
        build_oe4t_orin_nano_super_v4.sh \
        build_oe4t_orin_nano_super_v5.sh \
        build_oe4t_jetson_multi_v6.sh \
        build_oe4t_jetson_multi_v7.sh \
        build_oe4t_jetson_multi_v8.sh \
        build_oe4t_jetson_multi_v9.sh \
        build_oe4t_jetson_multi_v10.sh \
        build_oe4t_jetson_multi_v11.sh \
        build_oe4t_jetson_multi_v12.sh \
        build_oe4t_jetson_multi_v13.sh \
        build_oe4t_jetson_multi_v15.sh
    do
        sed -i "/^# BEGIN generated by ${old//\//\/}\$/,/^# END generated by ${old//\//\/}\$/d" "$file"
        sed -i "/^# BEGIN generated by ${old//\//\/} dev login\$/,/^# END generated by ${old//\//\/} dev login\$/d" "$file"
    done

    sed -i '/debug-tweaks/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_platform_v2[0-9]\.sh thor cuda overlap guard$/,/^# END generated by build_oe4t_jetson_multi_platform_v2[0-9]\.sh thor cuda overlap guard$/d' "$file"
    # Current BitBake aborts if the obsolete renamed variable appears anywhere in local.conf.
    sed -i '/^[[:space:]]*SSTATE_DUPWHITELIST[[:space:]]*[+:?.]*=/d' "$file"

    cat >> "$file" <<EOF_CONF

# BEGIN generated by build_oe4t_jetson_multi_v15.sh

# Platform selected by script.
# Platform: $platform
# Machine:  $machine

DL_DIR ?= "$downloads_dir"
SSTATE_DIR ?= "$sstate_dir"
BB_HASHSERVE_DB_DIR ?= "$hashserve_db_dir"

BB_NUMBER_THREADS ?= "$BB_THREADS"
PARALLEL_MAKE ?= "$MAKE_THREADS"

PARALLEL_MAKE:pn-rpcsvc-proto-native = "-j1"
PARALLEL_MAKE:pn-openssl-native = "-j1"
PARALLEL_MAKEINST:pn-openssl-native = "-j1"
PARALLEL_MAKE:pn-perl-native = "-j1"

LICENSE_FLAGS_ACCEPTED += "commercial"
IMAGE_INSTALL:append = " openssh-sftp-server"

# Do NOT force IMAGE_FSTYPES here.
# Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.

# END generated by build_oe4t_jetson_multi_v15.sh
EOF_CONF

    if [ "$platform" = "thor" ]; then
        cat >> "$file" <<'EOF_THOR_CUDA_CONF'

# BEGIN generated by build_oe4t_jetson_multi_platform_v33.sh thor cuda overlap guard

# Thor / CUDA 13 native sysroot collision guard.
# The failure path observed on AGX Thor is:
#   /usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h
# owned by both cuda-nvcc-native and cuda-nvcc-headers-native while
# cuda-compiler-native runs do_prepare_recipe_sysroot.
#
# Current BitBake treats the old SSTATE_DUPWHITELIST variable as a fatal
# parse error, so v32 uses only the renamed variable.
SSTATE_ALLOW_OVERLAP_FILES += " /usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h"
SSTATE_ALLOW_OVERLAP_FILES += " /usr/local/cuda-13.0/include/* /usr/local/cuda-13.0/targets/*/include/* /usr/local/cuda-*/include/* /usr/local/cuda-*/targets/*/include/*"

# END generated by build_oe4t_jetson_multi_platform_v33.sh thor cuda overlap guard
EOF_THOR_CUDA_CONF
    fi

    if [ "$DEV_LOGIN_FEATURES" = "1" ]; then
        cat >> "$file" <<EOF_DEV

# BEGIN generated by build_oe4t_jetson_multi_v15.sh dev login
EXTRA_IMAGE_FEATURES:append = " ssh-server-openssh allow-empty-password empty-root-password allow-root-login"
# END generated by build_oe4t_jetson_multi_v15.sh dev login
EOF_DEV
    else
        cat >> "$file" <<EOF_DEV

# BEGIN generated by build_oe4t_jetson_multi_v15.sh dev login
EXTRA_IMAGE_FEATURES:append = " ssh-server-openssh"
# END generated by build_oe4t_jetson_multi_v15.sh dev login
EOF_DEV
    fi
}

install_host_prereqs() {
    if command -v apt-get >/dev/null 2>&1; then
        log "Installing common Ubuntu/Debian Yocto and Jetson flashing prerequisites"
        sudo apt-get update
        sudo apt-get install -y \
            gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio \
            python3 python3-pip python3-pexpect python3-git python3-jinja2 python3-subunit \
            xz-utils debianutils iputils-ping file locales zstd lz4 util-linux \
            libsdl1.2-dev xterm bmap-tools tar usbutils rsync qemu-user-static binfmt-support
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

ensure_foreign_binary_support() {
    case "$(uname -m)" in x86_64|amd64) return ;; esac
    log "Checking user-mode emulation for NVIDIA flash helper binaries"
    if command -v update-binfmts >/dev/null 2>&1; then
        for binfmt in qemu-x86_64 qemu-i386 qemu-arm qemu-aarch64; do
            sudo update-binfmts --enable "$binfmt" >/dev/null 2>&1 || true
        done
    fi
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl restart systemd-binfmt >/dev/null 2>&1 || true
    fi
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

userns_selftest() { unshare -Ur true >/dev/null 2>&1; }

persist_sysctl_setting() {
    local key="$1" value="$2" file="/etc/sysctl.d/99-yocto-bitbake-userns.conf"
    [ "$PERSIST_UBUNTU_USERNS_FIX" = "1" ] || return 0
    sudo mkdir -p /etc/sysctl.d
    [ -f "$file" ] && sudo sed -i "/^${key}[[:space:]]*=.*/d" "$file"
    printf '%s = %s\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
}

ensure_bitbake_userns_usable() {
    log "Checking BitBake user namespace support"
    if userns_selftest; then
        log "User namespace self-test passed."
        return
    fi
    warn "User namespace self-test failed before applying host compatibility fixes."
    [ "$AUTO_FIX_UBUNTU_USERNS" = "1" ] || die "BitBake user namespace support is unavailable and AUTO_FIX_UBUNTU_USERNS is disabled."

    if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
        if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo unknown)" != "0" ]; then
            sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
            persist_sysctl_setting kernel.apparmor_restrict_unprivileged_userns 0
        fi
    fi
    if [ -r /proc/sys/kernel/unprivileged_userns_clone ]; then
        if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo unknown)" != "1" ]; then
            sudo sysctl -w kernel.unprivileged_userns_clone=1
            persist_sysctl_setting kernel.unprivileged_userns_clone 1
        fi
    fi
    userns_selftest || die "BitBake user namespace support is still unavailable after applying known compatibility settings."
}

ensure_builder_fix_layer() {
    local distro_dir="$1"
    local bblayers_conf="$2"
    local platform="${3:-unknown}"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    local core_layer_conf="$distro_dir/layers/meta/conf/layer.conf"
    local compat_series

    compat_series="$(sed -n 's/^LAYERSERIES_COMPAT_core[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$core_layer_conf" 2>/dev/null | head -n 1 || true)"
    if [ -z "$compat_series" ]; then
        compat_series="blacksail wrynose scarthgap styhead walnascar whinlatter master"
        warn "Could not read LAYERSERIES_COMPAT_core; using broad compatibility list."
    fi
    for fallback_series in blacksail wrynose scarthgap styhead walnascar whinlatter master; do
        case " $compat_series " in *" $fallback_series "*) ;; *) compat_series="$compat_series $fallback_series" ;; esac
    done

    log "Creating/updating local Yocto compatibility fix layer for $platform"
    mkdir -p \
        "$fix_layer/conf" \
        "$fix_layer/recipes-kernel/linux-firmware" \
        "$fix_layer/recipes-bsp/tegra-binaries" \
        "$fix_layer/recipes-bsp/tegra-flashtools/files" \
        "$fix_layer/recipes-devtools/cuda" \
        "$fix_layer/recipes-multimedia/freeimage" \
        "$fix_layer/recipes-support/jetson-builder-fixes-marker"

    cat > "$fix_layer/conf/layer.conf" <<EOF_LAYER
# Local fixes generated by build_oe4t_jetson_multi_platform_v33.sh.
BBPATH .= ":\${LAYERDIR}"
BBFILES += "\${LAYERDIR}/recipes-*/*/*.bb \${LAYERDIR}/recipes-*/*/*.bbappend"
BBFILE_COLLECTIONS += "jetson-builder-fixes"
BBFILE_PATTERN_jetson-builder-fixes = "^\${LAYERDIR}/"
BBFILE_PRIORITY_jetson-builder-fixes = "99"
LAYERDEPENDS_jetson-builder-fixes = "core"
LAYERSERIES_COMPAT_jetson-builder-fixes = "$compat_series"
EOF_LAYER


    cat > "$fix_layer/recipes-support/jetson-builder-fixes-marker/jetson-builder-fixes-marker_1.0.bb" <<'EOF_FIX_MARKER'
SUMMARY = "Marker recipe for the local jetson-builder-fixes layer"
DESCRIPTION = "This empty recipe keeps BitBake from warning that the generated local fix layer has no .bb files while bbappends are conditionally generated."
LICENSE = "CLOSED"
ALLOW_EMPTY:${PN} = "1"
do_install[noexec] = "1"
EOF_FIX_MARKER

    cat > "$fix_layer/recipes-kernel/linux-firmware/linux-firmware_%.bbappend" <<'EOF_LINUX_FW'
ERROR_QA:remove = "buildpaths"
WARN_QA:append = " buildpaths"
INSANE_SKIP:${PN}-qcom-qcs6490-radxa-dragon-q6a-audio += "buildpaths"
INSANE_SKIP:${PN}-qcom-qcs6490-radxa-dragon-q6a-compute += "buildpaths"
EOF_LINUX_FW


    # Do not create a FreeImage bbappend here. On fresh Thor checkouts the
    # freeimage recipe may not be present in the layer tree before BitBake has
    # parsed the active layer set. A dangling bbappend can prevent setup from
    # continuing, so the FreeImage PIC fix is installed later only if BitBake
    # confirms that a freeimage recipe is active.

    cat > "$fix_layer/recipes-bsp/tegra-binaries/tegra-libraries-%_%.bbappend" <<'EOF_TEGRA_LIBS'
ERROR_QA:remove = "buildpaths"
WARN_QA:append = " buildpaths"
INSANE_SKIP:${PN} += "buildpaths"
python __anonymous () {
    packages = (d.getVar('PACKAGES') or '').split()
    for pkg in packages:
        d.appendVar('INSANE_SKIP:%s' % pkg, ' buildpaths')
}
EOF_TEGRA_LIBS

    local cuda_nvcc_recipe_glob="$distro_dir/layers/meta-tegra/recipes-devtools/cuda/cuda-nvcc_"*.bb
    local has_cuda_nvcc_recipe=0
    if compgen -G "$cuda_nvcc_recipe_glob" >/dev/null; then
        has_cuda_nvcc_recipe=1
    fi

    if [ "$platform" = "thor" ] && [ "$has_cuda_nvcc_recipe" = "1" ]; then
        cat > "$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend" <<'EOF_CUDA_NVCC'
# Thor / CUDA 13 native sysroot collision fix.
PR:append = ".jetsonbuilder33"

jetson_builder_prune_cuda_nvcc_headers_from_dir() {
    root_base="$1"
    for cuda_root in "${root_base}"/usr/local/cuda-* "${root_base}"${prefix}/local/cuda-*; do
        [ -d "$cuda_root" ] || continue
        rm -rf "$cuda_root/include"
        rm -rf "$cuda_root/targets"/*/include
    done
}

do_install:append() {
    jetson_builder_prune_cuda_nvcc_headers_from_dir "${D}"
}

SYSROOT_PREPROCESS_FUNCS:append:class-native = " jetson_builder_prune_cuda_nvcc_headers_sysroot "
jetson_builder_prune_cuda_nvcc_headers_sysroot() {
    jetson_builder_prune_cuda_nvcc_headers_from_dir "${SYSROOT_DESTDIR}"
}
EOF_CUDA_NVCC

        cat > "$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend" <<'EOF_CUDA_COMPILER'
# Thor / CUDA 13 native sysroot collision fix, applied at the failing consumer.
# v32 prunes both component files and sstate-control manifest lines. The latter
# is critical because do_prepare_recipe_sysroot can detect ownership collisions
# from manifests even after the duplicate file has been deleted on disk.
PR:append = ".jetsonbuilder33"

python jetson_builder_prune_cuda_nvcc_native_component () {
    import glob
    import os
    import shutil

    tmpdir = d.getVar('TMPDIR') or ''
    if not tmpdir:
        bb.warn('jetson-builder CUDA fix: TMPDIR is empty; cannot inspect sysroot components')
        return

    header_suffixes = (
        '/usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h',
        '/usr/local/cuda-13.0/include/',
        '/usr/local/cuda-13.0/targets/',
        '/usr/local/cuda-/include/',
        '/usr/local/cuda-/targets/',
    )

    removed_dirs = []
    patterns = [
        os.path.join(tmpdir, 'sysroots-components', '*', 'cuda-nvcc-native', 'usr', 'local', 'cuda-*', 'include'),
        os.path.join(tmpdir, 'sysroots-components', '*', 'cuda-nvcc-native', 'usr', 'local', 'cuda-*', 'targets', '*', 'include'),
    ]
    for pattern in patterns:
        for path in glob.glob(pattern):
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
                removed_dirs.append(path)

    # Rewrite stale populate_sysroot manifests for cuda-nvcc-native. These live
    # under tmp/sstate-control on current OE-Core, but keep a broader fallback
    # pattern for branch variance.
    manifest_patterns = [
        os.path.join(tmpdir, 'sstate-control', 'manifest-*-cuda-nvcc-native.populate_sysroot'),
        os.path.join(tmpdir, 'sstate-control', '*cuda-nvcc-native*populate_sysroot*'),
        os.path.join(tmpdir, 'sysroots-components', '*', 'manifest-*-cuda-nvcc-native.populate_sysroot'),
        os.path.join(tmpdir, 'sysroots-components', '*', '*cuda-nvcc-native*populate_sysroot*'),
    ]

    rewritten = []
    seen = set()
    for pattern in manifest_patterns:
        for manifest in glob.glob(pattern):
            if manifest in seen or not os.path.isfile(manifest):
                continue
            seen.add(manifest)
            try:
                with open(manifest, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
            except OSError:
                continue

            kept = []
            changed = False
            for line in lines:
                normalized = line.strip()
                drop = False
                if '/usr/local/cuda-' in normalized and '/include' in normalized:
                    drop = True
                if normalized.endswith('/usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h'):
                    drop = True
                if drop:
                    changed = True
                    continue
                kept.append(line)

            if changed:
                tmp_manifest = manifest + '.jetsonbuilder30.tmp'
                with open(tmp_manifest, 'w', encoding='utf-8') as f:
                    f.writelines(kept)
                os.replace(tmp_manifest, manifest)
                rewritten.append(manifest)

    if removed_dirs:
        bb.warn('jetson-builder CUDA fix: pruned cuda-nvcc-native duplicate header dirs: %s' % ', '.join(removed_dirs))
    if rewritten:
        bb.warn('jetson-builder CUDA fix: pruned cuda-nvcc-native stale header ownership manifest entries: %s' % ', '.join(rewritten))
}

do_prepare_recipe_sysroot[prefuncs] += "jetson_builder_prune_cuda_nvcc_native_component "
EOF_CUDA_COMPILER
        log "Enabled Thor CUDA nvcc/header sysroot collision fix for $platform"
    else
        rm -f "$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend"
        rm -f "$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend"
        if [ "$platform" = "thor" ]; then
            warn "Skipping Thor CUDA nvcc/header sysroot collision fix; no matching cuda-nvcc recipe exists on this OE4T branch."
        else
            log "Skipping Thor-only CUDA nvcc/header sysroot collision fix for $platform."
        fi
    fi

    local tegra_flashtools_recipe_glob="$distro_dir/layers/meta-tegra/recipes-bsp/tegra-binaries/tegra-flashtools-native_"*.bb
    local has_tegra_flashtools_native=0
    if compgen -G "$tegra_flashtools_recipe_glob" >/dev/null; then
        has_tegra_flashtools_native=1
    fi

    if [ "$has_tegra_flashtools_native" = "1" ]; then
        cat > "$fix_layer/recipes-bsp/tegra-flashtools/files/mkbootimg-wrapper" <<'EOF_MKBOOTIMG_WRAPPER'
#!/bin/sh
set -u
self="$0"
real="${self}.real"
[ -f "$real" ] || { echo "mkbootimg wrapper error: missing payload $real" >&2; exit 126; }
chmod 0755 "$real" 2>/dev/null || true
tool_dir="$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)"
native_bindir="$(CDPATH= cd -- "$tool_dir/.." && pwd)"
host_arch="$(uname -m 2>/dev/null || echo unknown)"
magic=""
if [ -x "$native_bindir/file" ]; then magic="$($native_bindir/file -L "$real" 2>/dev/null || true)"; elif command -v file >/dev/null 2>&1; then magic="$(file -L "$real" 2>/dev/null || true)"; fi
run_direct() { "$real" "$@"; rc=$?; case "$rc" in 126|127) return 1 ;; *) exit "$rc" ;; esac; }
exec_qemu() { qemu_name="$1"; shift; for qemu in "$native_bindir/${qemu_name}" "$native_bindir/${qemu_name}-static" "/usr/bin/${qemu_name}" "/usr/bin/${qemu_name}-static" "${qemu_name}" "${qemu_name}-static"; do case "$qemu" in */*) [ -x "$qemu" ] && exec "$qemu" "$real" "$@" ;; *) command -v "$qemu" >/dev/null 2>&1 && exec "$qemu" "$real" "$@" ;; esac; done; return 1; }
case "$magic" in
    *"shell script"*|*"Python script"*|*"Perl script"*) exec "$real" "$@" ;;
    *"ELF"*"x86-64"*) case "$host_arch" in x86_64|amd64) exec "$real" "$@" ;; esac; exec_qemu qemu-x86_64 "$@" || true ;;
    *"ELF"*"80386"*|*"ELF"*"Intel 80386"*) case "$host_arch" in i386|i486|i586|i686) exec "$real" "$@" ;; esac; exec_qemu qemu-i386 "$@" || true ;;
    *"ELF"*"aarch64"*|*"ELF"*"ARM aarch64"*) case "$host_arch" in aarch64|arm64) exec "$real" "$@" ;; esac; exec_qemu qemu-aarch64 "$@" || true ;;
    *"ELF"*"ARM"*) case "$host_arch" in arm*|armhf) exec "$real" "$@" ;; esac; exec_qemu qemu-arm "$@" || true ;;
    *) run_direct "$@" || true; for qemu_name in qemu-aarch64 qemu-arm qemu-x86_64 qemu-i386; do exec_qemu "$qemu_name" "$@" || true; done ;;
esac
echo "mkbootimg wrapper error: cannot execute $real on $host_arch" >&2
[ -n "$magic" ] && echo "mkbootimg wrapper detected: $magic" >&2 || echo "mkbootimg wrapper could not detect payload architecture; file(1) unavailable" >&2
exit 126
EOF_MKBOOTIMG_WRAPPER
        chmod 0755 "$fix_layer/recipes-bsp/tegra-flashtools/files/mkbootimg-wrapper"

        cat > "$fix_layer/recipes-bsp/tegra-flashtools/tegra-flashtools-native_%.bbappend" <<'EOF_TEGRA_FLASHTOOLS'
DEPENDS:append = " qemu-native file-native"
JETSON_BUILDER_FIXDIR := "${THISDIR}"
PR:append = ".jetsonbuilder21"
do_install:append() {
    mkbootimg_path="${D}${bindir}/tegra-flash/mkbootimg"
    real_path="${mkbootimg_path}.real"
    wrapper_src="${JETSON_BUILDER_FIXDIR}/files/mkbootimg-wrapper"
    [ -e "$mkbootimg_path" ] || return 0
    [ -f "$wrapper_src" ] || bbfatal "missing mkbootimg wrapper at $wrapper_src"
    if [ -e "$real_path" ]; then rm -f "$mkbootimg_path"; else mv "$mkbootimg_path" "$real_path"; fi
    install -m 0755 "$wrapper_src" "$mkbootimg_path"
    chmod a+x "$real_path" || true
}
EOF_TEGRA_FLASHTOOLS
    else
        rm -f "$fix_layer/recipes-bsp/tegra-flashtools/tegra-flashtools-native_%.bbappend"
        rm -f "$fix_layer/recipes-bsp/tegra-flashtools/files/mkbootimg-wrapper"
        log "Skipping tegra-flashtools-native mkbootimg wrapper for $platform; no matching recipe exists on this OE4T branch."
    fi

    rm -f "$fix_layer/recipes-bsp/tegra-binaries/tegra-libraries-multimedia_%.bbappend"
    rm -f "$fix_layer/recipes-bsp/tegra-binaries/tegra-libraries-camera_%.bbappend"

    while IFS= read -r -d '' generated_bbappend; do
        bbappend_base="$(basename "$generated_bbappend")"
        recipe_name_pattern="${bbappend_base%.bbappend}.bb"
        recipe_name_pattern="${recipe_name_pattern//%/*}"
        if find "$distro_dir/layers" -type f -name "$recipe_name_pattern" -print -quit | grep -q .; then
            log "Validated generated bbappend $bbappend_base for $platform"
        else
            warn "Removing dangling generated bbappend for $platform: $bbappend_base has no matching recipe pattern $recipe_name_pattern"
            rm -f "$generated_bbappend"
        fi
    done < <(find "$fix_layer" -type f -name '*.bbappend' -print0)

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

write_freeimage_pic_bbappend() {
    local append_path="$1"
    mkdir -p "$(dirname "$append_path")"
    cat > "$append_path" <<'EOF_FREEIMAGE_ACTIVE'
# Generated by build_oe4t_jetson_multi_platform_v33.sh.
# Force PIC into every FreeImage bundled object before libfreeimage.so is linked.
PR:append = ".jetsonbuilder33"

FREEIMAGE_PIC_CFLAGS = "${CFLAGS} -fPIC"
FREEIMAGE_PIC_CXXFLAGS = "${CXXFLAGS} -fPIC"
FREEIMAGE_PIC_LDFLAGS = "${LDFLAGS}"

jetson_builder_force_freeimage_pic() {
    if [ -f "${S}/Makefile.gnu" ]; then
        sed -i \
            -e '/^ifeq ($(shell sh -c '\''uname -m 2>\/dev\/null || echo not'\''),x86_64)/,/^endif/d' \
            -e '/^CFLAGS[[:space:]]*+=.*-fPIC/d' \
            -e '/^CXXFLAGS[[:space:]]*+=.*-fPIC/d' \
            "${S}/Makefile.gnu"
        if ! grep -q 'jetson-builder v33 force PIC for all shared-library builds' "${S}/Makefile.gnu"; then
            cat >> "${S}/Makefile.gnu" <<'EOF_MAKEFILE_PIC'

# jetson-builder v33 force PIC for all shared-library builds
override CFLAGS += -fPIC
override CXXFLAGS += -fPIC
EOF_MAKEFILE_PIC
        fi
    fi

    find "${S}" -name '*.o' -delete 2>/dev/null || true
    find "${B}" -name '*.o' -delete 2>/dev/null || true
}

do_configure:prepend() {
    jetson_builder_force_freeimage_pic
}

do_compile:prepend() {
    jetson_builder_force_freeimage_pic
}

do_compile() {
    jetson_builder_force_freeimage_pic
    oe_runmake -C "${S}" -f Makefile.gnu \
        CFLAGS="${FREEIMAGE_PIC_CFLAGS}" \
        CXXFLAGS="${FREEIMAGE_PIC_CXXFLAGS}" \
        LDFLAGS="${FREEIMAGE_PIC_LDFLAGS}"
}
EOF_FREEIMAGE_ACTIVE
}

ensure_active_freeimage_pic_fix() {
    local platform="$1"
    local distro_dir="$2"
    [ "$platform" = "thor" ] || return 0

    log "Checking whether FreeImage is active before installing Thor PIC fix"

    local env_file="/tmp/jetson-builder-freeimage-v33-env.txt"
    if ! bitbake -e freeimage > "$env_file" 2>/tmp/jetson-builder-freeimage-v33-env.err; then
        warn "No active freeimage recipe is visible to BitBake for $platform; skipping FreeImage PIC fix."
        warn "This is OK if the selected image does not depend on FreeImage. If a later build names freeimage, paste that newer log."
        return 0
    fi

    local recipe_file=""
    recipe_file="$(sed -n 's/^FILE="\(.*freeimage_.*\.bb\)"/\1/p' "$env_file" | head -n 1 || true)"
    if [ -n "$recipe_file" ] && [ -f "$recipe_file" ]; then
        local recipe_dir recipe_base append_path
        recipe_dir="$(dirname "$recipe_file")"
        recipe_base="$(basename "$recipe_file" .bb)"
        append_path="$recipe_dir/${recipe_base}.bbappend"
        log "Installing FreeImage v33 PIC bbappend next to active recipe: $recipe_file"
        write_freeimage_pic_bbappend "$append_path"
    else
        local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
        local append_path="$fix_layer/recipes-multimedia/freeimage/freeimage_%.bbappend"
        log "Could not resolve FreeImage recipe file from bitbake -e; installing fix-layer wildcard bbappend instead"
        write_freeimage_pic_bbappend "$append_path"
    fi

    bitbake --kill-server >/dev/null 2>&1 || true
}


repair_thor_cuda_sysroot_components() {
    local platform="$1"
    local build_abs_dir="$2"
    [ "$platform" = "thor" ] || return 0

    log "Pruning cuda-nvcc-native CUDA include files and manifest ownership entries"
    python3 - "$build_abs_dir" <<'PY_REPAIR_CUDA_SYSROOT'
from pathlib import Path
import os
import shutil
import sys

build = Path(sys.argv[1]).resolve()
tmp = build / 'tmp'

# cuda-nvcc-native is a compiler/tool provider. CUDA headers are supplied by
# cuda-nvcc-headers-native. Keep cuda-nvcc-native's binaries/libs, but remove
# include ownership from its sysroot component and manifests so OE-Core's
# extend_recipe_sysroot fileset check cannot see two owners for the same header.
def is_cuda_include_path(text: str) -> bool:
    text = text.strip()
    return '/cuda-' in text and '/include' in text and '/cuda-nvcc-native/' in text

def is_manifest_cuda_include_entry(text: str) -> bool:
    text = text.strip()
    if '/usr/local/cuda-' not in text or '/include' not in text:
        return False
    # The failing file is this exact path. Also drop the broader native CUDA
    # include entries from cuda-nvcc-native; cuda-nvcc-headers-native owns them.
    return True

removed_dirs = []
removed_files = []
rewritten = []

components = tmp / 'sysroots-components'
if components.exists():
    for comp in components.glob('*/cuda-nvcc-native'):
        for rel in ('usr/local',):
            base = comp / rel
            if not base.exists():
                continue
            for cuda_root in base.glob('cuda-*'):
                for inc in list(cuda_root.glob('include')) + list(cuda_root.glob('targets/*/include')):
                    if inc.exists():
                        if inc.is_dir():
                            shutil.rmtree(inc, ignore_errors=True)
                            removed_dirs.append(str(inc))
                        else:
                            try:
                                inc.unlink()
                                removed_files.append(str(inc))
                            except OSError:
                                pass

# Manifest locations vary slightly across OE-Core versions and depending on
# whether the dependency came from sstate or was built locally. Patch every
# plausible cuda-nvcc-native populate_sysroot manifest under tmp.
manifest_candidates = []
if tmp.exists():
    for path in tmp.rglob('*cuda-nvcc-native*populate_sysroot*'):
        if path.is_file():
            manifest_candidates.append(path)
    # Recipe-specific installeddeps manifests can be named cuda-nvcc-native.<hash>
    # without populate_sysroot in the filename.
    for path in tmp.rglob('cuda-nvcc-native.*'):
        if path.is_file() and 'installeddeps' in str(path):
            manifest_candidates.append(path)

seen = set()
for manifest in manifest_candidates:
    key = str(manifest)
    if key in seen:
        continue
    seen.add(key)
    try:
        lines = manifest.read_text(encoding='utf-8', errors='ignore').splitlines(True)
    except OSError:
        continue
    kept = []
    changed = False
    for line in lines:
        s = line.strip()
        # Absolute component paths in sstate-control manifests often include
        # .../cuda-nvcc-native/usr/local/cuda-.../include/...
        if is_cuda_include_path(s):
            changed = True
            continue
        # Recipe installeddeps/shared manifests often contain destination paths
        # relative to the recipe sysroot instead of provider component paths.
        if is_manifest_cuda_include_entry(s):
            changed = True
            continue
        kept.append(line)
    if changed:
        tmp_manifest = manifest.with_suffix(manifest.suffix + '.jetsonbuilder30.tmp')
        tmp_manifest.write_text(''.join(kept), encoding='utf-8')
        os.replace(tmp_manifest, manifest)
        rewritten.append(str(manifest))

if removed_dirs:
    print('Removed cuda-nvcc-native include dirs:')
    for item in removed_dirs[:40]:
        print('  ' + item)
    if len(removed_dirs) > 40:
        print(f'  ... {len(removed_dirs) - 40} more')
if removed_files:
    print('Removed cuda-nvcc-native include files:')
    for item in removed_files[:40]:
        print('  ' + item)
    if len(removed_files) > 40:
        print(f'  ... {len(removed_files) - 40} more')
if rewritten:
    print('Rewrote cuda-nvcc-native manifests:')
    for item in rewritten[:60]:
        print('  ' + item)
    if len(rewritten) > 60:
        print(f'  ... {len(rewritten) - 60} more')
if not (removed_dirs or removed_files or rewritten):
    print('No cuda-nvcc-native include entries found to prune yet.')
PY_REPAIR_CUDA_SYSROOT
}

prepare_and_validate_thor_cuda_native_sysroot() {
    local platform="$1"
    local build_abs_dir="$2"
    [ "$platform" = "thor" ] || return 0

    log "Forcing CUDA native sysroot producers so their manifests exist before repair"
    bitbake -c populate_sysroot cuda-nvcc-headers-native cuda-nvcc-native

    repair_thor_cuda_sysroot_components "$platform" "$build_abs_dir"

    log "Validating repaired CUDA native sysroot with cuda-compiler-native:do_prepare_recipe_sysroot"
    bitbake -c clean cuda-compiler-native || true
    bitbake -c prepare_recipe_sysroot -f cuda-compiler-native
}

clean_thor_cuda_native_state_if_needed() {
    local platform="$1"
    local build_abs_dir="$2"
    local fix_layer="$3"
    local local_conf="${4:-}"
    [ "$platform" = "thor" ] || return 0

    local cuda_fix_bbappend="$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend"
    local cuda_compiler_fix_bbappend="$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend"
    [ -f "$cuda_fix_bbappend" ] || { warn "Thor CUDA collision fix bbappend was not found at $cuda_fix_bbappend; skipping CUDA cleansstate guard."; return 0; }

    local stamp_dir="$build_abs_dir/conf/.jetson-builder-stamps"
    local stamp_file="$stamp_dir/thor-cuda-native-clean-v33.sha256"
    mkdir -p "$stamp_dir"

    local hash_inputs=()
    hash_inputs+=("$cuda_fix_bbappend")
    [ -f "$cuda_compiler_fix_bbappend" ] && hash_inputs+=("$cuda_compiler_fix_bbappend")
    [ -n "$local_conf" ] && [ -f "$local_conf" ] && hash_inputs+=("$local_conf")

    local current_hash
    current_hash="$(cat "${hash_inputs[@]}" | sha256sum | awk '{print $1}')"
    if [ -f "$stamp_file" ] && grep -qxF "$current_hash" "$stamp_file"; then
        log "Thor CUDA native cleansstate guard already applied for the current v33 fix."
        return 0
    fi

    log "Cleaning stale Thor CUDA native state so the v32 nvcc/header collision fix is used"
    bitbake -c cleansstate cuda-nvcc-native cuda-nvcc-headers-native cuda-compiler-native

    if [ -d "$build_abs_dir/tmp/sysroots-components" ]; then
        find "$build_abs_dir/tmp/sysroots-components" -type d \
            \( -name cuda-nvcc-native -o -name cuda-nvcc-headers-native -o -name cuda-compiler-native \) \
            -prune -exec rm -rf {} + 2>/dev/null || true
    fi

    if [ -d "$build_abs_dir/tmp/sstate-control" ]; then
        find "$build_abs_dir/tmp/sstate-control" -type f \
            \( -name '*cuda-nvcc-native*populate_sysroot*' -o -name '*cuda-nvcc-headers-native*populate_sysroot*' -o -name '*cuda-compiler-native*populate_sysroot*' \) \
            -delete 2>/dev/null || true
    fi

    printf '%s\n' "$current_hash" > "$stamp_file"
}


clean_freeimage_state_if_needed() {
    local platform="$1"
    local distro_dir="$2"
    [ "$platform" = "thor" ] || return 0

    if ! bitbake -e freeimage >/tmp/jetson-builder-freeimage-v33-clean-env.txt 2>/dev/null; then
        warn "Skipping FreeImage cleansstate because freeimage is not active in BitBake metadata."
        return 0
    fi

    local stamp_dir="$distro_dir/conf/.jetson-builder-stamps"
    local stamp_file="$stamp_dir/freeimage-pic-clean-v33.sha256"
    mkdir -p "$stamp_dir"

    local current_hash
    current_hash="$(find "$distro_dir/layers" -type f -name 'freeimage_*.bbappend' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
    [ -n "$current_hash" ] || current_hash="no-freeimage-bbappend"

    if [ -f "$stamp_file" ] && grep -qxF "$current_hash" "$stamp_file"; then
        log "FreeImage PIC cleansstate guard already applied for the current v33 fix."
        return 0
    fi

    log "Cleaning stale FreeImage state so the v33 -fPIC fix is used"
    bitbake -c cleansstate freeimage
    printf '%s\n' "$current_hash" > "$stamp_file"
}

validate_freeimage_pic_fix() {
    local platform="$1"
    [ "$platform" = "thor" ] || return 0

    log "Validating FreeImage v33 PIC fix only if freeimage is active"
    if ! bitbake -e freeimage > /tmp/jetson-builder-freeimage-env.txt 2>/tmp/jetson-builder-freeimage-env.err; then
        warn "FreeImage is not active in BitBake metadata; skipping FreeImage compile validation."
        return 0
    fi
    if ! grep -q 'jetsonbuilder33' /tmp/jetson-builder-freeimage-env.txt; then
        die "FreeImage is active, but the v33 PIC bbappend is not active in BitBake metadata."
    fi
    if ! grep -q 'do_compile()' /tmp/jetson-builder-freeimage-env.txt || ! grep -q 'FREEIMAGE_PIC_CFLAGS' /tmp/jetson-builder-freeimage-env.txt; then
        die "FreeImage v33 do_compile override is not visible in BitBake metadata."
    fi

    log "Forcing FreeImage compile validation with v33 PIC fix"
    bitbake -c cleansstate freeimage
    bitbake -c compile -f freeimage
}


print_next_steps() {
    local platform="$1" machine="$2" branch="$3" workspace="$4" build_dir_name="$5" deploy_dir="$6" latest_tegraflash="$7" elapsed_hms="$8"
    cat <<EOF_NEXT

===============================================================================
BUILD COMPLETE: $platform
===============================================================================

Platform: $platform
OE4T branch: $branch
Machine: $machine
Target image: $TARGET_IMAGE
Build elapsed time: $elapsed_hms
Workspace: $workspace
Build directory: $workspace/tegra-demo-distro/$build_dir_name
Image deploy directory: $deploy_dir
Primary flashing package: $latest_tegraflash

To enter the build environment again later:

  cd "$workspace/tegra-demo-distro"
  . ./setup-env "$build_dir_name"

To rebuild the same image:

  bitbake "$TARGET_IMAGE"

To flash, extract the tegraflash package, put the Jetson in force-recovery mode,
confirm with lsusb, then run initrd-flash, doexternal.sh, or doflash.sh from the
extracted flashing directory, depending on which script the package provides.
===============================================================================
EOF_NEXT
}

build_one_platform() {
    local platform="$1"
    local machine branch workspace downloads_dir sstate_dir hashserve_db_dir build_dir_name
    local build_start_epoch build_end_epoch build_elapsed_seconds build_elapsed_hms

    machine="${TARGET_MACHINE:-$(platform_machine "$platform") }"
    machine="${machine% }"
    branch="${OE4T_BRANCH:-$(platform_branch "$platform") }"
    branch="${branch% }"
    workspace="$(platform_workspace "$platform")"
    downloads_dir="${DOWNLOADS_DIR:-$workspace/downloads}"
    sstate_dir="${SSTATE_DIR:-$workspace/sstate-cache}"
    hashserve_db_dir="${HASHSERVE_DB_DIR:-$sstate_dir/hashserv}"
    build_dir_name="${BUILD_DIR_NAME:-build-${machine}}"

    log "Checking available disk space for $platform"
    mkdir -p "$workspace"
    local free_gb
    free_gb="$(df -BG "$workspace" | awk 'NR == 2 { gsub(/G/, "", $4); print $4 }')"
    [ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || die "Only ${free_gb}GB free in $workspace. For $TARGET_IMAGE, free at least ${MIN_FREE_GB}GB."

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
        echo "Available machine names that may be relevant:"
        find -L . -path '*/conf/machine/*.conf' \
            \( -name '*orin*.conf' -o -name '*thor*.conf' -o -name 'p3768-0000-p3767-*.conf' -o -name 'p3509-a02-p3767-*.conf' \) \
            -print | sed 's#.*/##; s#\.conf$##' | sort
        die "Choose a listed machine with TARGET_MACHINE=<name>."
    fi

    log "Creating/updating OE4T build environment for $platform"
    set +u
    . ./setup-env --machine "$machine" --distro "$TARGET_DISTRO" "$build_dir_name"
    set -u

    local build_abs_dir="$workspace/tegra-demo-distro/$build_dir_name"
    local local_conf="$build_abs_dir/conf/local.conf"
    local bblayers_conf="$build_abs_dir/conf/bblayers.conf"
    [ -f "$local_conf" ] || die "local.conf was not created at $local_conf"
    [ -f "$bblayers_conf" ] || die "bblayers.conf was not created at $bblayers_conf"

    log "Applying local.conf settings for $platform"
    append_once_block "$local_conf" "$platform" "$machine" "$downloads_dir" "$sstate_dir" "$hashserve_db_dir"

    ensure_builder_fix_layer "$workspace/tegra-demo-distro" "$bblayers_conf" "$platform"

    # bitbake-layers starts a server while adding layers. Kill it so new/changed
    # bbappends and layer.conf contents are reparsed before any sanity checks or builds.
    bitbake --kill-server >/dev/null 2>&1 || true

    log "Checking required layers are present in bblayers.conf for $platform"
    for layer_hint in openembedded-core/meta meta-tegra meta-tegrademo meta-virtualization; do
        grep -q "$layer_hint" "$bblayers_conf" || warn "Layer hint not found in bblayers.conf for $platform: $layer_hint"
    done
    grep -Eq 'meta-openembedded/(meta-oe|meta-python|meta-networking|meta-filesystems|meta-multimedia|meta)' "$bblayers_conf" || warn "Layer hint not found in bblayers.conf for $platform: meta-openembedded sublayers"

    cat <<EOF_BUILD_CONFIG

Build configuration for $platform:
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
EOF_BUILD_CONFIG

    ensure_bitbake_userns_usable

    log "Running BitBake parse sanity check for $platform"
    bitbake -p

    ensure_active_freeimage_pic_fix "$platform" "$workspace/tegra-demo-distro"

    clean_thor_cuda_native_state_if_needed "$platform" "$build_abs_dir" "$workspace/tegra-demo-distro/layers/meta-jetson-builder-fixes" "$local_conf"
    prepare_and_validate_thor_cuda_native_sysroot "$platform" "$build_abs_dir"
    clean_freeimage_state_if_needed "$platform" "$workspace/tegra-demo-distro"
    validate_freeimage_pic_fix "$platform"

    log "Starting image build for $platform: bitbake $TARGET_IMAGE"
    build_start_epoch="$(date +%s)"
    time bitbake "$TARGET_IMAGE"
    build_end_epoch="$(date +%s)"
    build_elapsed_seconds="$((build_end_epoch - build_start_epoch))"
    build_elapsed_hms="$(format_seconds_hms "$build_elapsed_seconds")"

    local deploy_dir="$build_abs_dir/tmp/deploy/images/$machine"
    [ -d "$deploy_dir" ] || die "Expected deploy directory not found: $deploy_dir"

    local latest_tegraflash
    latest_tegraflash="$(find "$deploy_dir" -maxdepth 1 -type f \
        \( -name "${TARGET_IMAGE}-${machine}.rootfs*.tegraflash.tar.zst" -o -name "${TARGET_IMAGE}-${machine}.rootfs*.tegraflash-tar.zst" \) \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }')"
    if [ -z "$latest_tegraflash" ]; then
        latest_tegraflash="$(find "$deploy_dir" -maxdepth 1 -type f \
            \( -name "*${TARGET_IMAGE}*.tegraflash.tar.zst" -o -name "*${TARGET_IMAGE}*.tegraflash-tar.zst" \) \
            -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }')"
    fi
    [ -n "$latest_tegraflash" ] || { find "$deploy_dir" -maxdepth 1 -type f -printf '  %f\n' | sort; die "Build finished for $platform, but flashing package was not found."; }

    log "Listing key deploy artifacts for $platform"
    find "$deploy_dir" -maxdepth 1 -type f \
        \( -name "*${TARGET_IMAGE}*" -o -name "boot.img" -o -name "Image*.bin" -o -name "kernel_*.dtb" -o -name "tegra-espimage*.esp" -o -name "tegra-initrd-flash-initramfs*.cpio.gz.cboot" -o -name "tos-*.img" -o -name "uefi_*.bin" \) \
        -printf '  %f\n' | sort

    print_next_steps "$platform" "$machine" "$branch" "$workspace" "$build_dir_name" "$deploy_dir" "$latest_tegraflash" "$build_elapsed_hms"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    print_platform_help
    exit 0
fi

[ "$(id -u)" -ne 0 ] || die "Do not run Yocto/OE4T builds as root. Run as a normal user."

need_cmd git
need_cmd awk
need_cmd sed
need_cmd df
need_cmd find
need_cmd sort
need_cmd python3

install_host_prereqs
ensure_foreign_binary_support
check_clock_sync

if [ "$BUILD_ALL_PLATFORMS" = "1" ]; then
    [ -z "${TARGET_MACHINE:-}" ] || die "TARGET_MACHINE override is not supported with BUILD_ALL_PLATFORMS=1."
    for platform in orin-super-nano orin-nx thor; do
        build_one_platform "$platform"
    done
else
    build_one_platform "$TARGET_PLATFORM"
fi
