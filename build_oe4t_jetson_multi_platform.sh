#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# build_oe4t_jetson_multi_platform_v59.sh
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
#   ./build_oe4t_jetson_multi_platform_v59.sh
#   TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform_v59.sh
#   TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform_v59.sh
#
# Build all three platforms:
#   BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_platform_v59.sh
#
# Smaller image:
#   TARGET_IMAGE=demo-image-base ./build_oe4t_jetson_multi_platform_v59.sh
#
# Clean one platform build directory:
#   CLEAN_BUILD=1 ./build_oe4t_jetson_multi_platform_v59.sh
#
# Production-ish build without permissive dev login:
#   DEV_LOGIN_FEATURES=0 ./build_oe4t_jetson_multi_platform_v59.sh
#
# Bundle primary tegraflash artifact after a successful build:
#   ./build_oe4t_jetson_multi_platform_v59.sh --bundle
#
# Important:
#   This script intentionally does NOT force IMAGE_FSTYPES.
#   Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.
#
# v59 notes:
#   - Adds a Thor linux-noble-nvidia-tegra prefetch/repair guard. The Thor
#     kernel mirror is huge, and GitHub can drop the clone near completion; v59
#     removes corrupt partial mirrors and retries with HTTP/1.1 before BitBake.
#   - Keeps the all-platform hwloc guard for Orin Nano Super, Orin NX, and Thor:
#     disable hwloc CUDA/NVML autodetection so libhwloc does not acquire an
#     untracked libcudart.so.13 runtime dependency and fail do_package_qa.
#
# v57 notes:
#   - Fixes the v55 compiler-rt/compiler-rt-native runtimes guard selecting
#     the wrong LLVM shared-source tree when BitBake PR-suffixed work-shared
#     directories are present. v57 repairs the actual CMake source root first
#     via OECMAKE_SOURCEPATH/S, then falls back to LLVM source variables.
#
# v55 notes:
#   - Adds a compiler-rt/compiler-rt-native configure guard for Thor/LLVM
#     source trees where the shared llvm-project runtimes directory is absent.
#     The guard preserves real runtimes when present and otherwise supplies an
#     explicit empty fallback consistent with the existing empty-package shim.
#
# v54 notes:
#   - Hardens the perl/perl-native timestamp-skew fix for MakeMaker files
#     generated during do_compile by ignoring Makefile.PL remake checks and
#     normalizing timestamps at compile entry.
#
# v53 notes:
#   - Fixes the util-linux-native do_install libmount relink/install race by
#     serializing util-linux install/build metadata and cleaning stale state.
#
# v52 notes:
#   - Fixes the libidn2 bbappend parser failure by avoiding a helper function
#     name containing _remove_, which newer BitBake treats as old override syntax.
#   - Keeps the v50 libidn2 do_install guard semantics intact.
#
# v50 notes:
#   - Adds a libidn2 2.3.8 do_install guard for the bundled unistring
#     libtool self-resolution failure observed on Thor.
#   - Keeps the v47/v48/v49 platform/build/bundle/e2fsprogs/perl/LLVM fixes intact.
#   - Replaces the fragile v48 LLVM license-file copy fallback with a
#     self-contained do_populate_lic normalization for libcxx/libcxx-native and
#     compiler-rt/compiler-rt-native.
#   - If LLVM component LICENSE.TXT files are missing, v50 redirects the task
#     LIC_FILES_CHKSUM entry to a generated WORKDIR license text assembled from
#     Yocto common licenses when available, with an embedded Apache-2.0 WITH
#     LLVM-exception fallback. This avoids depending on missing source-tree
#     fallback files and cleans affected LLVM component recipe state once.
#
# v44 notes:
#   - Replaced the invalid v43 gcc-runtime-native dependency with a recipe-local
#     libcxx-native libstdc++ staging shim.
#   - Added empty-package/RPROVIDES compatibility for compiler-rt packages.
#
# v42 notes:
#   - Serialized OpenSSL compile/install to avoid high-core do_install races.
#
# v40 notes:
#   - Thor CUDA duplicate-header producer/manifest fix.
#   - OpenCV CUDA native include sysroot fix and opencv4.pc sanitizer.
#   - FreeImage PIC fix.
###############################################################################

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_PWD="$(pwd)"

OE4T_REPO="${OE4T_REPO:-https://github.com/OE4T/tegra-demo-distro.git}"
TARGET_PLATFORM="${TARGET_PLATFORM:-orin-super-nano}"
TARGET_IMAGE="${TARGET_IMAGE:-demo-image-full}"
TARGET_DISTRO="${TARGET_DISTRO:-tegrademo}"
BUILD_ALL_PLATFORMS="${BUILD_ALL_PLATFORMS:-0}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
DEV_LOGIN_FEATURES="${DEV_LOGIN_FEATURES:-1}"
BUNDLE_BUILD="${BUNDLE_BUILD:-0}"

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
    printf '%02d:%02d:%02d' "$((total_seconds / 3600))" "$(((total_seconds % 3600) / 60))" "$((total_seconds % 60))"
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

  ./build_oe4t_jetson_multi_platform_v59.sh
  TARGET_PLATFORM=orin-nx ./build_oe4t_jetson_multi_platform_v59.sh
  TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform_v59.sh
  BUILD_ALL_PLATFORMS=1 ./build_oe4t_jetson_multi_platform_v59.sh
  ./build_oe4t_jetson_multi_platform_v59.sh --bundle
  TARGET_PLATFORM=thor ./build_oe4t_jetson_multi_platform_v59.sh --bundle

EOF_HELP
}

