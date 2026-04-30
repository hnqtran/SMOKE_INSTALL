#!/bin/bash
# SMOKE Spack Deployment Engine
# CRITICAL: This script MUST maintain strict multi-platform support. 
# Never assume OS-specific paths, versions, or shell behaviors. 
# All logic must be portable and agnostic to specific Linux distributions.
# Usage: ./install.sh [COMPILER/SPEC] [/custom/install/path]

set -euo pipefail

# --- 1. Argument Parsing & Defaults ---
COMPILER_SPEC="%gcc"
MY_INSTALL_ROOT="${1:-$PWD/install_gcc}"
[[ "$MY_INSTALL_ROOT" != /* ]] && MY_INSTALL_ROOT="$PWD/$MY_INSTALL_ROOT"

export SPACK_ROOT="$PWD/spack"
PACKAGES_ROOT="${PWD}/spack-packages"
BUILD_STATIC="${BUILD_STATIC:-0}"

# --- 2. Helper Functions ---

log() { echo "==> $1"; }

get_safe_build_jobs() {
    local jobs=$(awk '/MemAvailable/ {printf "%.0f", $2 / 1024 / 1024 / 2}' /proc/meminfo 2>/dev/null)
    local cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    
    [[ -z "$jobs" ]] && jobs=2
    [[ $jobs -lt 1 ]] && jobs=1
    [[ $jobs -gt $cores ]] && jobs=$cores
    log "Debug: Calculated jobs=$jobs (Cores: $cores)" >&2
    echo $jobs
}

setup_spack_and_repos() {
    if [ ! -d "spack" ]; then
        log "Downloading Spack v1.1.1..."
        git clone -b v1.1.1 --depth 1 https://github.com/spack/spack.git
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

    spack repo add --scope site "${PACKAGES_ROOT}/repos/spack_repo/builtin" || true
    spack repo add --scope site "$PWD" || true

    log "Sanitizing mirror configuration..."
    for m in $(spack mirror list | grep -v "==>" | awk "{print \$1}"); do
        spack mirror remove "$m" || true
    done
    spack clean -m || true
}



init_spack_config() {
    local STATIC_SPEC="variants: [+shared, ~static]"
    if [[ "$BUILD_STATIC" == "1" ]]; then
        log "Enforcing strictly static toolchain (portable mode)..."
        STATIC_SPEC="variants: [~shared, +static]"
    fi

    log "Debug: Generating config.yaml at $SPACK_ROOT/etc/spack/config.yaml..."
    cat <<EOF > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: ${BUILD_JOBS}
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
EOF

    log "Debug: Generating base packages.yaml at $SPACK_ROOT/etc/spack/packages.yaml..."
    cat <<EOF > "$SPACK_ROOT/etc/spack/packages.yaml"
packages:
  all:
    ${STATIC_SPEC}
    require: ["target=${SPACK_TARGET:-x86_64}"]
    prefer: ["^gcc-runtime@14"]
  binutils: {require: "%gcc"}
  gmake: {require: "%gcc"}
  pkgconf: {require: "%gcc"}
  m4: {require: "%gcc"}
  autoconf: {require: "%gcc"}
  automake: {require: "%gcc"}
  libtool: {require: "%gcc"}
  findutils: {require: "%gcc"}
  texinfo: {require: "%gcc"}
  diffutils: {require: "%gcc"}
  sed: {require: "%gcc"}
  libiconv: {require: "%gcc"}
  xz: {require: "%gcc"}
  zstd: {require: "%gcc"}
  berkeley-db: {require: "%gcc"}
  ncurses: {require: "%gcc"}
  perl: {require: "%gcc"}
  openssl: {require: "%gcc"}
  curl: {require: "%gcc"}
  cmake: {require: "%gcc"}
  ninja: {require: "%gcc"}
EOF
}



# Foundation GCC is now built by build_foundation_gcc.sh

lock_gcc_foundation() {
    log "Locking foundational GCC 14 toolchain..."
    mkdir -p "$SPACK_ROOT/etc/spack"
    cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require:
      - "target=${SPACK_TARGET}"
  gcc:
    externals: [{spec: "gcc@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
  gcc-runtime:
    externals: [{spec: "gcc-runtime@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
EOF
}

generate_final_config() {
    local target_spec="$1"
    log "Finalizing toolchain lockdown for %$target_spec..."
    
    local STATIC_SPEC="variants: [+shared, ~static]"
    if [[ "$BUILD_STATIC" == "1" ]]; then
        STATIC_SPEC="variants: [~shared, +static]"
    fi

    # Formally register the bootstrap compiler so Spack can use it natively
    spack compiler find --scope site "$SPACK_GCC_PATH" || true

    log "Debug: Purging old packages.yaml..."
    rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
    
    log "Debug: Generating final strict dependency map..."
    cat <<EOF > "$SPACK_ROOT/etc/spack/packages.yaml"
packages:
  all:
    ${STATIC_SPEC}
    require:
      - "target=${SPACK_TARGET}"
  gcc:
    externals: [{spec: "gcc@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
  gcc-runtime:
    externals: [{spec: "gcc-runtime@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
  binutils: {prefer: ["%gcc"]}
  gmake: {prefer: ["%gcc"]}
  pkgconf: {prefer: ["%gcc"]}
  m4: {prefer: ["%gcc"]}
  autoconf: {prefer: ["%gcc"]}
  automake: {prefer: ["%gcc"]}
  libtool: {prefer: ["%gcc"]}
  findutils: {prefer: ["%gcc"]}
  texinfo: {prefer: ["%gcc"]}
  diffutils: {prefer: ["%gcc"]}
  sed: {prefer: ["%gcc"]}
  libiconv: {prefer: ["%gcc"]}
  xz: {prefer: ["%gcc"]}
  zstd: {prefer: ["%gcc"]}
  berkeley-db: {prefer: ["%gcc"]}
  ncurses: {prefer: ["%gcc"]}
  perl: {prefer: ["%gcc"]}
  openssl: {prefer: ["%gcc"]}
  curl: {prefer: ["%gcc"]}
  cmake: {prefer: ["%gcc"]}
  ninja: {prefer: ["%gcc"]}
  smoke: {require: "%${target_spec}"}
  ioapi: {require: "%${target_spec}"}
  netcdf-fortran: {require: "%${target_spec}"}
  netcdf-c: {require: "%${target_spec}"}
  hdf5: {require: "%${target_spec}"}
EOF
}

# --- 3. Main Logic Execution ---

BUILD_JOBS=$(get_safe_build_jobs)
log "Dynamic job scaling: Set to ${BUILD_JOBS} parallel threads based on available memory."

setup_spack_and_repos
log "Debug: Spack setup completed successfully."
export PATH="$SPACK_ROOT/bin:$PATH"

log "Detecting native system architecture..."
export SPACK_TARGET=$(spack arch -t)
export SPACK_OS=$(spack arch -o)
log "Target: ${SPACK_TARGET} | OS: ${SPACK_OS}"

# Locate foundation GCC from local build
log "Locating foundation GCC 14..."
if [[ -L "$PWD/gcc-latest" && -d "$PWD/gcc-latest" ]]; then
    export SPACK_GCC_PATH=$(readlink -f "$PWD/gcc-latest")
else
    # Fallback to guessing the gcc_14 directory
    GCC_INSTALL_DIR=$(find "$PWD/gcc_14" -maxdepth 3 -name "gcc-14*" -type d -print -quit 2>/dev/null || true)
    if [[ -n "$GCC_INSTALL_DIR" ]]; then
        export SPACK_GCC_PATH="$GCC_INSTALL_DIR"
    else
        log "Error: Failed to find GCC 14 at $PWD/gcc-latest or $PWD/gcc_14. Did you run build_foundation_gcc.sh first?"
        exit 1
    fi
fi

# Detect actual GCC version from binary
export GCC_VER=$("$SPACK_GCC_PATH/bin/gcc" -dumpfullversion 2>/dev/null || "$SPACK_GCC_PATH/bin/gcc" -dumpversion)

log "Found GCC 14 foundation. Locking paths..."
# Surgical Registration: Tell Spack about this compiler IMMEDIATELY
mkdir -p "$SPACK_ROOT/etc/spack"
cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: gcc@${GCC_VER}
    paths:
      cc: ${SPACK_GCC_PATH}/bin/gcc
      cxx: ${SPACK_GCC_PATH}/bin/g++
      f77: ${SPACK_GCC_PATH}/bin/gfortran
      fc: ${SPACK_GCC_PATH}/bin/gfortran
    flags: {}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF

init_spack_config

log "Using modern GCC track..."
cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: gcc@${GCC_VER}
    paths: {cc: ${SPACK_GCC_PATH}/bin/gcc, cxx: ${SPACK_GCC_PATH}/bin/g++, f77: ${SPACK_GCC_PATH}/bin/gfortran, fc: ${SPACK_GCC_PATH}/bin/gfortran}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
EOF
TARGET_SPEC="gcc@${GCC_VER}"

generate_final_config "$TARGET_SPEC"

# --- 4. Final Installation ---
if [[ "$COMPILER_SPEC" == smoke* ]]; then FULL_SPEC="$COMPILER_SPEC"; else FULL_SPEC="smoke@master %$TARGET_SPEC"; fi
log "Compiling SMOKE natively: $FULL_SPEC"
log "Debug: Commencing massive compilation phase. This process may take a significant amount of time depending on core count."
spack install --no-cache "$FULL_SPEC" < /dev/null
log "Debug: Compilation phase completed successfully."

CURRENT_SMOKE=$(spack location -i "$FULL_SPEC")
rm -f smoke-latest && ln -s "$CURRENT_SMOKE" smoke-latest
log "Compilation complete! Shortcut: ./smoke-latest/bin"
