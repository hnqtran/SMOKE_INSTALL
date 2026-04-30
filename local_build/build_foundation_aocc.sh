#!/bin/bash
# SMOKE Spack Deployment Engine - AOCC Foundation Builder
# Bootstraps the AOCC compiler using the GCC foundation.

set -euo pipefail

# --- 1. Argument Parsing & Defaults ---
MY_INSTALL_ROOT="${1:-$PWD/aocc_compiler_set}"
[[ "$MY_INSTALL_ROOT" != /* ]] && MY_INSTALL_ROOT="$PWD/$MY_INSTALL_ROOT"

export SPACK_ROOT="$PWD/spack"
PACKAGES_ROOT="${PWD}/spack-packages"

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
    log "Debug: Site configuration wiped."

    spack repo add --scope site "${PACKAGES_ROOT}/repos/spack_repo/builtin" || true
    spack repo add --scope site "$PWD" || true

    log "Sanitizing mirror configuration..."
    for m in $(spack mirror list | grep -v "==>" | awk "{print \$1}"); do
        spack mirror remove "$m" || true
    done
    spack clean -m || true
    log "Debug: Repositories and mirrors sanitized."
}

init_spack_config() {
    log "Configuring foundation install path..."
    mkdir -p "$SPACK_ROOT/etc/spack"
    log "Debug: Generating config.yaml at $SPACK_ROOT/etc/spack/config.yaml..."
    cat <<EOF > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
EOF
}

# --- 3. Main Logic Execution ---

BUILD_JOBS=$(get_safe_build_jobs)
log "Dynamic job scaling: Set to ${BUILD_JOBS} parallel threads based on available memory."

log "Locating required foundation GCC 14..."
if [[ -L "$PWD/gcc-latest" && -d "$PWD/gcc-latest" ]]; then
    export SPACK_GCC_PATH=$(readlink -f "$PWD/gcc-latest")
else
    # Fallback to guessing the gcc_14 directory
    GCC_INSTALL_DIR=$(find "$PWD/gcc_14" -maxdepth 3 -name "gcc-14*" -type d -print -quit 2>/dev/null || true)
    if [[ -n "$GCC_INSTALL_DIR" ]]; then
        export SPACK_GCC_PATH="$GCC_INSTALL_DIR"
    else
        log "Error: Failed to find base GCC 14 at $PWD/gcc-latest or $PWD/gcc_14. You MUST run build_foundation_gcc.sh first!"
        exit 1
    fi
fi

# Detect actual GCC version from binary
export GCC_VER=$("$SPACK_GCC_PATH/bin/gcc" -dumpfullversion 2>/dev/null || "$SPACK_GCC_PATH/bin/gcc" -dumpversion)
log "Found GCC $GCC_VER at $SPACK_GCC_PATH"

setup_spack_and_repos
log "Debug: Spack setup completed successfully."
init_spack_config
export PATH="$SPACK_ROOT/bin:$PATH"

log "Detecting native system architecture..."
export SPACK_TARGET=$(spack arch -t)
export SPACK_OS=$(spack arch -o)
log "Target: ${SPACK_TARGET} | OS: ${SPACK_OS}"

log "Registering foundation GCC..."
mkdir -p "$SPACK_ROOT/etc/spack"
log "Debug: Registering foundation GCC as internal compiler..."
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

log "Debug: Purging old packages.yaml..."
rm -f "$SPACK_ROOT/etc/spack/packages.yaml"

log "Locking foundational GCC 14 external..."
log "Debug: Finalizing external package lockdown for GCC..."
cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require:
      - "target=${SPACK_TARGET}"
  gcc:
    externals: [{spec: "gcc@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
EOF

log "Bootstrapping AOCC compiler..."
export TERM=dumb
log "Debug: Commencing massive compilation phase for AOCC. This process may take a significant amount of time depending on core count."
spack --no-color install -j ${BUILD_JOBS:-1} aocc+license-agreed %gcc@${GCC_VER} < /dev/null
log "Debug: AOCC compilation phase completed successfully."

AOCC_INFO=$(spack find --format "{prefix} {version}" aocc | head -n 1)
export SPACK_AOCC_PATH=$(echo $AOCC_INFO | awk '{print $1}')
export AOCC_VER=$(echo $AOCC_INFO | awk '{print $2}')

CURRENT_AOCC="$SPACK_AOCC_PATH"
rm -f aocc-latest && ln -s "$CURRENT_AOCC" aocc-latest

log "Foundation AOCC build complete!"
log "AOCC $AOCC_VER is available at: $PWD/aocc-latest"