append_once_block() {
    local file="$1" platform="$2" machine="$3" downloads_dir="$4" sstate_dir="$5" hashserve_db_dir="$6"

    for old in \
        build_oe4t_orin_nano_super_v2.sh build_oe4t_orin_nano_super_v3.sh \
        build_oe4t_orin_nano_super_v4.sh build_oe4t_orin_nano_super_v5.sh \
        build_oe4t_jetson_multi_v6.sh build_oe4t_jetson_multi_v7.sh \
        build_oe4t_jetson_multi_v8.sh build_oe4t_jetson_multi_v9.sh \
        build_oe4t_jetson_multi_v10.sh build_oe4t_jetson_multi_v11.sh \
        build_oe4t_jetson_multi_v12.sh build_oe4t_jetson_multi_v13.sh \
        build_oe4t_jetson_multi_v15.sh
    do
        sed -i "/^# BEGIN generated by ${old//\//\/}\$/,/^# END generated by ${old//\//\/}\$/d" "$file"
        sed -i "/^# BEGIN generated by ${old//\//\/} dev login\$/,/^# END generated by ${old//\//\/} dev login\$/d" "$file"
    done

    sed -i '/debug-tweaks/d' "$file"
    sed -i '/^# BEGIN generated by build_oe4t_jetson_multi_platform_v[0-9][0-9]\.sh thor cuda overlap guard$/,/^# END generated by build_oe4t_jetson_multi_platform_v[0-9][0-9]\.sh thor cuda overlap guard$/d' "$file"
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
PARALLEL_MAKE:pn-openssl = "-j1"
PARALLEL_MAKEINST:pn-openssl = "-j1"
PARALLEL_MAKE:pn-perl-native = "-j1"
PARALLEL_MAKEINST:pn-perl-native = "-j1"
PARALLEL_MAKE:pn-perl = "-j1"
PARALLEL_MAKEINST:pn-perl = "-j1"
PARALLEL_MAKE:pn-util-linux-native = "-j1"
PARALLEL_MAKEINST:pn-util-linux-native = "-j1"
PARALLEL_MAKE:pn-util-linux = "-j1"
PARALLEL_MAKEINST:pn-util-linux = "-j1"

LICENSE_FLAGS_ACCEPTED += "commercial"
IMAGE_INSTALL:append = " openssh-sftp-server"

# Do NOT force IMAGE_FSTYPES here.
# Current OE4T/meta-tegra handles Jetson tegraflash output generation itself.

# END generated by build_oe4t_jetson_multi_v15.sh
EOF_CONF

    if [ "$platform" = "thor" ]; then
        cat >> "$file" <<'EOF_THOR_CUDA_CONF'

# BEGIN generated by build_oe4t_jetson_multi_platform_v59.sh thor cuda overlap guard

# Thor / CUDA 13 native sysroot collision guard.
SSTATE_ALLOW_OVERLAP_FILES += " /usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h"
SSTATE_ALLOW_OVERLAP_FILES += " /usr/local/cuda-13.0/include/* /usr/local/cuda-13.0/targets/*/include/* /usr/local/cuda-*/include/* /usr/local/cuda-*/targets/*/include/*"

# END generated by build_oe4t_jetson_multi_platform_v59.sh thor cuda overlap guard
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

write_opencv_cuda_sysroot_bbappend() {
    local append_path="$1"
    mkdir -p "$(dirname "$append_path")"
    cat > "$append_path" <<'EOF_OPENCV_CUDA'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"

CUDA_VERSION_SHORT:pn-opencv = "13.0"
CUDA_NATIVE_ROOT:pn-opencv = "${RECIPE_SYSROOT_NATIVE}/usr/local/cuda-${CUDA_VERSION_SHORT}"
CUDA_TARGET_ROOT:pn-opencv = "${RECIPE_SYSROOT}/usr/local/cuda-${CUDA_VERSION_SHORT}"

jetson_builder_fix_opencv_cuda_native_include() {
    native_root="${CUDA_NATIVE_ROOT}"
    target_root="${CUDA_TARGET_ROOT}"
    native_include="${native_root}/include"
    target_include=""

    for candidate in \
        "${target_root}/include" \
        "${target_root}/targets/sbsa-linux/include" \
        "${target_root}/targets/aarch64-linux/include" \
        "${RECIPE_SYSROOT}/usr/include"; do
        if [ -e "${candidate}/cuda_runtime.h" ] || [ -e "${candidate}/cuda.h" ]; then
            target_include="${candidate}"
            break
        fi
    done

    if [ -z "${target_include}" ]; then
        found_header="$(find "${RECIPE_SYSROOT}" -type f \( -name cuda_runtime.h -o -name cuda.h \) -print -quit 2>/dev/null || true)"
        if [ -n "${found_header}" ]; then
            target_include="$(dirname "${found_header}")"
        fi
    fi

    mkdir -p "${native_root}"
    if [ -n "${target_include}" ]; then
        if [ -L "${native_include}" ]; then
            ln -sfn "${target_include}" "${native_include}"
        elif [ -d "${native_include}" ]; then
            :
        elif [ -e "${native_include}" ]; then
            rm -f "${native_include}"
            ln -sfn "${target_include}" "${native_include}"
        else
            ln -sfn "${target_include}" "${native_include}"
        fi
    fi

    echo "jetson-builder v50 OpenCV CUDA native root: ${native_root}"
    echo "jetson-builder v50 OpenCV CUDA target root: ${target_root}"
    echo "jetson-builder v50 OpenCV CUDA selected target include: ${target_include:-none}"
    ls -ld "${native_root}" || true
    ls -ld "${native_include}" || true

    if [ ! -d "${native_include}" ]; then
        bbfatal "jetson-builder v50: ${native_include} still does not exist; cannot satisfy CMake CUDA imported target validation"
    fi
}

jetson_builder_sanitize_opencv_pkgconfig() {
    pc_file="${D}${libdir}/pkgconfig/opencv4.pc"
    [ -f "${pc_file}" ] || { echo "jetson-builder v50 OpenCV pkg-config sanitize: ${pc_file} not found; skipping"; return 0; }
    tmp_file="${pc_file}.jetsonbuilder50"

    awk \
        -v tmpdir="${TMPDIR}" \
        -v workdir="${WORKDIR}" \
        -v builddir="${B}" \
        -v sourcedir="${S}" \
        -v recipe_sysroot="${RECIPE_SYSROOT}" \
        -v recipe_sysroot_native="${RECIPE_SYSROOT_NATIVE}" \
        -v staging_target="${STAGING_DIR_TARGET}" \
        -v staging_native="${STAGING_DIR_NATIVE}" '
        BEGIN {
            roots[1] = tmpdir; roots[2] = workdir; roots[3] = builddir; roots[4] = sourcedir
            roots[5] = recipe_sysroot; roots[6] = recipe_sysroot_native; roots[7] = staging_target; roots[8] = staging_native
        }
        function is_bad_token(token, i) {
            for (i = 1; i <= 8; i++) if (roots[i] != "" && index(token, roots[i]) > 0) return 1
            return 0
        }
        /^prefix=/ { print "prefix=/usr"; next }
        /^exec_prefix=/ { print "exec_prefix=${prefix}"; next }
        /^libdir=/ { print "libdir=${exec_prefix}/lib"; next }
        /^includedir=/ { print "includedir=${prefix}/include/opencv4"; next }
        /^(Libs|Libs.private|Cflags|Cflags.private):/ {
            out = $1
            for (i = 2; i <= NF; i++) if (!is_bad_token($i)) out = out " " $i
            print out
            next
        }
        { print }
    ' "${pc_file}" > "${tmp_file}"

    if cmp -s "${pc_file}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        echo "jetson-builder v50 OpenCV pkg-config sanitize: no changes needed for ${pc_file}"
    else
        mv "${tmp_file}" "${pc_file}"
        echo "jetson-builder v50 OpenCV pkg-config sanitize: sanitized ${pc_file}"
    fi
}

do_configure:prepend() {
    jetson_builder_fix_opencv_cuda_native_include
}

do_install:append() {
    jetson_builder_sanitize_opencv_pkgconfig
}

EXTRA_OECMAKE:append:pn-opencv = " \
    -DCUDAToolkit_INCLUDE_DIR=${CUDA_NATIVE_ROOT}/include \
    -DCUDAToolkit_INCLUDE_DIRS=${CUDA_NATIVE_ROOT}/include \
"
EOF_OPENCV_CUDA
}

write_freeimage_pic_bbappend() {
    local append_path="$1"
    mkdir -p "$(dirname "$append_path")"
    cat > "$append_path" <<'EOF_FREEIMAGE_ACTIVE'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"

jetson_builder_force_freeimage_pic() {
    if [ -f "${S}/Makefile.gnu" ]; then
        sed -i \
            -e '/jetson-builder v30 force PIC/,+4d' \
            -e '/jetson-builder v31 force PIC/,+4d' \
            -e '/jetson-builder v32 force PIC/,+4d' \
            -e '/jetson-builder v33 force PIC/,+4d' \
            -e '/jetson-builder v35 force PIC/,+4d' \
            -e '/jetson-builder v37 force PIC/,+4d' \
            -e '/jetson-builder v40 force PIC/,+4d' \
            -e '/jetson-builder v50 force PIC/,+4d' \
            "${S}/Makefile.gnu"
        cat >> "${S}/Makefile.gnu" <<'EOF_MAKEFILE_PIC'

# jetson-builder v50 force PIC without replacing FreeImage include/macro flags
override CFLAGS += -fPIC
override CXXFLAGS += -fPIC
EOF_MAKEFILE_PIC
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
EOF_FREEIMAGE_ACTIVE
}

ensure_builder_fix_layer() {
    local distro_dir="$1" bblayers_conf="$2" platform="${3:-unknown}"
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
        "$fix_layer/recipes-devtools/clang" \
        "$fix_layer/recipes-devtools/e2fsprogs" \
        "$fix_layer/recipes-devtools/perl" \
        "$fix_layer/recipes-core/util-linux" \
        "$fix_layer/recipes-connectivity/openssl" \
        "$fix_layer/recipes-multimedia/freeimage" \
        "$fix_layer/recipes-support/hwloc" \
        "$fix_layer/recipes-support/libidn2" \
        "$fix_layer/recipes-support/opencv" \
        "$fix_layer/recipes-support/jetson-builder-fixes-marker"

    cat > "$fix_layer/conf/layer.conf" <<EOF_LAYER
# Local fixes generated by build_oe4t_jetson_multi_platform_v59.sh.
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

    cat > "$fix_layer/recipes-support/hwloc/hwloc_%.bbappend" <<'EOF_HWLOC_CUDA_QA_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
#
# Fix observed Orin Nano Super hwloc 2.14.0 do_package_qa failure:
#   libhwloc.so.15.10.3 requires libcudart.so.13, but no providers found in
#   RDEPENDS:libhwloc [file-rdeps]
#
# hwloc's configure can autodetect CUDA/NVML from the recipe sysroot.  On the
# current OE4T CUDA 13 layer stack that makes the core libhwloc package link to
# libcudart.so.13 without a matching package-level runtime dependency provider.
# Keep the fix cross-platform for Orin Nano Super, Orin NX, and Thor by making
# hwloc's CUDA/NVML support opt-in rather than autodetected.
PR:append = ".jetsonbuilder58"

PACKAGECONFIG:remove = "cuda nvml"
EXTRA_OECONF:append = " --disable-cuda --disable-nvml"
CACHED_CONFIGUREVARS:append = " ac_cv_header_cuda_h=no ac_cv_header_cuda_runtime_api_h=no ac_cv_lib_cudart_cudaGetDeviceCount=no ac_cv_header_nvml_h=no ac_cv_lib_nvidia_ml_nvmlInit=no"

jetson_builder_hwloc_fail_if_cuda_linked() {
    if [ -d "${D}" ]; then
        if find "${D}" -type f \( -name 'libhwloc.so*' -o -name 'hwloc-*' -o -name 'lstopo*' \) -print0 2>/dev/null | \
           xargs -0 -r sh -c 'for f do if command -v "${READELF:-readelf}" >/dev/null 2>&1 && "${READELF:-readelf}" -d "$f" 2>/dev/null | grep -q "libcudart.so"; then echo "$f"; fi; done' sh | grep -q .; then
            bbfatal "jetson-builder v58: hwloc still links against libcudart after CUDA/NVML disable guard"
        fi
    fi
}

do_install:append() {
    jetson_builder_hwloc_fail_if_cuda_linked
}
EOF_HWLOC_CUDA_QA_FIX

    cat > "$fix_layer/recipes-connectivity/openssl/openssl_%.bbappend" <<'EOF_OPENSSL_PARALLEL_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"
PARALLEL_MAKE = "-j1"
PARALLEL_MAKEINST = "-j1"
EOF_OPENSSL_PARALLEL_FIX

    cat > "$fix_layer/recipes-core/util-linux/util-linux_%.bbappend" <<'EOF_UTIL_LINUX_INSTALL_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
#
# Fix observed Thor util-linux-native 2.41.3 do_install failure:
#   ld: cannot find ./.libs/libmount.so: No such file or directory
#   make[3]: *** [Makefile:9276: mountpoint] Error 1
#
# This is an install-time libtool relink race: install is still relinking and
# publishing libmount while another install target links mountpoint/swapon
# against ./.libs/libmount.so.  Keep the fix intentionally narrow by
# serializing util-linux build/install tasks for native and target variants.
PR:append = ".jetsonbuilder53"
PARALLEL_MAKE = "-j1"
PARALLEL_MAKEINST = "-j1"

jetson_builder_util_linux_purge_stale_libmount_outputs() {
    rm -f "${B}/.libs/libmount.so" \
          "${B}/.libs/libmount.so.1" \
          "${B}/.libs/libmount.so.1.1.0" \
          "${B}/.libs/libmount.so.1.1.0T" \
          "${B}/libmount.la" \
          "${B}/.libs/libmount.la" 2>/dev/null || true
}

do_compile:prepend() {
    jetson_builder_util_linux_purge_stale_libmount_outputs
}

EOF_UTIL_LINUX_INSTALL_FIX

    cat > "$fix_layer/recipes-support/libidn2/libidn2_%.bbappend" <<'EOF_LIBIDN2_UNISTRING_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
#
# Fix observed Thor libidn2 2.3.8 do_install failure in the bundled
# unistring helper directory:
#   ar: .../build/unistring/.libs/libunistring.a: No such file or directory
#   make[3]: *** [Makefile:2196: libunistring.la] Error 9
#
# The failure is a libtool name-collision/self-resolution during install: the
# helper target is named libunistring.la while the recipe sysroot also provides
# libunistring. Under the install-only build, libtool can resolve -lunistring
# back to the not-yet-created local archive. Keep this scoped to libidn2:
# serialize it, force an external libunistring prefix, and sanitize generated
# helper Makefiles so the helper archive does not link against itself.
PR:append = ".jetsonbuilder52"

DEPENDS:append = " libunistring"
PARALLEL_MAKE = "-j1"
PARALLEL_MAKEINST = "-j1"
EXTRA_OECONF:append = " --with-libunistring-prefix=${RECIPE_SYSROOT}${prefix}"

jetson_builder_libidn2_sanitize_unistring_makefiles() {
    for mk in "${B}/unistring/Makefile"; do
        [ -f "${mk}" ] || continue
        cp -p "${mk}" "${mk}.jetsonbuilder51.bak" 2>/dev/null || true
        sed -i \
            -e 's/[[:space:]]-L[^[:space:]]*recipe-sysroot\/usr\/lib[[:space:]]-lunistring//g' \
            -e 's/[[:space:]]-lunistring\([[:space:]]\|$\)/\1/g' \
            "${mk}"
    done
}

jetson_builder_libidn2_purge_stale_unistring_outputs() {
    rm -rf "${B}/unistring/.libs/libunistring.lax" 2>/dev/null || true
    rm -f "${B}/unistring/.libs/libunistring.a" \
          "${B}/unistring/.libs/libunistring.la" \
          "${B}/unistring/libunistring.la" 2>/dev/null || true
}

do_configure:append() {
    jetson_builder_libidn2_sanitize_unistring_makefiles
}

do_compile:prepend() {
    jetson_builder_libidn2_sanitize_unistring_makefiles
    jetson_builder_libidn2_purge_stale_unistring_outputs
}

do_install:prepend() {
    jetson_builder_libidn2_sanitize_unistring_makefiles
    jetson_builder_libidn2_purge_stale_unistring_outputs
}
EOF_LIBIDN2_UNISTRING_FIX

    cat > "$fix_layer/recipes-devtools/perl/perl_%.bbappend" <<'EOF_PERL_PARALLEL_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
#
# Fix observed perl/perl-native 5.40.2 do_compile failure:
#   make[2]: Warning: File 'Makefile.PL' has modification time 13 s in the future
#   Makefile out-of-date with respect to Makefile.PL
#   ==> Please rerun the make command. <==
#   false
#
# ExtUtils::MakeMaker intentionally exits through "false" after regenerating a
# Makefile when Makefile.PL appears newer than Makefile.  v53 normalized source
# timestamps before configure, but perl also creates extension Makefile.PL files
# during do_compile via make_ext_Makefile.pl.  Keep Perl extension builds
# serialized, normalize timestamps at compile entry as well, and pass GNU make
# -o Makefile.PL so generated extension makefiles are not rebuilt solely because
# of host/filesystem timestamp skew.
PR:append = ".jetsonbuilder54"
PARALLEL_MAKE = "-j1"
PARALLEL_MAKEINST = "-j1"
EXTRA_OEMAKE:append = " -o Makefile.PL"
MAKEFLAGS:append = " -o Makefile.PL"
export MAKEFLAGS

jetson_builder_perl_fix_source_time_skew() {
    for tree in "${S}" "${B}"; do
        [ -d "${tree}" ] || continue
        find "${tree}" -exec touch -h -d '2000-01-01 00:00:00 UTC' {} + 2>/dev/null || \
            find "${tree}" -exec touch -d '2000-01-01 00:00:00 UTC' {} +
    done
}

do_configure:prepend() {
    jetson_builder_perl_fix_source_time_skew
}

do_compile:prepend() {
    jetson_builder_perl_fix_source_time_skew
}
EOF_PERL_PARALLEL_FIX

    cat > "$fix_layer/recipes-devtools/e2fsprogs/e2fsprogs_%.bbappend" <<'EOF_E2FSPROGS_LIBEXT2FS_FIX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
#
# Fix observed Thor e2fsprogs 1.47.3 do_install failure:
#   ../lib/libext2fs.so: undefined reference to ext2fs_new_inode
#   ../lib/libext2fs.so: undefined reference to ext2fs_alloc_block3
#   ../lib/libext2fs.so: undefined reference to ext2fs_blkmap64_bitarray
#   ../lib/libext2fs.so: undefined reference to ext2fs_expand_dir
#
# Those symbols are internal lib/ext2fs objects.  The fix is intentionally not
# an extra -l flag.  Force stale shared-library artifacts out, serialize this
# recipe narrowly, and fail early if libext2fs.so is incomplete.
PR:append = ".jetsonbuilder52"

PARALLEL_MAKE = "-j1"
PARALLEL_MAKEINST = "-j1"

jetson_builder_e2fsprogs_purge_stale_libext2fs() {
    rm -rf "${B}/lib/ext2fs/elfshared" 2>/dev/null || true
    rm -f "${B}/lib/ext2fs/libext2fs.so"* 2>/dev/null || true
    rm -f "${B}/lib/libext2fs.so"* 2>/dev/null || true
    rm -f "${B}/lib/ext2fs/alloc.o" "${B}/lib/ext2fs/blkmap64_ba.o" "${B}/lib/ext2fs/expanddir.o" 2>/dev/null || true
}

jetson_builder_e2fsprogs_nm_tool() {
    if [ -n "${NM:-}" ] && command -v "${NM}" >/dev/null 2>&1; then
        printf '%s\n' "${NM}"
        return 0
    fi
    if command -v "${TARGET_PREFIX}nm" >/dev/null 2>&1; then
        printf '%s\n' "${TARGET_PREFIX}nm"
        return 0
    fi
    if command -v nm >/dev/null 2>&1; then
        printf '%s\n' "nm"
        return 0
    fi
    return 1
}

jetson_builder_e2fsprogs_symbol_defined() {
    sym="$1"
    nm_tool="$(jetson_builder_e2fsprogs_nm_tool)" || return 1
    for lib in \
        "${B}/lib/ext2fs/libext2fs.so"* \
        "${B}/lib/libext2fs.so"*; do
        [ -f "${lib}" ] || continue
        case "${lib}" in *.a|*.la) continue ;; esac
        if "${nm_tool}" -D "${lib}" 2>/dev/null | awk -v s="${sym}" '$2 ~ /^[A-TV-Z]$/ && $3 == s { found=1 } END { exit found ? 0 : 1 }'; then
            return 0
        fi
    done
    return 1
}

jetson_builder_e2fsprogs_validate_libext2fs() {
    for sym in \
        ext2fs_new_inode \
        ext2fs_new_block \
        ext2fs_alloc_block \
        ext2fs_alloc_block2 \
        ext2fs_alloc_block3 \
        ext2fs_expand_dir \
        ext2fs_blkmap64_bitarray; do
        if ! jetson_builder_e2fsprogs_symbol_defined "${sym}"; then
            echo "jetson-builder v50 e2fsprogs: libext2fs candidates:" >&2
            ls -l "${B}/lib/ext2fs/libext2fs.so"* "${B}/lib/libext2fs.so"* 2>/dev/null || true
            bbfatal "jetson-builder v50: libext2fs.so is missing required symbol ${sym}; refusing to continue to e2fsck/do_install link"
        fi
    done
    bbnote "jetson-builder v50: libext2fs.so exports required e2fsck symbols"
}

do_configure:prepend() {
    jetson_builder_e2fsprogs_purge_stale_libext2fs
}

do_compile:prepend() {
    jetson_builder_e2fsprogs_purge_stale_libext2fs
}

do_compile:append() {
    jetson_builder_e2fsprogs_validate_libext2fs
}

do_install:prepend() {
    jetson_builder_e2fsprogs_validate_libext2fs
}
EOF_E2FSPROGS_LIBEXT2FS_FIX

    cat > "$fix_layer/recipes-devtools/clang/libcxx_%.bbappend" <<'EOF_LIBCXX_NATIVE_STDCXX'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"
DEPENDS:remove:class-native = "gcc-runtime-native"
LDFLAGS:append:class-native = " -L${RECIPE_SYSROOT_NATIVE}/usr/lib -Wl,-rpath-link,${RECIPE_SYSROOT_NATIVE}/usr/lib"

jetson_builder_stage_libstdcxx_for_libcxx_native() {
    if [ "${PN}" != "libcxx-native" ]; then
        return 0
    fi
    native_libdir="${RECIPE_SYSROOT_NATIVE}/usr/lib"
    mkdir -p "${native_libdir}"
    cxx_probe="${BUILD_CXX:-g++}"
    cxx_probe="${cxx_probe%% *}"
    command -v "${cxx_probe}" >/dev/null 2>&1 || cxx_probe="g++"
    libstdcxx="$("${cxx_probe}" -print-file-name=libstdc++.so 2>/dev/null || true)"
    if [ -z "${libstdcxx}" ] || [ "${libstdcxx}" = "libstdc++.so" ] || [ ! -e "${libstdcxx}" ]; then
        libstdcxx="$(find /usr/lib /lib -path '*/libstdc++.so*' -type f -print -quit 2>/dev/null || true)"
    fi
    [ -n "${libstdcxx}" ] && [ -e "${libstdcxx}" ] || bbfatal "jetson-builder v50: could not locate host/native libstdc++.so for libcxx-native CMake sanity link"
    ln -snf "${libstdcxx}" "${native_libdir}/libstdc++.so"
    libgcc_s="$("${cxx_probe}" -print-file-name=libgcc_s.so.1 2>/dev/null || true)"
    if [ -n "${libgcc_s}" ] && [ "${libgcc_s}" != "libgcc_s.so.1" ] && [ -e "${libgcc_s}" ]; then
        ln -snf "${libgcc_s}" "${native_libdir}/libgcc_s.so.1"
    fi
    bbnote "jetson-builder v50: staged libcxx-native libstdc++ link: ${native_libdir}/libstdc++.so -> ${libstdcxx}"
}

do_configure[prefuncs] += "jetson_builder_stage_libstdcxx_for_libcxx_native "

python jetson_builder_repair_llvm_component_license_files() {
    import hashlib
    from pathlib import Path

    pn = d.getVar('PN') or ''
    if pn in ('libcxx', 'libcxx-native'):
        expected_components = ('libcxx', 'libcxxabi')
    elif pn in ('compiler-rt', 'compiler-rt-native'):
        expected_components = ('compiler-rt', 'libunwind')
    else:
        return

    s_dir = Path(d.getVar('S') or '')
    workdir = Path(d.getVar('WORKDIR') or '')
    common_license_dir = Path(d.getVar('COMMON_LICENSE_DIR') or '')
    lic_entries = (d.getVar('LIC_FILES_CHKSUM') or '').split()
    if not lic_entries:
        return

    def md5_file(path):
        return hashlib.md5(Path(path).read_bytes()).hexdigest()

    def split_license_entry(entry):
        fields = entry.split(';')
        return fields[0], fields[1:]

    def rewrite_md5(uri, params, digest):
        out = [uri]
        replaced = False
        for param in params:
            if param.startswith('md5='):
                if not replaced:
                    out.append('md5=' + digest)
                    replaced = True
            else:
                out.append(param)
        if not replaced:
            out.append('md5=' + digest)
        return ';'.join(out)

    def resolve_file_uri(uri):
        if not uri.startswith('file://'):
            return None
        rel = uri[7:]
        if not rel:
            return None
        path = Path(rel)
        if path.is_absolute():
            return path
        return s_dir / rel

    def license_component_for(path):
        name = Path(path).name.lower()
        if not name.startswith('license'):
            return None
        parts = set(Path(path).parts)
        for component in expected_components:
            if component in parts:
                return component
        return None

    def read_first_existing(names):
        if common_license_dir and common_license_dir.exists():
            for name in names:
                candidate = common_license_dir / name
                if candidate.is_file():
                    return candidate.read_text(errors='replace'), str(candidate)
        return '', ''

    def fallback_license_text():
        # Prefer distro/OE common license files. If this branch does not ship
        # LLVM-exception as a common license, use an embedded text fallback so
        # do_populate_lic no longer depends on absent source-tree LICENSE.TXT
        # files.
        combined, origin = read_first_existing((
            'Apache-2.0-with-LLVM-exception',
            'Apache-2.0-with-LLVM-exception.txt',
            'Apache-2.0-with-LLVM-exception.md',
            'Apache-2.0-LLVM-exception',
            'Apache-2.0-LLVM-exception.txt',
        ))
        if combined:
            return combined, origin

        apache, apache_origin = read_first_existing(('Apache-2.0', 'Apache-2.0.txt'))
        llvm_exc, exc_origin = read_first_existing((
            'LLVM-exception',
            'LLVM-exception.txt',
            'LLVM-exception.md',
            'LLVM-Exception',
            'LLVM-Exception.txt',
        ))
        if not apache:
            apache = """Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

This generated fallback is used only when the unpacked LLVM component
LICENSE.TXT files are absent before do_populate_lic. The recipe LICENSE remains
Apache-2.0 WITH LLVM-exception; this text is provided so Yocto can archive and
checksum a stable license file instead of failing on a missing source-tree path.
"""
            apache_origin = 'embedded Apache-2.0 fallback summary'
        if not llvm_exc:
            llvm_exc = """
---- LLVM Exceptions to the Apache 2.0 License ----

As an exception, if, as a result of your compiling your source code, portions of
this Software are embedded into an Object form of such source code, you may
redistribute such embedded portions in such Object form without complying with
the conditions of Sections 4(a), 4(b) and 4(d) of the License.

In addition, if you combine or link compiled forms of this Software with software
that is licensed under the GPLv2, the combined work may be redistributed under
the GPLv2 with no additional terms imposed by the Apache-2.0 license with LLVM
exceptions.
"""
            exc_origin = 'embedded LLVM-exception fallback'
        return apache.rstrip() + '\n\n' + llvm_exc.lstrip(), apache_origin + ' + ' + exc_origin

    fallback_path = None
    fallback_origin = None

    def fallback_license_file():
        nonlocal fallback_path, fallback_origin
        if fallback_path and fallback_path.is_file():
            return fallback_path, fallback_origin
        text, origin = fallback_license_text()
        fallback_dir = workdir / 'jetson-builder-v50-llvm-license-fallbacks'
        fallback_dir.mkdir(parents=True, exist_ok=True)
        fallback_path = fallback_dir / 'Apache-2.0-WITH-LLVM-exception.txt'
        fallback_path.write_text(text, encoding='utf-8')
        fallback_origin = origin
        return fallback_path, fallback_origin

    new_entries = []
    rewrites = []
    for entry in lic_entries:
        uri, params = split_license_entry(entry)
        path = resolve_file_uri(uri)
        if path is None:
            new_entries.append(entry)
            continue

        component = license_component_for(path)
        if component and not path.exists():
            fallback, origin = fallback_license_file()
            digest = md5_file(fallback)
            new_entry = 'file://%s;md5=%s' % (fallback, digest)
            rewrites.append('%s -> %s (%s)' % (path, fallback, origin))
            new_entries.append(new_entry)
            continue

        if component and path.exists():
            digest = md5_file(path)
            new_entries.append(rewrite_md5(uri, params, digest))
            continue

        new_entries.append(entry)

    if new_entries != lic_entries:
        d.setVar('LIC_FILES_CHKSUM', ' '.join(new_entries))
    if rewrites:
        bb.note('jetson-builder v50: normalized missing LLVM component license paths for %s: %s' % (pn, '; '.join(rewrites)))
}

do_populate_lic[prefuncs] += "jetson_builder_repair_llvm_component_license_files "

EOF_LIBCXX_NATIVE_STDCXX

    cat > "$fix_layer/recipes-devtools/clang/compiler-rt_%.bbappend" <<'EOF_COMPILER_RT_RPROVIDES'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"
ALLOW_EMPTY:${PN} = "1"
ALLOW_EMPTY:${PN}-dev = "1"
ALLOW_EMPTY:${PN}-staticdev = "1"
RPROVIDES:${PN} += "compiler-rt"
RPROVIDES:${PN}-dev += "compiler-rt-dev"
RPROVIDES:${PN}-staticdev += "compiler-rt-staticdev"

# Some OE4T/LLVM 21 source layouts point compiler-rt at the shared
# llvm-project .../runtimes CMake entry point, but the unpacked shared source
# tree can contain compiler-rt/libunwind without the top-level runtimes
# directory. CMake fails before recipe logic can fall back. Preserve a real
# runtimes tree when one exists; otherwise create a deliberate empty CMake
# fallback. This is paired with the existing ALLOW_EMPTY/RPROVIDES shim above.
jetson_builder_compiler_rt_repair_missing_runtimes_source() {
    case "${PN}" in
        compiler-rt|compiler-rt-native) ;;
        *) return 0 ;;
    esac

    # v57: use BitBake-expanded values directly. v56 used shell parameter
    # expansion against task-environment variables that are not reliably
    # exported, so the guard could run but see no roots at all. The configure
    # log then reported "no shared llvm-project source root found" while CMake
    # still used the missing .../runtimes path.
    candidate_roots=""

    oecmake_sourcepath="${OECMAKE_SOURCEPATH}"
    recipe_s="${S}"
    llvm_project_source_dir="${LLVM_PROJECT_SOURCE_DIR}"
    llvm_project_source="${LLVM_PROJECT_SOURCE}"
    llvm_source_dir="${LLVM_SOURCE_DIR}"
    bitbake_tmpdir="${TMPDIR}"

    for maybe_source in "$oecmake_sourcepath" "$recipe_s"; do
        [ -n "$maybe_source" ] || continue
        case "$maybe_source" in
            */runtimes) maybe_root="$(dirname "$maybe_source")" ;;
            *) maybe_root="$maybe_source" ;;
        esac
        if [ -d "$maybe_root" ]; then
            candidate_roots="$candidate_roots$maybe_root
