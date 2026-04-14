#!/bin/bash
# SMOKE Spack Deployment Engine
# CRITICAL: This script MUST maintain strict multi-platform support. 
# Never assume OS-specific paths, versions, or shell behaviors. 
# All logic must be portable and agnostic to specific Linux distributions.
# Usage: ./install.sh [COMPILER/SPEC] [/custom/install/path]

set -euo pipefail

# --- 1. Argument Parsing & Defaults ---
if [[ "${1:-}" == smoke* && "${2:-}" == %* ]]; then
    COMPILER_SPEC="$1 $2"
    MY_INSTALL_ROOT="${3:-$PWD/install}"
else
    COMPILER_SPEC="${1:-%gcc}"
    MY_INSTALL_ROOT="${2:-$PWD/install}"
fi

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

}

apply_intel_patches() {
    log "Applying toolchain decoupling patches to builtin repo..."
    (cd "$PACKAGES_ROOT" && git checkout repos/spack_repo/builtin/packages/intel_oneapi_compilers/package.py repos/spack_repo/builtin/packages/intel_oneapi_runtime/package.py)
    
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

init_spack_config() {
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
    require: ["target=${SPACK_TARGET:-x86_64}"]
    prefer: ["^gcc-runtime@14"]
  gcc: {require: "%gcc"}
  gcc-runtime: {require: "%gcc"}
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

setup_system_gcc() {
    log "Discovering System GCC base toolchain for current OS..."
    spack compiler find --scope site
    
    local gcc_bin
    gcc_bin=$(command -v gcc || true)
    if [[ -z "$gcc_bin" ]]; then
        log "Error: No GCC found on the system. Cannot proceed."
        exit 1
    fi
    
    SPACK_GCC_PATH=$(dirname $(dirname "$gcc_bin"))
    GCC_VER=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)
    SPACK_OS=$(spack arch -o)
    SPACK_TARGET="x86_64" # Enforce portability
    
    log "Found System GCC: ${GCC_VER} at ${SPACK_GCC_PATH}"
}

bootstrap_gcc_base() {
    log "Ensuring GCC 14 base toolchain..."
    spack compiler find --scope site
    
    local system_gcc=$(command -v gcc)
    local gcc_ver=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)
    local system_prefix=$(dirname $(dirname "$system_gcc"))
    
    log "Cleansing site configuration of package locks..."
    python3 -c '
import sys, yaml, os
spack_root = sys.argv[1]; prefix = sys.argv[2]; ver = sys.argv[3]
p = os.path.join(spack_root, "etc/spack/site/packages.yaml")
data = {}
if os.path.exists(p):
    try:
        with open(p, "r") as f: data = yaml.safe_load(f) or {}
    except: pass
if "packages" not in data: data["packages"] = {}
if "gcc" in data["packages"]: del data["packages"]["gcc"]
data["packages"]["gcc-runtime"] = {
    "externals": [{"spec": f"gcc-runtime@{ver}", "prefix": prefix}],
    "buildable": False
}
with open(p, "w") as f: yaml.dump(data, f)
' "$SPACK_ROOT" "$system_prefix" "$gcc_ver"

    # Ensure no remnant packages.yaml at root is blocking us
    rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
    
    log "Bootstrapping GCC 14..."
    export TERM=dumb
    spack --no-color install -j ${BUILD_JOBS:-1} gcc@14 languages=c,c++,fortran
    
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
    SPACK_OS=$(spack arch -o)
    SPACK_TARGET=$(spack arch -t)
}

