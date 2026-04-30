#!/bin/bash
# SMOKE Spack Deployment Engine - GCC Foundation Builder
# Bootstraps GCC 14 and exports it as a shareable Spack buildcache.

set -euo pipefail

# --- 1. Argument Parsing & Defaults ---
MY_INSTALL_ROOT="${1:-$PWD/gcc_14}"
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

    spack repo add --scope site "${PACKAGES_ROOT}/repos/spack_repo/builtin" || true
    spack repo add --scope site "$PWD" || true

    log "Sanitizing mirror configuration..."
    for m in $(spack mirror list | grep -v "==>" | awk "{print \$1}"); do
        spack mirror remove "$m" || true
    done
    spack clean -m || true
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

bootstrap_gcc_base() {
    log "Ensuring GCC 14 base toolchain..."
    spack compiler find --scope site
    
    local system_gcc=$(command -v gcc || true)
    local gcc_ver=""
    local system_prefix=""
    if [[ -n "$system_gcc" ]]; then
        gcc_ver=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)
        system_prefix=$(dirname $(dirname "$system_gcc"))
    
        log "Cleansing site configuration of package locks..."
        python3 -c "
import sys, yaml, os
spack_root = sys.argv[1]; prefix = sys.argv[2]; ver = sys.argv[3]
p = os.path.join(spack_root, 'etc/spack/site/packages.yaml')
data = {'packages': {}}
if os.path.exists(p):
    try:
        with open(p, 'r') as f: data = yaml.safe_load(f) or {'packages': {}}
    except: pass
if 'packages' not in data: data['packages'] = {}
data['packages']['gcc-runtime'] = {
    'externals': [{'spec': f'gcc-runtime@{ver}', 'prefix': prefix}],
    'buildable': False
}
with open(p, 'w') as f: yaml.dump(data, f)
" "$SPACK_ROOT" "$system_prefix" "$gcc_ver"
    fi

    log "Debug: Purging old packages.yaml..."
    rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
    
    log "Bootstrapping GCC 14..."
    export TERM=dumb
    log "Debug: Commencing massive compilation phase for GCC 14. This process may take a significant amount of time depending on core count."
    spack --no-color install -j ${BUILD_JOBS:-1} gcc@14 languages=c,c++,fortran < /dev/null
    log "Debug: GCC 14 compilation phase completed successfully."
    
    export SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    export GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
}

# --- 3. Main Logic Execution ---

BUILD_JOBS=$(get_safe_build_jobs)
log "Dynamic job scaling: Set to ${BUILD_JOBS} parallel threads based on available memory."

setup_spack_and_repos
log "Debug: Spack setup completed successfully."
init_spack_config
export PATH="$SPACK_ROOT/bin:$PATH"

log "Detecting native system architecture..."
export SPACK_TARGET=$(spack arch -t)
export SPACK_OS=$(spack arch -o)
log "Target: ${SPACK_TARGET} | OS: ${SPACK_OS}"

# Deterministic Toolchain Discovery
if spack find gcc@14 >/dev/null 2>&1; then
    log "Found indigenous GCC 14 foundation. Locking paths..."
    export SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    export GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
else
    bootstrap_gcc_base
fi

# Formally register the bootstrap compiler so Spack can use it natively
spack compiler find --scope site "$SPACK_GCC_PATH" || true

CURRENT_GCC="$SPACK_GCC_PATH"
rm -f gcc-latest && ln -s "$CURRENT_GCC" gcc-latest
log "Foundation GCC build complete!"
log "GCC 14 is available at: $PWD/gcc-latest"