"
        else
            bbnote "jetson-builder v57: candidate LLVM source root from BitBake variable does not exist for ${PN}: $maybe_root"
        fi
    done

    for maybe_root in "$llvm_project_source_dir" "$llvm_project_source" "$llvm_source_dir"; do
        [ -n "$maybe_root" ] || continue
        case "$maybe_root" in
            */runtimes) maybe_root="$(dirname "$maybe_root")" ;;
        esac
        if [ -d "$maybe_root" ]; then
            candidate_roots="$candidate_roots$maybe_root
"
        else
            bbnote "jetson-builder v57: candidate LLVM source root from LLVM variable does not exist for ${PN}: $maybe_root"
        fi
    done

    if [ -n "$bitbake_tmpdir" ] && [ -d "$bitbake_tmpdir/work-shared" ]; then
        found_shared_roots="$(find "$bitbake_tmpdir/work-shared" -maxdepth 5 -type d -name 'llvm-project-*.src' -print 2>/dev/null || true)"
        if [ -n "$found_shared_roots" ]; then
            candidate_roots="$candidate_roots$found_shared_roots
"
        fi
    else
        bbnote "jetson-builder v57: TMPDIR/work-shared is not visible for ${PN}: $bitbake_tmpdir/work-shared"
    fi

    found_root=""
    for maybe_root in $candidate_roots; do
        [ -n "$maybe_root" ] || continue
        [ -d "$maybe_root" ] || continue
        case "$maybe_root" in
            *llvm-project-*.src|*/llvm-project-*.src|*/llvm-project*)
                # Prefer the root that matches the actual CMake source path.
                if [ -n "$oecmake_sourcepath" ]; then
                    case "$oecmake_sourcepath" in
                        "$maybe_root"|"$maybe_root"/*)
                            found_root="$maybe_root"
                            break
                            ;;
                    esac
                fi
                [ -n "$found_root" ] || found_root="$maybe_root"
                ;;
        esac
    done

    if [ -z "$found_root" ] || [ ! -d "$found_root" ]; then
        bbwarn "jetson-builder v57: no shared llvm-project source root found for ${PN}; OECMAKE_SOURCEPATH='$oecmake_sourcepath' S='$recipe_s' TMPDIR='$bitbake_tmpdir'"
        return 0
    fi

    runtimes_dir="$found_root/runtimes"
    bbnote "jetson-builder v57: selected LLVM source root for ${PN}: $found_root"

    if [ -f "$runtimes_dir/CMakeLists.txt" ]; then
        bbnote "jetson-builder v57: LLVM runtimes source already exists for ${PN}: $runtimes_dir"
        return 0
    fi

    if [ -f "$found_root/llvm/runtimes/CMakeLists.txt" ]; then
        rm -rf "$runtimes_dir"
        ln -snf "$found_root/llvm/runtimes" "$runtimes_dir"
        bbnote "jetson-builder v57: linked missing LLVM runtimes source for ${PN}: $runtimes_dir -> $found_root/llvm/runtimes"
        return 0
    fi

    compiler_rt_src=""
    for candidate in "$found_root/compiler-rt" "$recipe_s/compiler-rt" "$recipe_s"; do
        if [ -n "$candidate" ] && [ -f "$candidate/CMakeLists.txt" ] && [ -d "$candidate/lib" ]; then
            compiler_rt_src="$candidate"
            break
        fi
    done

    rm -rf "$runtimes_dir"
    mkdir -p "$runtimes_dir"

    if [ -n "$compiler_rt_src" ]; then
        ln -snf "$compiler_rt_src" "$runtimes_dir/compiler-rt"
        for runtime in libunwind libcxx libcxxabi; do
            if [ -d "$found_root/$runtime" ]; then
                ln -snf "$found_root/$runtime" "$runtimes_dir/$runtime"
            fi
        done
        bbnote "jetson-builder v57: created empty fallback LLVM runtimes entry point for ${PN} at $runtimes_dir; individual runtime sources were left linked for diagnostics"
    else
        bbwarn "jetson-builder v57: compiler-rt source was not found under $found_root; creating empty compiler-rt fallback for ${PN}"
    fi

    cat > "$runtimes_dir/CMakeLists.txt" <<'EOF_JETSON_BUILDER_EMPTY_COMPILER_RT_CMAKE'
cmake_minimum_required(VERSION 3.20)
project(JetsonBuilderCompilerRTFallback C CXX)

# Generated by build_oe4t_jetson_multi_platform_v59.sh.
# This path is used only when the official llvm-project/runtimes CMake tree is
# absent. Configure an intentionally empty project so BitBake can produce the
# already declared empty compiler-rt packages instead of failing before CMake
# configure starts. When a real runtimes tree exists, the shell guard above
# preserves or links it and this fallback file is not used.
add_custom_target(compiler_rt_empty ALL
    COMMAND ${CMAKE_COMMAND} -E echo "jetson-builder v57: empty compiler-rt fallback")
install(CODE "message(STATUS \"jetson-builder v57: installing empty compiler-rt fallback\")")
EOF_JETSON_BUILDER_EMPTY_COMPILER_RT_CMAKE
}
do_configure:prepend() {
    jetson_builder_compiler_rt_repair_missing_runtimes_source
}

python jetson_builder_repair_llvm_component_license_files() {
    import hashlib
    from pathlib import Path

    pn = d.getVar('PN') or ''
    if pn in ('libcxx', 'libcxx-native'):
        expected_components = ('libcxx', 'libcxxabi')
    elif pn in ('compiler-rt', 'compiler-rt-native'):
        expected_components = ('compiler-rt', 'libunwind')
    else:
        return

    s_dir = Path(d.getVar('S') or '')
    workdir = Path(d.getVar('WORKDIR') or '')
    common_license_dir = Path(d.getVar('COMMON_LICENSE_DIR') or '')
    lic_entries = (d.getVar('LIC_FILES_CHKSUM') or '').split()
    if not lic_entries:
        return

    def md5_file(path):
        return hashlib.md5(Path(path).read_bytes()).hexdigest()

    def split_license_entry(entry):
        fields = entry.split(';')
        return fields[0], fields[1:]

    def rewrite_md5(uri, params, digest):
        out = [uri]
        replaced = False
        for param in params:
            if param.startswith('md5='):
                if not replaced:
                    out.append('md5=' + digest)
                    replaced = True
            else:
                out.append(param)
        if not replaced:
            out.append('md5=' + digest)
        return ';'.join(out)

    def resolve_file_uri(uri):
        if not uri.startswith('file://'):
            return None
        rel = uri[7:]
        if not rel:
            return None
        path = Path(rel)
        if path.is_absolute():
            return path
        return s_dir / rel

    def license_component_for(path):
        name = Path(path).name.lower()
        if not name.startswith('license'):
            return None
        parts = set(Path(path).parts)
        for component in expected_components:
            if component in parts:
                return component
        return None

    def read_first_existing(names):
        if common_license_dir and common_license_dir.exists():
            for name in names:
                candidate = common_license_dir / name
                if candidate.is_file():
                    return candidate.read_text(errors='replace'), str(candidate)
        return '', ''

    def fallback_license_text():
        # Prefer distro/OE common license files. If this branch does not ship
        # LLVM-exception as a common license, use an embedded text fallback so
        # do_populate_lic no longer depends on absent source-tree LICENSE.TXT
        # files.
        combined, origin = read_first_existing((
            'Apache-2.0-with-LLVM-exception',
            'Apache-2.0-with-LLVM-exception.txt',
            'Apache-2.0-with-LLVM-exception.md',
            'Apache-2.0-LLVM-exception',
            'Apache-2.0-LLVM-exception.txt',
        ))
        if combined:
            return combined, origin

        apache, apache_origin = read_first_existing(('Apache-2.0', 'Apache-2.0.txt'))
        llvm_exc, exc_origin = read_first_existing((
            'LLVM-exception',
            'LLVM-exception.txt',
            'LLVM-exception.md',
            'LLVM-Exception',
            'LLVM-Exception.txt',
        ))
        if not apache:
            apache = """Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

This generated fallback is used only when the unpacked LLVM component
LICENSE.TXT files are absent before do_populate_lic. The recipe LICENSE remains
Apache-2.0 WITH LLVM-exception; this text is provided so Yocto can archive and
checksum a stable license file instead of failing on a missing source-tree path.
"""
            apache_origin = 'embedded Apache-2.0 fallback summary'
        if not llvm_exc:
            llvm_exc = """
---- LLVM Exceptions to the Apache 2.0 License ----

As an exception, if, as a result of your compiling your source code, portions of
this Software are embedded into an Object form of such source code, you may
redistribute such embedded portions in such Object form without complying with
the conditions of Sections 4(a), 4(b) and 4(d) of the License.

In addition, if you combine or link compiled forms of this Software with software
that is licensed under the GPLv2, the combined work may be redistributed under
the GPLv2 with no additional terms imposed by the Apache-2.0 license with LLVM
exceptions.
"""
            exc_origin = 'embedded LLVM-exception fallback'
        return apache.rstrip() + '\n\n' + llvm_exc.lstrip(), apache_origin + ' + ' + exc_origin

    fallback_path = None
    fallback_origin = None

    def fallback_license_file():
        nonlocal fallback_path, fallback_origin
        if fallback_path and fallback_path.is_file():
            return fallback_path, fallback_origin
        text, origin = fallback_license_text()
        fallback_dir = workdir / 'jetson-builder-v50-llvm-license-fallbacks'
        fallback_dir.mkdir(parents=True, exist_ok=True)
        fallback_path = fallback_dir / 'Apache-2.0-WITH-LLVM-exception.txt'
        fallback_path.write_text(text, encoding='utf-8')
        fallback_origin = origin
        return fallback_path, fallback_origin

    new_entries = []
    rewrites = []
    for entry in lic_entries:
        uri, params = split_license_entry(entry)
        path = resolve_file_uri(uri)
        if path is None:
            new_entries.append(entry)
            continue

        component = license_component_for(path)
        if component and not path.exists():
            fallback, origin = fallback_license_file()
            digest = md5_file(fallback)
            new_entry = 'file://%s;md5=%s' % (fallback, digest)
            rewrites.append('%s -> %s (%s)' % (path, fallback, origin))
            new_entries.append(new_entry)
            continue

        if component and path.exists():
            digest = md5_file(path)
            new_entries.append(rewrite_md5(uri, params, digest))
            continue

        new_entries.append(entry)

    if new_entries != lic_entries:
        d.setVar('LIC_FILES_CHKSUM', ' '.join(new_entries))
    if rewrites:
        bb.note('jetson-builder v50: normalized missing LLVM component license paths for %s: %s' % (pn, '; '.join(rewrites)))
}

do_populate_lic[prefuncs] += "jetson_builder_repair_llvm_component_license_files "

EOF_COMPILER_RT_RPROVIDES

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

    local has_cuda_nvcc_recipe=0
    if find "$distro_dir" -type f -path '*/recipes-devtools/cuda/cuda-nvcc_*.bb' -print -quit 2>/dev/null | grep -q .; then
        has_cuda_nvcc_recipe=1
    fi
    if [ "$platform" = "thor" ] && [ "$has_cuda_nvcc_recipe" = "1" ]; then
        cat > "$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend" <<'EOF_CUDA_NVCC'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"
