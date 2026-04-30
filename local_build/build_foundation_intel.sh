#!/bin/bash
# SMOKE Spack Deployment Engine - Intel oneAPI Foundation Builder
# Bootstraps the Intel oneAPI compiler using the GCC foundation.

set -euo pipefail

# --- 1. Argument Parsing & Defaults ---
MY_INSTALL_ROOT="${1:-$PWD/intel_latest}"
[[ "$MY_INSTALL_ROOT" != /* ]] && MY_INSTALL_ROOT="$PWD/$MY_INSTALL_ROOT"
INTEL_REQ_VER="${2:-2025.3.2}"

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

apply_intel_patches() {
    log "Applying toolchain decoupling patches to builtin repo..."
    log "Debug: Commencing Python-based package patching for toolchain decoupling..."
    (cd "$PACKAGES_ROOT" && git checkout repos/spack_repo/builtin/packages/intel_oneapi_compilers/package.py repos/spack_repo/builtin/packages/intel_oneapi_runtime/package.py 2>/dev/null || true)
    
    python3 -c '
import sys, re
for fpath in sys.argv[1:]:
    with open(fpath, "r") as f: content = f.read()
    content = content.replace("depends_on(\"gcc languages=c,c++\", type=\"run\")", "")
    content = content.replace("depends_on(\"gcc-runtime\", type=\"link\")", "")
    if "intel_oneapi_runtime" in fpath:
        content = content.replace("depends_on(\"intel-oneapi-compilers\", type=\"build\")", "depends_on(\"intel-oneapi-compilers@2025.3.2\", type=\"build\")")
    if "intel_oneapi_compilers" in fpath:
        marker = "versions = ["; s_idx = content.find(marker)
        if s_idx != -1:
            e_dict = content.find("\n    },", s_idx)
            if e_dict != -1:
                e_list = content.find("\n]", e_dict)
                if e_list != -1: content = content[:s_idx] + content[s_idx:e_dict+6] + "\n]" + content[e_list+2:]
        if "target = \"gcc = self.spec" not in content:
            old = "        gcc = self.spec[\"gcc\"].package\n        llvm_flags = [f\"--gcc-toolchain={gcc.prefix}\"]\n        classic_flags = [f\"-gcc-name={gcc.cc}\", f\"-gxx-name={gcc.cxx}\"]"
            new = "        try:\n            gcc = self.spec[\"gcc\"].package\n            llvm_flags = [f\"--gcc-toolchain={gcc.prefix}\"]\n            classic_flags = [f\"-gcc-name={gcc.cc}\", f\"-gxx-name={gcc.cxx}\"]\n        except:\n            llvm_flags = []; classic_flags = []"
            content = content.replace(old, new)
    with open(fpath, "w") as f: f.write(content)
' "${PACKAGES_ROOT}/repos/spack_repo/builtin/packages/intel_oneapi_compilers/package.py" \
  "${PACKAGES_ROOT}/repos/spack_repo/builtin/packages/intel_oneapi_runtime/package.py"
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
apply_intel_patches
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

log "Bootstrapping Intel oneAPI compiler..."
export TERM=dumb
log "Debug: Commencing massive compilation phase for Intel oneAPI. This process may take a significant amount of time depending on core count."
spack --no-color install -j ${BUILD_JOBS:-1} --reuse intel-oneapi-compilers@${INTEL_REQ_VER} < /dev/null
log "Debug: Intel oneAPI compilation phase completed successfully."

INTEL_INFO=$(spack find --format "{prefix} {version}" intel-oneapi-compilers@${INTEL_REQ_VER} | head -n 1)
export SPACK_INTEL_PATH=$(echo $INTEL_INFO | awk '{print $1}')
export ONEAPI_VER=$(echo $INTEL_INFO | awk '{print $2}')

CURRENT_INTEL="$SPACK_INTEL_PATH"
rm -f intel-latest && ln -s "$CURRENT_INTEL" intel-latest

log "Foundation Intel oneAPI build complete!"
log "Intel oneAPI $ONEAPI_VER is available at: $PWD/intel-latest"
