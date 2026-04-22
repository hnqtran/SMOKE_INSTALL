#!/bin/bash
# SMOKE Spack Deployment Engine - AMD AOCC
# Dedicated track for AMD AOCC hydration and SMOKE compilation.

set -euo pipefail

cleanup_on_error() {
    echo "==> [ERROR] Build failed! Cleaning up intermediate environment to prevent corruption..."
    rm -rf "${PWD}/envs/${ENV_NAME:-default}"
    exit 1
}
trap cleanup_on_error ERR

preflight_check() {
    local req_tools=("python3" "git" "tar" "gcc" "bzip2" "xz")
    for tool in "${req_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "==> [ERROR] Missing required tool: $tool"
            exit 1
        fi
    done
}
preflight_check

# --- 1. Argument Parsing & Defaults ---
if [[ "${1:-}" == smoke* && "${2:-}" == %* ]]; then
    COMPILER_SPEC="$1 $2"
    MY_INSTALL_ROOT="${3:-$PWD/install_aocc}"
else
    COMPILER_SPEC="${1:-%gcc}"
    MY_INSTALL_ROOT="${2:-$PWD/install_aocc}"
fi
[[ "$MY_INSTALL_ROOT" != /* ]] && MY_INSTALL_ROOT="$PWD/$MY_INSTALL_ROOT"

if [ -d "/opt/smoke_foundation/spack" ]; then
    SPACK_ROOT="/opt/smoke_foundation/spack"
    PACKAGES_ROOT="/opt/smoke_foundation/spack-packages"
else
    SPACK_ROOT="$PWD/spack"
    PACKAGES_ROOT="${PWD}/spack-packages"
fi
BUILD_STATIC="${BUILD_STATIC:-0}"
SPACK_VERSION="${SPACK_VERSION:-develop}"
SPACK_TARGET="${SPACK_TARGET:-x86_64}"

# --- 2. Helper Functions ---

log() { echo "==> [AOCC] $1"; }

get_safe_build_jobs() {
    local jobs=$(awk '/MemAvailable/ {printf "("%.0f", $2 / 1024 / 1024 / 2}' /proc/meminfo 2>/dev/null)
    local cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    [[ -z "$jobs" ]] && jobs=2
    [[ $jobs -lt 1 ]] && jobs=1
    [[ $jobs -gt $cores ]] && jobs=$cores
    echo $jobs
}

setup_spack_and_repos() {
    if [ ! -d "spack" ]; then
        log "Dynamically identifying latest stable Spack release..."
        # Querying tags, filtering for stable releases (avoiding pre/alpha/beta), and grabbing the highest
        LATEST_STABLE=$(git ls-remote --tags https://github.com/spack/spack.git | \
                        grep -o "refs/tags/v[0-9]*\.[0-9]*\.[0-9]*$" | \
                        sed 's/refs\/tags\///' | \
                        sort -V | tail -n 1)
        
        log "Found Latest Stable: ${LATEST_STABLE}. Hydrating foundation..."
        git clone -b "${LATEST_STABLE}" --depth 1 https://github.com/spack/spack.git
        export SPACK_VERSION="${LATEST_STABLE}"
    fi
    if [[ ! -d "$PACKAGES_ROOT" ]]; then
        log "Cloning core repository..."
        git clone --depth 1 https://github.com/spack/spack-packages.git "$PACKAGES_ROOT"
    fi
    
    source "$SPACK_ROOT/share/spack/setup-env.sh"
    export SPACK_DISABLE_LOCAL_CONFIG=1

    log "Wiping site and local configurations..."
    mkdir -p "$SPACK_ROOT/etc/spack"
    rm -f "$SPACK_ROOT/etc/spack/"{config,packages,compilers,repos}.yaml
    rm -rf "$SPACK_ROOT/etc/spack/"{site,linux}
    rm -rf "${PWD}/envs"
    rm -rf "${PWD}/.spack" || true

    MIRROR_DIR="${PWD}/spack_mirror"
    log "Creating Safe Mirror to isolate incompatible submodule recipes..."
    rm -rf "${MIRROR_DIR}" && mkdir -p "${MIRROR_DIR}/packages"
    printf "repo:\n  namespace: builtin_mirror\n" > "${MIRROR_DIR}/repo.yaml"
    # Link ONLY infra what we need from the submodule
    WANTED_PKGS=("zlib" "zlib_ng" "libiconv" "gmp" "mpfr" "mpc" "zstd" "gmake" "cmake" "binutils" "pkgconf" "diffutils" "perl" "m4")
    log "Hydrating Minimalist Mirror: ${WANTED_PKGS[*]}..."
    for pkg_name in "${WANTED_PKGS[@]}"; do
        pkg_src="${PACKAGES_ROOT}/repos/spack_repo/builtin/packages/${pkg_name}"
        # Standardize naming: zlib_ng (submodule) -> zlib-ng (expected by SMOKE)
        pkg_dst_name="${pkg_name//_/-}"
        if [[ -d "$pkg_src" ]]; then
            cp -r "$pkg_src" "${MIRROR_DIR}/packages/${pkg_dst_name}"
        else
            log "Warning: Wanted package '${pkg_name}' not found in submodule."
        fi
    done

    # Persistent Patching of Mirror Recipes to bypass auto-tool failures
    log "Hardening Mirror Recipes: GMP and MPFR..."
    sed -i "s/force_autoreconf = True/force_autoreconf = False/g" "${MIRROR_DIR}/packages/gmp/package.py"
    sed -i "s/depends_on(\"autoconf/#depends_on(\"autoconf/g" "${MIRROR_DIR}/packages/gmp/package.py"
    sed -i "s/depends_on(\"automake/#depends_on(\"automake/g" "${MIRROR_DIR}/packages/gmp/package.py"
    sed -i "s/depends_on(\"libtool/#depends_on(\"libtool/g" "${MIRROR_DIR}/packages/gmp/package.py"
    # m4 is required for configure
    
    sed -i "s/force_autoreconf = True/force_autoreconf = False/g" "${MIRROR_DIR}/packages/mpfr/package.py"
    sed -i "s/depends_on(\"autoconf/#depends_on(\"autoconf/g" "${MIRROR_DIR}/packages/mpfr/package.py"
    sed -i "s/depends_on(\"automake/#depends_on(\"automake/g" "${MIRROR_DIR}/packages/mpfr/package.py"
    sed -i "s/depends_on(\"libtool/#depends_on(\"libtool/g" "${MIRROR_DIR}/packages/mpfr/package.py"
    sed -i "s/depends_on(\"texinfo/#depends_on(\"texinfo/g" "${MIRROR_DIR}/packages/mpfr/package.py"

    spack repo add "$PWD" || true
    spack repo add "${MIRROR_DIR}" || true
    spack clean -m || true
}

write_env_yaml() {
    local BOOTSTRAP_MODE="${1:-0}"
    local ARCH_VAL="${SPACK_TARGET:-x86_64}"
    local ENV_DIR="${PWD}/envs/${ENV_NAME:-default}"
    local SHARED_VAL="~shared"
    local LIBS_VAL="libs=static"
    [[ "${BUILD_STATIC:-1}" == "0" ]] && { SHARED_VAL="+shared"; LIBS_VAL="libs=shared,static"; }

    local GCC_PATH=$(command -v gcc || echo "/usr/bin/gcc")
    local SYSTEM_VER_FULL=$("${GCC_PATH}" -dumpfullversion 2>/dev/null || "${GCC_PATH}" -dumpversion)

    local GMAKE_PATH=$(command -v gmake || echo "/usr/bin/gmake")
    local GMAKE_VER=$("${GMAKE_PATH}" --version | head -n 1 | awk '{print $NF}')
    local GMAKE_PREFIX=$(dirname $(dirname "${GMAKE_PATH}"))

    local DIFF_PATH=$(command -v diff || echo "/usr/bin/diff")
    local DIFF_VER=$("${DIFF_PATH}" --version | head -n 1 | awk '{print $NF}')
    local DIFF_PREFIX=$(dirname $(dirname "${DIFF_PATH}"))

    local PERL_PATH=$(command -v perl || echo "/usr/bin/perl")
    local PERL_VER=$("${PERL_PATH}" -e 'print $^V' | sed 's/v//')
    local PERL_PREFIX=$(dirname $(dirname "${PERL_PATH}"))

    local TAR_PATH=$(command -v tar || echo "/usr/bin/tar")
    local TAR_VER=$("${TAR_PATH}" --version | head -n 1 | awk '{print $NF}')
    local TAR_PREFIX=$(dirname $(dirname "${TAR_PATH}"))

    local XZ_PATH=$(command -v xz || echo "/usr/bin/xz")
    local XZ_VER=$("${XZ_PATH}" --version | head -n 1 | awk '{print $NF}')
    local XZ_PREFIX=$(dirname $(dirname "${XZ_PATH}"))

    local BZIP2_PATH=$(command -v bzip2 || echo "/usr/bin/bzip2")
    local BZIP2_VER=$("${BZIP2_PATH}" --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    local BZIP2_PREFIX=$(dirname $(dirname "${BZIP2_PATH}"))

    log "Updating Enclave Config: ${ENV_NAME:-default} via Template..."
    mkdir -p "${ENV_DIR}"
    log "Generating Enclave Config: ${ENV_DIR}/spack.yaml..."
    
    python3 <<EOF > "${ENV_DIR}/spack.yaml"
import json
config = {
    "spack": {
        "concretizer": {"unify": False},
        "view": True,
        "repos": ["${PWD}", "${MIRROR_DIR}"],
        "packages": {
            "all": {"require": ["target=${ARCH_VAL}"]} if not ${BOOTSTRAP_MODE} else {},
            "gcc": {"externals": [{"spec": "gcc@${SYSTEM_VER_FULL} languages=c,c++,fortran", "prefix": "/usr"}], "buildable": True if ${BOOTSTRAP_MODE} else False},
            "gmake": {"externals": [{"spec": "gmake@${GMAKE_VER}", "prefix": "${GMAKE_PREFIX}"}], "buildable": False},
            "diffutils": {"externals": [{"spec": "diffutils@${DIFF_VER}", "prefix": "${DIFF_PREFIX}"}], "buildable": False},
            "perl": {"externals": [{"spec": "perl@${PERL_VER}", "prefix": "${PERL_PREFIX}"}], "buildable": False},
            "tar": {"externals": [{"spec": "tar@${TAR_VER}", "prefix": "${TAR_PREFIX}"}], "buildable": False},
            "xz": {"externals": [{"spec": "xz@${XZ_VER}", "prefix": "${XZ_PREFIX}"}], "buildable": False},
            "bzip2": {"externals": [{"spec": "bzip2@${BZIP2_VER}", "prefix": "${BZIP2_PREFIX}"}], "buildable": False},
            "binutils": {"prefer": ["%gcc"]},
            "cmake": {"prefer": ["%gcc"]},
            "automake": {"require": ["@1.15.1"]},
            "autoconf": {"require": ["@2.69"]},
            "smoke": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "ioapi": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "netcdf-fortran": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "netcdf-c": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "hdf5": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "zlib": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "zlib-ng": {"require": ["target=${ARCH_VAL}", "${SHARED_VAL}"]},
            "gmp": {"require": ["target=${ARCH_VAL}", "${LIBS_VAL}"]},
            "mpfr": {"require": ["target=${ARCH_VAL}", "${LIBS_VAL}"]},
            "mpc": {"require": ["target=${ARCH_VAL}", "${LIBS_VAL}"]},
            "zstd": {"require": ["target=${ARCH_VAL}", "${LIBS_VAL}"]},
            "libiconv": {"require": ["target=${ARCH_VAL}", "${LIBS_VAL}"]}
        }
    }
}
print(json.dumps(config, indent=2))
EOF
}

bootstrap_gcc_base() {
    log "Enrolling System GCC into enclave foundation via auto-discovery..."
    
    GCC_PATH=$(command -v gcc || echo "/usr/bin/gcc")
    SYSTEM_VER_FULL=$("${GCC_PATH}" -dumpfullversion 2>/dev/null || "${GCC_PATH}" -dumpversion)
    
    spack compiler find
    spack external find gmake tar xz bzip2 perl diffutils
    
    log "Bootstrapping GCC 14 using system toolchain: %gcc@${SYSTEM_VER_FULL}..."
    spack install -j ${BUILD_JOBS} "gcc@14.3.0+piclibs %gcc@${SYSTEM_VER_FULL}" target=${SPACK_TARGET} < /dev/null
    
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
    
    # Register the production GCC
    spack compiler find "${SPACK_GCC_PATH}"
}

generate_final_config() {
    log "Finalizing AOCC toolchain enrolment via discovery..."
    AOCC_INFO=$(spack find --format "{prefix} {version}" aocc | head -n 1)
    AOCC_PATH=$(echo $AOCC_INFO | awk '{print $1}')
    
    # Discovery will pick up the one we just built
    spack compiler find "${AOCC_PATH}"
    
    # We still need write_env_yaml to set the package requirements
    write_env_yaml
}

# --- 3. Main Execution ---

BUILD_JOBS=$(get_safe_build_jobs)
setup_spack_and_repos
export PATH="$SPACK_ROOT/bin:$PATH"

if ! spack find gcc@14 >/dev/null 2>&1; then
    bootstrap_gcc_base
else
    log "GCC 14 foundation already presence. Reusing existing toolchain..."
fi

# Re-resolve paths if already installed
GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)

# Environment Initialization
export ENV_NAME="${ENV_NAME:-default}"
ENV_DIR="${PWD}/envs/${ENV_NAME}"
if [ ! -d "${ENV_DIR}" ]; then
    log "Creating new Spack Environment: ${ENV_NAME}..."
    spack env create -d "${ENV_DIR}"
fi
source "$SPACK_ROOT/share/spack/setup-env.sh"
spack env activate -d "${ENV_DIR}"

log "Purging hybrid foundation to ensure strictly static toolchain..."
spack uninstall -a -y --force gmp mpfr mpc zstd libiconv >/dev/null 2>&1 || true

log "Hydrating AOCC track..."
spack install --add -j ${BUILD_JOBS} aocc+license-agreed %gcc@${GCC_VER} < /dev/null

# Reflect on the AOCC installation to finalize config
AOCC_INFO=$(spack find --format "{prefix} {version}" aocc | head -n 1)
AOCC_VER=$(echo $AOCC_INFO | awk "{print \$2}")

TARGET_SPEC="aocc@${AOCC_VER}"
generate_final_config

if [[ "$COMPILER_SPEC" == smoke* ]]; then FULL_SPEC="$COMPILER_SPEC"; else FULL_SPEC="smoke@master %$TARGET_SPEC"; fi
log "Compiling SMOKE in environment ${ENV_NAME}: $FULL_SPEC target=${SPACK_TARGET:-x86_64}"
spack install --add --no-cache "$FULL_SPEC" target=${SPACK_TARGET:-x86_64} < /dev/null

CURRENT_SMOKE=$(spack location -i "$FULL_SPEC")
rm -f smoke-aocc && ln -s "$CURRENT_SMOKE" smoke-aocc
log "Done. Shortcut: ./smoke-aocc/bin"