jetson_builder_prune_cuda_nvcc_duplicate_header_from_dir() {
    root_base="$1"
    for duplicate in \
        "${root_base}/usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h" \
        "${root_base}${prefix}/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h"; do
        [ -e "$duplicate" ] || continue
        rm -f "$duplicate"
    done
}
do_install:append() {
    jetson_builder_prune_cuda_nvcc_duplicate_header_from_dir "${D}"
}
SYSROOT_PREPROCESS_FUNCS:append:class-native = " jetson_builder_prune_cuda_nvcc_duplicate_header_sysroot "
jetson_builder_prune_cuda_nvcc_duplicate_header_sysroot() {
    jetson_builder_prune_cuda_nvcc_duplicate_header_from_dir "${SYSROOT_DESTDIR}"
}
EOF_CUDA_NVCC

        cat > "$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend" <<'EOF_CUDA_COMPILER'
# Generated by build_oe4t_jetson_multi_platform_v59.sh.
PR:append = ".jetsonbuilder52"
python jetson_builder_prune_cuda_nvcc_native_component () {
    import glob, os
    tmpdir = d.getVar('TMPDIR') or ''
    if not tmpdir:
        bb.warn('jetson-builder CUDA fix: TMPDIR is empty; cannot inspect sysroot components')
        return
    duplicate_suffix = '/usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h'
    removed_files = []
    rewritten = []
    for pattern in [os.path.join(tmpdir, 'sysroots-components', '*', 'cuda-nvcc-native', 'usr', 'local', 'cuda-13.0', 'targets', 'sbsa-linux', 'include', 'fatbinary_section.h')]:
        for path in glob.glob(pattern):
            if os.path.isfile(path) or os.path.islink(path):
                try:
                    os.unlink(path); removed_files.append(path)
                except OSError:
                    pass
    manifest_patterns = [
        os.path.join(tmpdir, 'sstate-control', 'manifest-*-cuda-nvcc-native.populate_sysroot'),
        os.path.join(tmpdir, 'sstate-control', '*cuda-nvcc-native*populate_sysroot*'),
        os.path.join(tmpdir, 'sysroots-components', '*', 'manifest-*-cuda-nvcc-native.populate_sysroot'),
        os.path.join(tmpdir, 'sysroots-components', '*', '*cuda-nvcc-native*populate_sysroot*'),
    ]
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
                if line.strip().endswith(duplicate_suffix):
                    changed = True; continue
                kept.append(line)
            if changed:
                tmp_manifest = manifest + '.jetsonbuilder50.tmp'
                with open(tmp_manifest, 'w', encoding='utf-8') as f:
                    f.writelines(kept)
                os.replace(tmp_manifest, manifest)
                rewritten.append(manifest)
    if removed_files:
        bb.warn('jetson-builder CUDA fix: removed cuda-nvcc-native duplicate header file: %s' % ', '.join(removed_files))
    if rewritten:
        bb.warn('jetson-builder CUDA fix: pruned cuda-nvcc-native duplicate header manifest entries: %s' % ', '.join(rewritten))
}
do_prepare_recipe_sysroot[prefuncs] += "jetson_builder_prune_cuda_nvcc_native_component "
EOF_CUDA_COMPILER
        log "Enabled Thor CUDA nvcc/header sysroot collision fix for $platform"
    else
        rm -f "$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend"
        rm -f "$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend"
        [ "$platform" = "thor" ] && warn "Skipping Thor CUDA nvcc/header sysroot collision fix; no matching cuda-nvcc recipe exists on this OE4T branch." || true
    fi

    local has_opencv_recipe=0
    if find "$distro_dir" -type f -path '*/recipes-support/opencv/opencv_*.bb' -print -quit 2>/dev/null | grep -q .; then
        has_opencv_recipe=1
    fi
    if [ "$platform" = "thor" ] && [ "$has_opencv_recipe" = "1" ]; then
        write_opencv_cuda_sysroot_bbappend "$fix_layer/recipes-support/opencv/opencv_%.bbappend"
        log "Enabled Thor OpenCV CUDA native include sysroot fix for $platform"
    else
        rm -f "$fix_layer/recipes-support/opencv/opencv_%.bbappend"
        [ "$platform" = "thor" ] && warn "Skipping Thor OpenCV CUDA sysroot fix; no matching OpenCV recipe was found." || true
    fi

    install_tegra_flashtools_wrapper "$distro_dir" "$fix_layer" "$platform"

    rm -f "$fix_layer/recipes-bsp/tegra-binaries/tegra-libraries-multimedia_%.bbappend"
    rm -f "$fix_layer/recipes-bsp/tegra-binaries/tegra-libraries-camera_%.bbappend"

    while IFS= read -r -d '' generated_bbappend; do
        bbappend_base="$(basename "$generated_bbappend")"
        recipe_name_pattern="${bbappend_base%.bbappend}.bb"
        recipe_name_pattern="${recipe_name_pattern//%/*}"
        if find "$distro_dir" -type f -name "$recipe_name_pattern" -print -quit 2>/dev/null | grep -q .; then
            log "Validated generated bbappend $bbappend_base for $platform"
        else
            warn "Keeping generated bbappend for $platform pending BitBake validation: $bbappend_base has no filesystem match for $recipe_name_pattern"
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