generate_final_config() {
    local target_spec="$1"
    log "Finalizing toolchain lockdown for %$target_spec..."
    rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
    
    cat <<EOF > "$SPACK_ROOT/etc/spack/packages.yaml"
packages:
  all:
    require:
      - "target=x86_64"
EOF

    if [[ "$target_spec" == oneapi* ]]; then
        cat <<EOF >> "$SPACK_ROOT/etc/spack/packages.yaml"
    providers:
      fortran-rt: [intel-oneapi-runtime]
  intel-oneapi-compilers: {require: "@${ONEAPI_VER:-}"}
  intel-oneapi-runtime:   {require: "@${ONEAPI_VER:-}"}
  gcc:
    externals: [{spec: "gcc@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
  gcc-runtime:
    externals: [{spec: "gcc-runtime@${GCC_VER}", prefix: "${SPACK_GCC_PATH}"}]
    buildable: false
EOF
    elif [[ "$target_spec" != gcc* ]]; then
        cat <<EOF >> "$SPACK_ROOT/etc/spack/packages.yaml"
  gcc: {require: "%gcc@14"}
  gcc-runtime: {require: "%gcc@14"}
EOF
    fi

    cat <<EOF >> "$SPACK_ROOT/etc/spack/packages.yaml"
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
apply_intel_patches
if [[ "$COMPILER_SPEC" == *"%oneapi"* || "$COMPILER_SPEC" == *"%intel"* ]]; then
    setup_system_gcc
else
    bootstrap_gcc_base
fi

init_spack_config

log "Configuring public binary cache for dependents..."
spack mirror add spack-public https://binaries.spack.io/develop || true

if [[ "$COMPILER_SPEC" == *"%aocc"* ]]; then
    log "Hydrating AOCC track..."
    spack install -j ${BUILD_JOBS:-1} --reuse aocc+license-agreed %gcc@${GCC_VER}
    AOCC_INFO=$(spack find --format "{prefix} {version}" aocc | head -n 1)
    AOCC_PATH=$(echo $AOCC_INFO | awk "{print \$1}")
    AOCC_VER=$(echo $AOCC_INFO | awk "{print \$2}")
    
    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: aocc@${AOCC_VER}
    paths:
      cc: ${AOCC_PATH}/bin/clang
      cxx: ${AOCC_PATH}/bin/clang++
      f77: ${AOCC_PATH}/bin/flang
      fc: ${AOCC_PATH}/bin/flang
    flags:
      cflags: --gcc-toolchain=${SPACK_GCC_PATH}
      cxxflags: --gcc-toolchain=${SPACK_GCC_PATH} -Wl,-rpath,${SPACK_GCC_PATH}/lib64
      fflags: --gcc-toolchain=${SPACK_GCC_PATH}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
- compiler:
    spec: gcc@${GCC_VER}
    paths: {cc: ${SPACK_GCC_PATH}/bin/gcc, cxx: ${SPACK_GCC_PATH}/bin/g++, f77: ${SPACK_GCC_PATH}/bin/gfortran, fc: ${SPACK_GCC_PATH}/bin/gfortran}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
EOF
    TARGET_SPEC="aocc@${AOCC_VER}"

elif [[ "$COMPILER_SPEC" == *"%oneapi"* || "$COMPILER_SPEC" == *"%intel"* ]]; then
    log "Hydrating Intel oneAPI track..."
    spack install -j ${BUILD_JOBS:-1} --reuse intel-oneapi-compilers@2025.3.2
    INTEL_INFO=$(spack find --format "{prefix} {version}" intel-oneapi-compilers@2025.3.2 | head -n 1)
    INTEL_ROOT=$(echo $INTEL_INFO | awk "{print \$1}")
    ONEAPI_VER=$(echo $INTEL_INFO | awk "{print \$2}")
    INTEL_BIN_DIR=$(find "$INTEL_ROOT" -name icx -exec dirname {} + | head -n 1)

    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: oneapi@${ONEAPI_VER}
    paths: {cc: ${INTEL_BIN_DIR}/icx, cxx: ${INTEL_BIN_DIR}/icpx, f77: ${INTEL_BIN_DIR}/ifx, fc: ${INTEL_BIN_DIR}/ifx}
    flags: {cflags: --gcc-toolchain=${SPACK_GCC_PATH}, cxxflags: --gcc-toolchain=${SPACK_GCC_PATH}, fflags: --gcc-toolchain=${SPACK_GCC_PATH}}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
- compiler:
    spec: gcc@${GCC_VER}
    paths: {cc: ${SPACK_GCC_PATH}/bin/gcc, cxx: ${SPACK_GCC_PATH}/bin/g++, f77: ${SPACK_GCC_PATH}/bin/gfortran, fc: ${SPACK_GCC_PATH}/bin/gfortran}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
EOF
    TARGET_SPEC="oneapi@${ONEAPI_VER}"

else
    log "Using modern GCC track..."
    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: gcc@${GCC_VER}
    paths: {cc: ${SPACK_GCC_PATH}/bin/gcc, cxx: ${SPACK_GCC_PATH}/bin/g++, f77: ${SPACK_GCC_PATH}/bin/gfortran, fc: ${SPACK_GCC_PATH}/bin/gfortran}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
EOF
    if [[ "$COMPILER_SPEC" == *"%"* ]]; then TARGET_SPEC=$(echo "$COMPILER_SPEC" | sed 's/.*%//'); else TARGET_SPEC="gcc@${GCC_VER}"; fi
fi

generate_final_config "$TARGET_SPEC"

# --- 4. Final Installation ---
if [[ "$COMPILER_SPEC" == smoke* ]]; then FULL_SPEC="$COMPILER_SPEC"; else FULL_SPEC="smoke@master %$TARGET_SPEC"; fi
log "Compiling SMOKE natively: $FULL_SPEC"
spack install --no-cache "$FULL_SPEC"

CURRENT_SMOKE=$(spack location -i "$FULL_SPEC")
rm -f smoke-latest && ln -s "$CURRENT_SMOKE" smoke-latest
log "Compilation complete! Shortcut: ./smoke-latest/bin"
