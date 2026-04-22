#!/bin/bash
# SMOKE Spack Deployment Engine - Intel oneAPI
# Dedicated track for Intel Toolchain hydration and SMOKE compilation.

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
    MY_INSTALL_ROOT="${3:-$PWD/install_intel}"
else
    COMPILER_SPEC="${1:-%gcc}"
    MY_INSTALL_ROOT="${2:-$PWD/install_intel}"
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

log() { echo "==> [INTEL] $1"; }

get_safe_build_jobs() {
    local jobs=$(awk '/MemAvailable/ {printf "%.0f", $2 / 1024 / 1024 / 2}' /proc/meminfo 2>/dev/null)
    local cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    [[ -z "$jobs" ]] && jobs=2
    [[ $jobs -lt 1 ]] && jobs=1
    [[ $jobs -gt $cores ]] && jobs=$cores
    echo $jobs
}

setup_spack_and_repos() {
    if [ ! -d "spack" ]; then
        log "Downloading Spack ${SPACK_VERSION}..."
        git clone -b "${SPACK_VERSION}" --depth 1 https://github.com/spack/spack.git
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

    spack repo add "${PACKAGES_ROOT}/repos/spack_repo/builtin" || true
    spack repo add "$PWD" || true
    spack mirror list | grep -v "==>" | awk "{print \$1}" | xargs -I {} spack mirror remove {} || true
    spack clean -m || true
}

apply_intel_patches() {
    log "Applying toolchain decoupling patches to intel-oneapi @${SMK_INTEL_VER}..."
    export SMK_PKG_ROOT="${PACKAGES_ROOT}/repos/spack_repo/builtin/packages"
    spack python <<'EOF'
import os, re
root = os.environ['SMK_PKG_ROOT']
target_ver = os.environ['SMK_INTEL_VER']
paths = [
    os.path.join(root, "intel_oneapi_compilers/package.py"),
    os.path.join(root, "intel_oneapi_runtime/package.py")
]
for fpath in paths:
    with open(fpath, "r") as f: content = f.read()
    content = content.replace("depends_on(\"gcc languages=c,c++\", type=\"run\")", "")
    content = content.replace("depends_on(\"gcc-runtime\", type=\"link\")", "")
    if "intel_oneapi_runtime" in fpath:
        content = content.replace("depends_on(\"intel-oneapi-compilers\", type=\"build\")", f"depends_on(\"intel-oneapi-compilers@{target_ver}\", type=\"build\")")
    if "intel_oneapi_compilers" in fpath:
        old = "        gcc = self.spec[\"gcc\"].package\n        llvm_flags = [f\"--gcc-toolchain={gcc.prefix}\"]\n        classic_flags = [f\"-gcc-name={gcc.cc}\", f\"-gxx-name={gcc.cxx}\"]"
        new = "        try:\n            gcc = self.spec[\"gcc\"].package\n            llvm_flags = [f\"--gcc-toolchain={gcc.prefix}\"]\n            classic_flags = [f\"-gcc-name={gcc.cc}\", f\"-gxx-name={gcc.cxx}\"]\n        except:\n            llvm_flags = []; classic_flags = []"
        content = content.replace(old, new)
    with open(fpath, "w") as f: f.write(content)
EOF
}