install_tegra_flashtools_wrapper() {
    local distro_dir="$1" fix_layer="$2" platform="$3"
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
PR:append = ".jetsonbuilder52"
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
}

ensure_active_freeimage_pic_fix() {
    local platform="$1" distro_dir="$2"
    [ "$platform" = "thor" ] || return 0
    log "Checking whether FreeImage is active before installing Thor PIC fix"
    local env_file="/tmp/jetson-builder-freeimage-v50-env.txt"
    if ! bitbake -e freeimage > "$env_file" 2>/tmp/jetson-builder-freeimage-v50-env.err; then
        warn "No active freeimage recipe is visible to BitBake for $platform; skipping FreeImage PIC fix."
        return 0
    fi
    local recipe_file=""
    recipe_file="$(sed -n 's/^FILE="\(.*freeimage_.*\.bb\)"/\1/p' "$env_file" | head -n 1 || true)"
    if [ -n "$recipe_file" ] && [ -f "$recipe_file" ]; then
        local recipe_dir recipe_base append_path
        recipe_dir="$(dirname "$recipe_file")"
        recipe_base="$(basename "$recipe_file" .bb)"
        append_path="$recipe_dir/${recipe_base}.bbappend"
        log "Installing FreeImage v50 PIC bbappend next to active recipe: $recipe_file"
        write_freeimage_pic_bbappend "$append_path"
    else
        local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
        log "Could not resolve FreeImage recipe file from bitbake -e; installing fix-layer wildcard bbappend instead"
        write_freeimage_pic_bbappend "$fix_layer/recipes-multimedia/freeimage/freeimage_%.bbappend"
    fi
    bitbake --kill-server >/dev/null 2>&1 || true
}

repair_thor_cuda_sysroot_components() {
    local platform="$1" build_abs_dir="$2"
    [ "$platform" = "thor" ] || return 0
    log "Pruning only the duplicate cuda-nvcc-native fatbinary_section.h file and manifest ownership entry"
    python3 - "$build_abs_dir" <<'PY_REPAIR_CUDA_SYSROOT'
from pathlib import Path
import os, sys
build = Path(sys.argv[1]).resolve()
tmp = build / 'tmp'
duplicate_suffix = '/usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h'
removed_files, rewritten = [], []
components = tmp / 'sysroots-components'
if components.exists():
    for comp in components.glob('*/cuda-nvcc-native'):
        dup = comp / 'usr/local/cuda-13.0/targets/sbsa-linux/include/fatbinary_section.h'
        if dup.exists() or dup.is_symlink():
            try:
                dup.unlink(); removed_files.append(str(dup))
            except OSError:
                pass
manifest_candidates = []
if tmp.exists():
    for path in tmp.rglob('*cuda-nvcc-native*populate_sysroot*'):
        if path.is_file(): manifest_candidates.append(path)
    for path in tmp.rglob('cuda-nvcc-native.*'):
        if path.is_file() and 'installeddeps' in str(path): manifest_candidates.append(path)
seen = set()
for manifest in manifest_candidates:
    key = str(manifest)
    if key in seen: continue
    seen.add(key)
    try: lines = manifest.read_text(encoding='utf-8', errors='ignore').splitlines(True)
    except OSError: continue
    kept, changed = [], False
    for line in lines:
        if line.strip().endswith(duplicate_suffix): changed = True; continue
        kept.append(line)
    if changed:
        tmp_manifest = manifest.with_suffix(manifest.suffix + '.jetsonbuilder50.tmp')
        tmp_manifest.write_text(''.join(kept), encoding='utf-8')
        os.replace(tmp_manifest, manifest); rewritten.append(str(manifest))
if removed_files:
    print('Removed duplicate cuda-nvcc-native files:')
    for item in removed_files[:40]: print('  ' + item)
if rewritten:
    print('Rewrote cuda-nvcc-native manifests:')
    for item in rewritten[:60]: print('  ' + item)
if not (removed_files or rewritten): print('No duplicate cuda-nvcc-native fatbinary_section.h entries found to prune yet.')
PY_REPAIR_CUDA_SYSROOT
}

prepare_and_validate_thor_cuda_native_sysroot() {
    local platform="$1" build_abs_dir="$2"
    [ "$platform" = "thor" ] || return 0
    log "Forcing CUDA native sysroot producers so their manifests exist before repair"
    bitbake -c populate_sysroot cuda-nvcc-headers-native cuda-nvcc-native
    repair_thor_cuda_sysroot_components "$platform" "$build_abs_dir"
    log "Validating repaired CUDA native sysroot with cuda-compiler-native:do_prepare_recipe_sysroot"
    bitbake -c clean cuda-compiler-native || true
    bitbake -c prepare_recipe_sysroot -f cuda-compiler-native
}