init_spack_config() {
    local STATIC_SPEC="variants: [+shared, ~static]"
    [[ "$BUILD_STATIC" == "1" ]] && STATIC_SPEC="variants: [~shared, +static]"
    
    cat <<EOF > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: ${BUILD_JOBS}
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
EOF

    cat <<EOF > "$SPACK_ROOT/etc/spack/packages.yaml"
packages:
  all:
    ${STATIC_SPEC}
    require: ["target=${SPACK_TARGET}"]
EOF
write_env_yaml() {
    local ARCH_VAL="${SPACK_TARGET:-x86_64}"
    local ENV_DIR="${PWD}/envs/${ENV_NAME:-default}"
    local COMPILER_YAML="${1:-}"
    local SHARED_VAL="~shared"
    local LIBS_VAL="libs=static"
    [[ "${BUILD_STATIC:-1}" == "0" ]] && { SHARED_VAL="+shared"; LIBS_VAL="libs=shared,static"; }
    
    local STATIC_REQ="\"target=${ARCH_VAL}\",\"${SHARED_VAL}\""
    local LIBS_REQ="\"target=${ARCH_VAL}\",\"${LIBS_VAL}\""

    log "Updating Enclave Config: ${ENV_NAME:-default}..."
    mkdir -p "${ENV_DIR}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
  concretizer:
    unify: true
  packages:
    all:
      require: ["target=${ARCH_VAL}"]
    intel-oneapi-compilers: {require: "@${ONEAPI_VER:-}"}
    intel-oneapi-runtime:   {require: "@${ONEAPI_VER:-}"}
    providers: {fortran-rt: [intel-oneapi-runtime]}
    binutils: {prefer: ["%gcc"]}
    gmake: {prefer: ["%gcc"]}
    pkgconf: {prefer: ["%gcc"]}
    ncurses: {prefer: ["%gcc"]}
    curl: {prefer: ["%gcc"]}
    cmake: {prefer: ["%gcc"]}
    smoke: {require: [$STATIC_REQ]}
    ioapi: {require: [$STATIC_REQ]}
    netcdf-fortran: {require: [$STATIC_REQ]}
    netcdf-c: {require: [$STATIC_REQ]}
    hdf5: {require: [$STATIC_REQ]}
    zlib: {require: [$STATIC_REQ]}
    zlib-ng: {require: [$STATIC_REQ]}
    gmp: {require: [$LIBS_REQ]}
    mpfr: {require: [$LIBS_REQ]}
    mpc: {require: [$LIBS_REQ]}
    zstd: {require: [$LIBS_REQ]}
    libiconv: {require: [$LIBS_REQ]}
  compilers:
$(echo "$COMPILER_YAML" | sed 's/^/  /')
  view: true
EOF
}

bootstrap_gcc_base() {
    log "Enrolling System GCC into enclave foundation via auto-discovery..."
    
    GCC_PATH=$(command -v gcc || echo "/usr/bin/gcc")
    SYSTEM_VER_FULL=$("${GCC_PATH}" -dumpfullversion 2>/dev/null || "${GCC_PATH}" -dumpversion)
    SPACK_OS=$(spack arch -o)
    
    spack compiler find
    spack external find gmake tar xz bzip2 perl diffutils
    
    log "Bootstrapping GCC 14 using system toolchain: %gcc@${SYSTEM_VER_FULL}..."
    spack install -j ${BUILD_JOBS} "gcc@14.3.0+piclibs %gcc@${SYSTEM_VER_FULL}" target=${SPACK_TARGET} < /dev/null
    
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
    
    # Register the production GCC
    spack compiler find "${SPACK_GCC_PATH}"
}

lock_gcc_foundation() {
    log "Locking foundational toolchain..."
    cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require: ["target=${SPACK_TARGET:-x86_64}"]
  gcc:
    externals: [{spec: "gcc@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
  gcc-runtime:
    externals: [{spec: "gcc-runtime@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
EOF
}

generate_final_config() {
    local target_spec="$1"
    local ARCH_VAL="${SPACK_TARGET:-x86_64}"
    local SHARED_VAL="~shared"
    local LIBS_VAL="libs=static"
    [[ "${BUILD_STATIC:-1}" == "0" ]] && { SHARED_VAL="+shared"; LIBS_VAL="libs=shared,static"; }
    
    local STATIC_REQ="\"target=${ARCH_VAL}\",\"${SHARED_VAL}\""
    local LIBS_REQ="\"target=${ARCH_VAL}\",\"${LIBS_VAL}\""
    local ENV_DIR="${PWD}/envs/${ENV_NAME:-default}"

    log "Generating Isolated Spack Environment: ${ENV_NAME:-default}..."
    mkdir -p "${ENV_DIR}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
  concretizer:
    unify: true
  packages:
    all:
      require: ["target=${ARCH_VAL}"]
    intel-oneapi-compilers: {require: "@${ONEAPI_VER:-}"}
    intel-oneapi-runtime:   {require: "@${ONEAPI_VER:-}"}
    providers: {fortran-rt: [intel-oneapi-runtime]}
    binutils: {prefer: ["%gcc"]}
    gmake: {prefer: ["%gcc"]}
    pkgconf: {prefer: ["%gcc"]}
    ncurses: {prefer: ["%gcc"]}
    curl: {prefer: ["%gcc"]}
    cmake: {prefer: ["%gcc"]}
    smoke: {require: [$STATIC_REQ, "%${target_spec}"]}
    ioapi: {require: [$STATIC_REQ, "%${target_spec}"]}
    netcdf-fortran: {require: [$STATIC_REQ, "%${target_spec}"]}
    netcdf-c: {require: [$STATIC_REQ, "%${target_spec}"]}
    hdf5: {require: [$STATIC_REQ, "%${target_spec}"]}
    zlib: {require: [$STATIC_REQ]}
    zlib-ng: {require: [$STATIC_REQ]}
    gmp: {require: [$LIBS_REQ]}
    mpfr: {require: [$LIBS_REQ]}
    mpc: {require: [$LIBS_REQ]}
    zstd: {require: [$LIBS_REQ]}
    libiconv: {require: [$LIBS_REQ]}
  view: true
EOF
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
SPACK_OS=$(spack arch -o)

lock_gcc_foundation

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
spack uninstall -a -y --force gmp mpfr mpc zstd libiconv || true

log "Resolving Intel oneAPI Track versions..."
INTEL_REQ_VER=$(echo "$COMPILER_SPEC" | sed -n 's/.*%[a-z0-9\-]*@\([^ ]*\).*/\1/p')
if [ -z "$INTEL_REQ_VER" ]; then
    log "No specific version requested. Querying Spack for latest stable release..."
    INTEL_REQ_VER=$(spack info intel-oneapi-compilers | awk '/Safe versions:/ {print $3}' | tr -d ',')
fi
export SMK_INTEL_VER="$INTEL_REQ_VER"

apply_intel_patches

log "Hydrating Intel oneAPI @${SMK_INTEL_VER}..."
spack install --add -j ${BUILD_JOBS} --reuse intel-oneapi-compilers@${SMK_INTEL_VER} < /dev/null
INTEL_INFO=$(spack find --format "{prefix} {version}" intel-oneapi-compilers@${SMK_INTEL_VER} | head -n 1)
INTEL_ROOT=$(echo $INTEL_INFO | awk "{print \$1}")
ONEAPI_VER=$(echo $INTEL_INFO | awk "{print \$2}")
INTEL_BIN_DIR=$(find "$INTEL_ROOT" -name icx -exec dirname {} + | head -n 1)

log "Hard-coding Intel compiler schema..."
cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: oneapi@${ONEAPI_VER}
    paths: {cc: ${INTEL_BIN_DIR}/icx, cxx: ${INTEL_BIN_DIR}/icpx, f77: ${INTEL_BIN_DIR}/ifx, fc: ${INTEL_BIN_DIR}/ifx}
    flags: 
      cflags: --gcc-toolchain=${SPACK_GCC_PATH} -L${SPACK_GCC_PATH}/lib64 -L${SPACK_GCC_PATH}/lib/gcc/x86_64-pc-linux-gnu/${GCC_VER} -Wl,-rpath,${SPACK_GCC_PATH}/lib64
      cxxflags: --gcc-toolchain=${SPACK_GCC_PATH} -L${SPACK_GCC_PATH}/lib64 -L${SPACK_GCC_PATH}/lib/gcc/x86_64-pc-linux-gnu/${GCC_VER} -Wl,-rpath,${SPACK_GCC_PATH}/lib64
      fflags: --gcc-toolchain=${SPACK_GCC_PATH} -L${SPACK_GCC_PATH}/lib64 -L${SPACK_GCC_PATH}/lib/gcc/x86_64-pc-linux-gnu/${GCC_VER} -Wl,-rpath,${SPACK_GCC_PATH}/lib64
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF

TARGET_SPEC="oneapi@${ONEAPI_VER}"
generate_final_config "$TARGET_SPEC"

if [[ "$COMPILER_SPEC" == smoke* ]]; then FULL_SPEC="$COMPILER_SPEC"; else FULL_SPEC="smoke@master %$TARGET_SPEC"; fi
log "Compiling SMOKE in environment ${ENV_NAME}: $FULL_SPEC target=${SPACK_TARGET:-x86_64}"
spack install --add --no-cache "$FULL_SPEC" target=${SPACK_TARGET:-x86_64} < /dev/null

CURRENT_SMOKE=$(spack location -i "$FULL_SPEC")
rm -f smoke-intel && ln -s "$CURRENT_SMOKE" smoke-intel
log "Done. Shortcut: ./smoke-intel/bin"