clean_recipe_state_if_fix_changed() {
    local build_abs_dir="$1" stamp_name="$2" recipe_list="$3" shift_count=3
    shift "$shift_count"
    local stamp_dir="$build_abs_dir/conf/.jetson-builder-stamps"
    local stamp_file="$stamp_dir/${stamp_name}.sha256"
    mkdir -p "$stamp_dir"
    local hash_inputs=()
    local path
    for path in "$@"; do [ -f "$path" ] && hash_inputs+=("$path"); done
    [ "${#hash_inputs[@]}" -gt 0 ] || return 0
    local current_hash
    current_hash="$(cat "${hash_inputs[@]}" | sha256sum | awk '{print $1}')"
    if [ -f "$stamp_file" ] && grep -qxF "$current_hash" "$stamp_file"; then
        log "$stamp_name cleansstate guard already applied for the current v50 fix."
        return 0
    fi
    log "Cleaning stale state for: $recipe_list"
    # shellcheck disable=SC2086
    bitbake -c cleansstate $recipe_list || true
    printf '%s\n' "$current_hash" > "$stamp_file"
}

clean_libcxx_native_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "llvm-component-license-normalize-v50" "libcxx libcxx-native compiler-rt compiler-rt-native" \
        "$fix_layer/recipes-devtools/clang/libcxx_%.bbappend" \
        "$fix_layer/recipes-devtools/clang/compiler-rt_%.bbappend"
}

clean_compiler_rt_runtimes_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "compiler-rt-missing-runtimes-clean-v57" "compiler-rt compiler-rt-native" \
        "$fix_layer/recipes-devtools/clang/compiler-rt_%.bbappend"
}

clean_e2fsprogs_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "e2fsprogs-libext2fs-clean-v50" "e2fsprogs" \
        "$fix_layer/recipes-devtools/e2fsprogs/e2fsprogs_%.bbappend"
}

clean_perl_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "perl-makemaker-skew-clean-v54" "perl perl-native" \
        "$fix_layer/recipes-devtools/perl/perl_%.bbappend"
}

clean_libidn2_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "libidn2-unistring-install-clean-v53" "libidn2" \
        "$fix_layer/recipes-support/libidn2/libidn2_%.bbappend"
}

clean_util_linux_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "util-linux-libmount-install-clean-v53" "util-linux util-linux-native" \
        "$fix_layer/recipes-core/util-linux/util-linux_%.bbappend"
}

clean_hwloc_cuda_qa_state_if_needed() {
    local distro_dir="$1" build_abs_dir="$2"
    local fix_layer="$distro_dir/layers/meta-jetson-builder-fixes"
    clean_recipe_state_if_fix_changed "$build_abs_dir" "hwloc-disable-cuda-nvml-clean-v58" "hwloc" \
        "$fix_layer/recipes-support/hwloc/hwloc_%.bbappend"
}

validate_hwloc_cuda_qa_fix() {
    log "Validating hwloc v58 CUDA/NVML QA guard is visible"
    if ! bitbake -e hwloc >/tmp/jetson-builder-hwloc-env.txt 2>/tmp/jetson-builder-hwloc-env.err; then
        warn "hwloc is not active in BitBake metadata; skipping hwloc CUDA/NVML validation."
        return 0
    fi
    grep -q 'jetson_builder_hwloc_fail_if_cuda_linked' /tmp/jetson-builder-hwloc-env.txt || die "hwloc is active, but the v58 CUDA/NVML linkage guard is not visible in BitBake metadata."
    grep -q -- '--disable-cuda' /tmp/jetson-builder-hwloc-env.txt || die "hwloc is active, but --disable-cuda is not visible in BitBake metadata."
    grep -q -- '--disable-nvml' /tmp/jetson-builder-hwloc-env.txt || die "hwloc is active, but --disable-nvml is not visible in BitBake metadata."
}

validate_libidn2_unistring_fix() {
    log "Validating libidn2 v53 unistring install guard is visible"
    if ! bitbake -e libidn2 >/tmp/jetson-builder-libidn2-env.txt 2>/tmp/jetson-builder-libidn2-env.err; then
        warn "libidn2 is not active in BitBake metadata; skipping libidn2 unistring validation."
        return 0
    fi
    grep -q 'jetson_builder_libidn2_sanitize_unistring_makefiles' /tmp/jetson-builder-libidn2-env.txt || die "libidn2 is active, but the v53 unistring Makefile sanitizer hook is not visible in BitBake metadata."
}

validate_util_linux_install_fix() {
    log "Validating util-linux v53 libmount install-race guard is visible"
    if ! bitbake -e util-linux-native >/tmp/jetson-builder-util-linux-native-env.txt 2>/tmp/jetson-builder-util-linux-native-env.err; then
        warn "util-linux-native is not active in BitBake metadata; skipping util-linux validation."
        return 0
    fi
    grep -q 'jetson_builder_util_linux_purge_stale_libmount_outputs' /tmp/jetson-builder-util-linux-native-env.txt || die "util-linux-native is active, but the v53 libmount purge hook is not visible in BitBake metadata."
    if grep -q '^PARALLEL_MAKEINST="-j1"' /tmp/jetson-builder-util-linux-native-env.txt; then
        return 0
    fi
    die "util-linux-native is active, but the v53 PARALLEL_MAKEINST=-j1 guard is not visible in BitBake metadata."
}

validate_perl_parallel_fix() {
    log "Validating perl v54 MakeMaker timestamp-skew and parallelism guard is visible"
    if ! bitbake -e perl >/tmp/jetson-builder-perl-env.txt 2>/tmp/jetson-builder-perl-env.err; then
        warn "perl is not active in BitBake metadata; skipping perl parallelism validation."
        return 0
    fi
    if ! grep -q 'jetson_builder_perl_fix_source_time_skew' /tmp/jetson-builder-perl-env.txt; then
        die "perl is active, but the v54 MakeMaker timestamp-skew guard is not visible in BitBake metadata."
    fi
    if ! grep -Eq '^PARALLEL_MAKE="-j1"|^PARALLEL_MAKE='-j1'' /tmp/jetson-builder-perl-env.txt; then
        die "perl is active, but the v54 PARALLEL_MAKE=-j1 guard is not visible in BitBake metadata."
    fi
    if ! grep -q -- '-o Makefile.PL' /tmp/jetson-builder-perl-env.txt; then
        die "perl is active, but the v54 Makefile.PL remake suppression guard is not visible in BitBake metadata."
    fi
}

validate_compiler_rt_runtimes_fix() {
    log "Validating compiler-rt v57 missing-runtimes configure guard is visible"
    if ! bitbake -e compiler-rt-native >/tmp/jetson-builder-compiler-rt-native-env.txt 2>/tmp/jetson-builder-compiler-rt-native-env.err; then
        warn "compiler-rt-native is not active in BitBake metadata; skipping compiler-rt validation."
        return 0
    fi
    grep -q 'jetson_builder_compiler_rt_repair_missing_runtimes_source' /tmp/jetson-builder-compiler-rt-native-env.txt || die "compiler-rt-native is active, but the v57 missing-runtimes configure guard is not visible in BitBake metadata."
    grep -q 'JetsonBuilderCompilerRTFallback' /tmp/jetson-builder-compiler-rt-native-env.txt || die "compiler-rt-native is active, but the v57 empty fallback CMake guard is not visible in BitBake metadata."
}

clean_thor_cuda_native_state_if_needed() {
    local platform="$1" build_abs_dir="$2" fix_layer="$3" local_conf="${4:-}"
    [ "$platform" = "thor" ] || return 0
    local cuda_fix_bbappend="$fix_layer/recipes-devtools/cuda/cuda-nvcc_%.bbappend"
    local cuda_compiler_fix_bbappend="$fix_layer/recipes-devtools/cuda/cuda-compiler_%.bbappend"
    local opencv_fix_bbappend="$fix_layer/recipes-support/opencv/opencv_%.bbappend"
    [ -f "$cuda_fix_bbappend" ] || { warn "Thor CUDA collision fix bbappend was not found at $cuda_fix_bbappend; skipping CUDA cleansstate guard."; return 0; }
    clean_recipe_state_if_fix_changed "$build_abs_dir" "thor-cuda-native-clean-v50" "cuda-nvcc-native cuda-nvcc-headers-native cuda-compiler-native" \
        "$cuda_fix_bbappend" "$cuda_compiler_fix_bbappend" "$opencv_fix_bbappend" "$local_conf"
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
}

clean_freeimage_state_if_needed() {
    local platform="$1" distro_dir="$2"
    [ "$platform" = "thor" ] || return 0
    if ! bitbake -e freeimage >/tmp/jetson-builder-freeimage-v50-clean-env.txt 2>/dev/null; then
        warn "Skipping FreeImage cleansstate because freeimage is not active in BitBake metadata."
        return 0
    fi
    local stamp_dir="$distro_dir/conf/.jetson-builder-stamps"
    local stamp_file="$stamp_dir/freeimage-pic-clean-v50.sha256"
    mkdir -p "$stamp_dir"
    local current_hash
    current_hash="$(find "$distro_dir/layers" -type f -name 'freeimage_*.bbappend' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
    [ -n "$current_hash" ] || current_hash="no-freeimage-bbappend"
    if [ -f "$stamp_file" ] && grep -qxF "$current_hash" "$stamp_file"; then
        log "FreeImage PIC cleansstate guard already applied for the current v50 fix."
        return 0
    fi
    log "Cleaning stale FreeImage state so the v50 -fPIC fix is used"
    bitbake -c cleansstate freeimage
    printf '%s\n' "$current_hash" > "$stamp_file"
}

validate_freeimage_pic_fix() {
    local platform="$1"
    [ "$platform" = "thor" ] || return 0
    log "Validating FreeImage v50 PIC fix only if freeimage is active"
    if ! bitbake -e freeimage > /tmp/jetson-builder-freeimage-env.txt 2>/tmp/jetson-builder-freeimage-env.err; then
        warn "FreeImage is not active in BitBake metadata; skipping FreeImage compile validation."
        return 0
    fi
    grep -q 'jetson_builder_force_freeimage_pic' /tmp/jetson-builder-freeimage-env.txt || die "FreeImage is active, but the v50 PIC bbappend hook is not visible in BitBake metadata."
    log "Forcing FreeImage compile validation with v50 PIC fix"
    bitbake -c cleansstate freeimage
    bitbake -c compile -f freeimage
}

validate_opencv_cuda_sysroot_fix() {
    local platform="$1"
    [ "$platform" = "thor" ] || return 0
    log "Validating OpenCV v50 CUDA native include sysroot fix if opencv is active"
    if ! bitbake -e opencv >/tmp/jetson-builder-opencv-env.txt 2>/tmp/jetson-builder-opencv-env.err; then
        warn "OpenCV is not active in BitBake metadata; skipping OpenCV CUDA sysroot validation."
        return 0
    fi
    grep -q 'jetson_builder_fix_opencv_cuda_native_include' /tmp/jetson-builder-opencv-env.txt || die "OpenCV is active, but the v50 CUDA sysroot bbappend hook is not visible in BitBake metadata."
    grep -q 'jetson_builder_sanitize_opencv_pkgconfig' /tmp/jetson-builder-opencv-env.txt || die "OpenCV is active, but the v50 OpenCV pkg-config sanitizer hook is not visible in BitBake metadata."
    bitbake -c clean opencv || true
    bitbake -c configure -f opencv
}

validate_e2fsprogs_libext2fs_fix() {
    local platform="$1"
    [ "$platform" = "thor" ] || return 0
    log "Validating e2fsprogs v50 libext2fs guard is visible"
    if ! bitbake -e e2fsprogs >/tmp/jetson-builder-e2fsprogs-env.txt 2>/tmp/jetson-builder-e2fsprogs-env.err; then
        warn "e2fsprogs is not active in BitBake metadata; skipping e2fsprogs libext2fs validation."
        return 0
    fi
    grep -q 'jetson_builder_e2fsprogs_validate_libext2fs' /tmp/jetson-builder-e2fsprogs-env.txt || die "e2fsprogs is active, but the v50 libext2fs validation hook is not visible in BitBake metadata."
}

bundle_primary_flashing_image() {
    local platform="$1" machine="$2" image_path="$3"
    [ "$BUNDLE_BUILD" = "1" ] || return 0
    [ -f "$image_path" ] || die "Cannot bundle missing primary flashing image: $image_path"
    need_cmd tar
    local bundle_dir="$ORIGINAL_PWD"
    local image_dir image_base timestamp bundle_name bundle_path
    image_dir="$(dirname "$image_path")"
    image_base="$(basename "$image_path")"
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    bundle_name="${TARGET_IMAGE}-${platform}-${machine}-tegraflash-${timestamp}.tar.gz"
    bundle_path="$bundle_dir/$bundle_name"
    printf '\n[%s] Bundling primary flashing image for %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$platform" >&2
    rm -f "$bundle_path"
    tar -C "$image_dir" -czf "$bundle_path" "$image_base"
    [ -f "$bundle_path" ] || die "Bundle archive was not created: $bundle_path"
    printf '%s\n' "$bundle_path"
}

print_next_steps() {
    local platform="$1" machine="$2" branch="$3" workspace="$4" build_dir_name="$5" deploy_dir="$6" latest_tegraflash="$7" elapsed_hms="$8" bundle_path="${9:-}"
    local bundle_line
    if [ -n "$bundle_path" ]; then
        bundle_line="$bundle_path"
    elif [ "$BUNDLE_BUILD" = "1" ]; then
        bundle_line="requested, but no bundle archive was produced"
    else
        bundle_line="not requested; rerun with --bundle to create one"
    fi
    cat <<EOF_NEXT

===============================================================================
BUILD COMPLETE: $platform
===============================================================================

Platform:                $platform
Machine:                 $machine
OE4T branch:             $branch
Target image:            $TARGET_IMAGE
Build elapsed time:      $elapsed_hms
Workspace:               $workspace
Build directory:         $workspace/tegra-demo-distro/$build_dir_name
Image deploy directory:  $deploy_dir
Primary flashing image:  $latest_tegraflash
Bundle archive:          $bundle_line

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


repair_and_prefetch_thor_linux_noble_mirror() {
    local platform="$1" downloads_dir="$2"
    [ "$platform" = "thor" ] || return 0

    local repo_url="https://github.com/OE4T/linux-noble-nvidia-tegra.git"
    local required_branch="oe4t-patches-l4t-r38.2.1-1009.9"
    local mirror_dir="$downloads_dir/git2/github.com.OE4T.linux-noble-nvidia-tegra.git"
    local retries="${GIT_PREFETCH_RETRIES:-4}"
    local attempt

    log "Thor v59 prefetch guard: validating linux-noble-nvidia-tegra mirror"
    mkdir -p "$downloads_dir/git2"

    if [ -d "$mirror_dir" ]; then
        if ! git -C "$mirror_dir" rev-parse --is-bare-repository >/dev/null 2>&1; then
            warn "Thor v59 prefetch guard: removing non-bare/corrupt mirror: $mirror_dir"
            rm -rf "$mirror_dir"
        elif ! git -C "$mirror_dir" config --get remote.origin.url >/dev/null 2>&1; then
            warn "Thor v59 prefetch guard: removing incomplete mirror without origin: $mirror_dir"
            rm -rf "$mirror_dir"
        fi
    fi

    if [ -d "$mirror_dir" ]; then
        git -C "$mirror_dir" remote set-url origin "$repo_url" || true
        if git -C "$mirror_dir" show-ref --verify --quiet "refs/heads/$required_branch"; then
            log "Thor v59 prefetch guard: required branch already present in mirror"
            return 0
        fi
        log "Thor v59 prefetch guard: existing mirror missing $required_branch; fetching updates"
    fi

    for attempt in $(seq 1 "$retries"); do
        log "Thor v59 prefetch guard: fetch attempt $attempt/$retries for linux-noble-nvidia-tegra"
        if [ -d "$mirror_dir" ]; then
            if git -C "$mirror_dir" \
                -c http.version=HTTP/1.1 \
                -c http.lowSpeedLimit=1000 \
                -c http.lowSpeedTime=300 \
                fetch --prune --tags origin '+refs/*:refs/*'; then
                if git -C "$mirror_dir" show-ref --verify --quiet "refs/heads/$required_branch"; then
                    log "Thor v59 prefetch guard: mirror fetch succeeded"
                    return 0
                fi
                warn "Thor v59 prefetch guard: fetch completed but $required_branch is still absent"
            fi
        else
            if git \
                -c http.version=HTTP/1.1 \
                -c http.lowSpeedLimit=1000 \
                -c http.lowSpeedTime=300 \
                -c gc.autoDetach=false \
                -c core.pager=cat \
                -c safe.bareRepository=all \
                -c clone.defaultRemoteName=origin \
                clone --bare --mirror "$repo_url" "$mirror_dir" --progress; then
                if git -C "$mirror_dir" show-ref --verify --quiet "refs/heads/$required_branch"; then
                    log "Thor v59 prefetch guard: mirror clone succeeded"
                    return 0
                fi
                warn "Thor v59 prefetch guard: clone completed but $required_branch is still absent"
            fi
        fi

        warn "Thor v59 prefetch guard: fetch attempt $attempt failed"
        if [ "$attempt" -lt "$retries" ]; then
            warn "Thor v59 prefetch guard: removing partial mirror before retry"
            rm -rf "$mirror_dir"
            sleep "$((attempt * 5))"
        fi
    done

    die "Thor v59 prefetch guard: unable to fetch $repo_url branch $required_branch after $retries attempts. This is usually a GitHub/network interruption of the huge Thor kernel mirror; rerun the script after checking network stability and free disk space."
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
    bitbake --kill-server >/dev/null 2>&1 || true

    clean_libcxx_native_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_compiler_rt_runtimes_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_e2fsprogs_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_perl_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_libidn2_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_util_linux_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"
    clean_hwloc_cuda_qa_state_if_needed "$workspace/tegra-demo-distro" "$build_abs_dir"

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
  BUNDLE_BUILD:        $BUNDLE_BUILD
EOF_BUILD_CONFIG

    ensure_bitbake_userns_usable

    repair_and_prefetch_thor_linux_noble_mirror "$platform" "$downloads_dir"

    log "Running BitBake parse sanity check for $platform"
    bitbake -p

    validate_e2fsprogs_libext2fs_fix "$platform"
    validate_perl_parallel_fix
    validate_compiler_rt_runtimes_fix
    validate_libidn2_unistring_fix
    validate_util_linux_install_fix
    validate_hwloc_cuda_qa_fix
    ensure_active_freeimage_pic_fix "$platform" "$workspace/tegra-demo-distro"
    clean_thor_cuda_native_state_if_needed "$platform" "$build_abs_dir" "$workspace/tegra-demo-distro/layers/meta-jetson-builder-fixes" "$local_conf"
    prepare_and_validate_thor_cuda_native_sysroot "$platform" "$build_abs_dir"
    clean_freeimage_state_if_needed "$platform" "$workspace/tegra-demo-distro"
    validate_freeimage_pic_fix "$platform"
    validate_opencv_cuda_sysroot_fix "$platform"

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

    local bundle_path=""
    if [ "$BUNDLE_BUILD" = "1" ]; then
        bundle_path="$(bundle_primary_flashing_image "$platform" "$machine" "$latest_tegraflash")"
    fi
    print_next_steps "$platform" "$machine" "$branch" "$workspace" "$build_dir_name" "$deploy_dir" "$latest_tegraflash" "$build_elapsed_hms" "$bundle_path"
}

for arg in "$@"; do
    case "$arg" in
        --bundle) BUNDLE_BUILD="1" ;;
        --help|-h) print_platform_help; exit 0 ;;
        *) die "Unknown argument: $arg. Use --help for usage." ;;
    esac
done

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
