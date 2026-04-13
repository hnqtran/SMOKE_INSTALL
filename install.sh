#!/bin/bash
# Usage: ./install.sh [COMPILER/SPEC] [/custom/install/path]
#
# Examples:
#   ./install.sh %aocc                      (Installs latest master with AOCC)
#   ./install.sh "smoke@5.2.1 %oneapi"      (Installs release 5.2.1 with Intel)
#   ./install.sh %gcc /home/user/smoke_bin  (Installs to custom location)

# Set default values if arguments are missing
# Smarter argument parsing to handle separate spec and compiler (e.g. smoke@5.2 %aocc)
if [[ "$1" == smoke* && "$2" == %* ]]; then
    COMPILER="$1 $2"
    MY_INSTALL_ROOT="${3:-$PWD/install}"
else
    COMPILER="${1:-%gcc}"
    MY_INSTALL_ROOT="${2:-$PWD/install}"
fi

# Stop on any error
set -e

echo "==> Preparing Spack for SMOKE Compilation with $COMPILER at $MY_INSTALL_ROOT"

# 1. Clone Spack locally if it doesn't exist on this machine
# PINNED to v1.1.1 as requested
if [ ! -d "spack" ]; then
    echo "==> Downloading Spack v1.1.1..."
    git clone -b v1.1.1 --depth 1 https://github.com/spack/spack.git
fi

# 2. PROVISION PACKAGES (Required for v1.x unbundled architecture)
PACKAGES_ROOT="${PWD}/spack-packages"
if [[ ! -d "$PACKAGES_ROOT" ]]; then
    echo "==> Spack packages missing. Cloning core repository..."
    git clone --depth 1 https://github.com/spack/spack-packages.git "$PACKAGES_ROOT"
fi

# 5.1 Surgical Provisioning Patches (Permanent fix for Spack v1.1.1 circularity)
# These patches break the hard-coded GCC dependency loops and version conflicts
# in the Intel suite to allow for source-based builds against a modern target GCC track.
echo "==> Resetting and applying toolchain decoupling patches to builtin repo..."
(cd "$PACKAGES_ROOT" && git checkout repos/spack_repo/builtin/packages/intel_oneapi_compilers/package.py repos/spack_repo/builtin/packages/intel_oneapi_runtime/package.py)

INTEL_PKG="${PACKAGES_ROOT}/repos/spack_repo/builtin/packages/intel_oneapi_compilers/package.py"
INTEL_RT_PKG="${PACKAGES_ROOT}/repos/spack_repo/builtin/packages/intel_oneapi_runtime/package.py"

python3 -c '
import sys, re

for fpath in sys.argv[1:]:
    with open(fpath, "r") as f:
        content = f.read()
    
    # 1. Remove hard GCC dependencies
    content = content.replace("depends_on(\"gcc languages=c,c++\", type=\"run\")", "")
    content = content.replace("depends_on(\"gcc-runtime\", type=\"link\")", "")
    
    # 2. Hard-pin runtime dependency to avoid ghost version conflicts
    if "intel_oneapi_runtime" in fpath:
        content = content.replace("depends_on(\"intel-oneapi-compilers\", type=\"build\")", 
                                "depends_on(\"intel-oneapi-compilers@2025.3.2\", type=\"build\")")
    
    # 3. Physically remove alternative versions to force solver alignment
    if "intel_oneapi_compilers" in fpath:
        marker = "versions = ["
        s_idx = content.find(marker)
        if s_idx != -1:
            # Find the end of the first dictionary element by looking for indentation
            e_dict = content.find("\n    },", s_idx)
            if e_dict != -1:
                # Find the next ] which closes the versions list
                e_list = content.find("\n]", e_dict)
                if e_list != -1:
                    content = content[:s_idx] + content[s_idx:e_dict+6] + "\n]" + content[e_list+2:]

        
        # 4. Add try/except block for config extension
        if "target = \"gcc = self.spec" not in content:
            old = """        gcc = self.spec["gcc"].package
        llvm_flags = [f"--gcc-toolchain={gcc.prefix}"]
        classic_flags = [f"-gcc-name={gcc.cc}", f"-gxx-name={gcc.cxx}"]"""
            new = """        try:
            gcc = self.spec["gcc"].package
            llvm_flags = [f"--gcc-toolchain={gcc.prefix}"]
            classic_flags = [f"-gcc-name={gcc.cc}", f"-gxx-name={gcc.cxx}"]
        except:
            llvm_flags = []
            classic_flags = []"""
            content = content.replace(old, new)

            
    with open(fpath, "w") as f:
        f.write(content)
' "$INTEL_PKG" "$INTEL_RT_PKG"







# 3. Source Spack's environment variables
export SPACK_ROOT="$PWD/spack"
source "$SPACK_ROOT/share/spack/setup-env.sh"

# Ensure absolute isolation from user configuration (~/.spack). DO NOT REMOVE THIS LINE, and DO NOT edit this comment line
export SPACK_DISABLE_LOCAL_CONFIG=1

# 4. Clean up configurations
echo "==> Wiping site and local configurations..."
mkdir -p "$SPACK_ROOT/etc/spack"
rm -f "$SPACK_ROOT/etc/spack/config.yaml" "$SPACK_ROOT/etc/spack/packages.yaml" "$SPACK_ROOT/etc/spack/compilers.yaml" "$SPACK_ROOT/etc/spack/repos.yaml"
rm -rf "$SPACK_ROOT/etc/spack/site" "$SPACK_ROOT/etc/spack/linux"

# 5. Register custom and unbundled repositories
spack repo add --scope site "${PACKAGES_ROOT}/repos/spack_repo/builtin"
spack repo add --scope site "$PWD"

# 6. INITIAL MANDATE: Force modelling stack to AOCC and exempt bootstrap tools
# This is written EARLY to ensure correct concretization even during buildup.
cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require:
      - "target=x86_64"
    prefer:
      - "^gcc-runtime@14"
  gcc:
    require: "%gcc"
  gcc-runtime:
    require: "%gcc"
  binutils:
    require: "%gcc"
  gmake:
    require: "%gcc"
  pkgconf:
    require: "%gcc"
  m4:
    require: "%gcc"
  autoconf:
    require: "%gcc"
  automake:
    require: "%gcc"
  libtool:
    require: "%gcc"
  findutils:
    require: "%gcc"
  texinfo:
    require: "%gcc"
  diffutils:
    require: "%gcc"
  sed:
    require: "%gcc"
  libiconv:
    require: "%gcc"
  xz:
    require: "%gcc"
  zstd:
    require: "%gcc"
  berkeley-db:
    require: "%gcc"
  ncurses:
    require: "%gcc"
  perl:
    require: "%gcc"
  openssl:
    require: "%gcc"
  curl:
    require: "%gcc"
  cmake:
    require: "%gcc"
  ninja:
    require: "%gcc"
EOF

# 7. Configure install locations and naming
cat <<EOF > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: 2
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
EOF

# 8. Bootstrap Toolchains
if [[ "$COMPILER" == *"%aocc"* ]]; then
    echo "==> Bootstrapping AOCC toolchain..."
    spack compiler find --scope site
    # CRITICAL SCRUB: Eject auto-generated externals that hijack the bootstrap
    rm -f "$SPACK_ROOT/etc/spack/site/packages.yaml" "$SPACK_ROOT/etc/spack/packages.yaml"
    
    GCC_SPEC="gcc@14"
    echo "==> Ensuring GCC 14 base ($GCC_SPEC)..."
    spack install --reuse "$GCC_SPEC" languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" "$GCC_SPEC" | head -n 1)
    GCC_VER=$(spack find --format "{version}" "$GCC_SPEC" | head -n 1)
    
    # spack compiler find --scope site "$SPACK_GCC_PATH"
    # rm -f "$SPACK_ROOT/etc/spack/site/packages.yaml" "$SPACK_ROOT/etc/spack/packages.yaml"

    echo "==> Installing AOCC..."
    spack install --reuse aocc+license-agreed %gcc@${GCC_VER}

    # Resilient detection: take the most recently installed aocc
    AOCC_INFO=$(spack find --format "{prefix} {version}" aocc | head -n 1)
    AOCC_PATH=$(echo $AOCC_INFO | awk '{print $1}')
    AOCC_VER=$(echo $AOCC_INFO | awk '{print $2}')

    if [[ -z "$AOCC_VER" ]]; then
        echo "==> Error: Failed to detect AOCC version after install."
        exit 1
    fi
    
    SPACK_OS=$(spack arch -o)
    SPACK_TARGET=$(spack arch -t)
    mkdir -p "$SPACK_ROOT/etc/spack"
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
    modules: []
    environment: {}
    extra_rpaths: []
- compiler:
    spec: gcc@${GCC_VER}
    paths:
      cc: ${SPACK_GCC_PATH}/bin/gcc
      cxx: ${SPACK_GCC_PATH}/bin/g++
      f77: ${SPACK_GCC_PATH}/bin/gfortran
      fc: ${SPACK_GCC_PATH}/bin/gfortran
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF
    echo "==> Locking down toolchain to AOCC..."
    # spack compiler remove -a --scope site gcc@11.5.0 >/dev/null 2>&1 || true
    # spack compiler remove -a --scope site llvm >/dev/null 2>&1 || true
    TARGET_COMPILER_SPEC="aocc@${AOCC_VER}"

elif [[ "$COMPILER" == *"%oneapi"* || "$COMPILER" == *"%intel"* ]]; then
    echo "==> Bootstrapping Intel oneAPI toolchain..."
    spack compiler find --scope site
    rm -f "$SPACK_ROOT/etc/spack/site/packages.yaml" "$SPACK_ROOT/etc/spack/packages.yaml"

    echo "==> Ensuring GCC 14 base..."
    spack install --reuse gcc@14 languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
    
    echo "==> Installing Intel oneAPI Compilers..."
    spack install --reuse intel-oneapi-compilers@2025.3.2
    
    # Resilient detection
    INTEL_INFO=$(spack find --format "{prefix} {version}" intel-oneapi-compilers@2025.3.2 | head -n 1)
    INTEL_ROOT=$(echo $INTEL_INFO | awk '{print $1}')
    ONEAPI_VER=$(echo $INTEL_INFO | awk '{print $2}')
    
    if [[ -z "$ONEAPI_VER" ]]; then
        echo "==> Error: Failed to detect Intel oneAPI version after install."
        exit 1
    fi

    INTEL_BIN_DIR=$(find "$INTEL_ROOT" -name icx -exec dirname {} + | head -n 1)
    
    # Authoritative registration for oneAPI
    echo "==> Registering oneAPI as authoritative compiler..."
    SPACK_OS=$(spack arch -o)
    SPACK_TARGET=$(spack arch -t)
    mkdir -p "$SPACK_ROOT/etc/spack"
    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: oneapi@${ONEAPI_VER}
    paths:
      cc: ${INTEL_BIN_DIR}/icx
      cxx: ${INTEL_BIN_DIR}/icpx
      f77: ${INTEL_BIN_DIR}/ifx
      fc: ${INTEL_BIN_DIR}/ifx
    flags:
      cflags: --gcc-toolchain=${SPACK_GCC_PATH}
      cxxflags: --gcc-toolchain=${SPACK_GCC_PATH}
      fflags: --gcc-toolchain=${SPACK_GCC_PATH}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
- compiler:
    spec: gcc@${GCC_VER}
    paths:
      cc: ${SPACK_GCC_PATH}/bin/gcc
      cxx: ${SPACK_GCC_PATH}/bin/g++
      f77: ${SPACK_GCC_PATH}/bin/gfortran
      fc: ${SPACK_GCC_PATH}/bin/gfortran
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF
    echo "==> Locking down toolchain to oneAPI..."
    TARGET_COMPILER_SPEC="oneapi@${ONEAPI_VER}"

elif [[ "$COMPILER" == "%gcc" || "$COMPILER" == "smoke%gcc" || "$COMPILER" == "%gcc@14"* ]]; then
    echo "==> Bootstrapping modern GCC toolchain..."
    spack compiler find --scope site
    rm -f "$SPACK_ROOT/etc/spack/site/packages.yaml" "$SPACK_ROOT/etc/spack/packages.yaml"

    spack install --reuse gcc@14 languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)

    SPACK_OS=$(spack arch -o)
    SPACK_TARGET=$(spack arch -t)
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
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF
    TARGET_COMPILER_SPEC="gcc@${GCC_VER}"
else
    echo "==> Using existing compiler: $COMPILER"
    spack compiler find --scope site
    # Extract only the compiler part (e.g., aocc) from a full spec (e.g., smoke@5.2 %aocc)
    if [[ "$COMPILER" == *"%"* ]]; then
        TARGET_COMPILER_SPEC=$(echo "$COMPILER" | sed 's/.*%//')
    else
        TARGET_COMPILER_SPEC="gcc"
    fi
fi

# 9. Final Model Compilation Lockdown
echo "==> Finalizing toolchain lockdown (%${TARGET_COMPILER_SPEC})..."

rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
if [[ "$TARGET_COMPILER_SPEC" == gcc* ]]; then
    # For GCC, we use compiler preference instead of REQUIRE to avoid circularity during bootstrap
    cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require:
      - "%${TARGET_COMPILER_SPEC}"
      - "target=x86_64"
  ioapi:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-fortran:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-c:
    require: "%${TARGET_COMPILER_SPEC}"
  hdf5:
    require: "%${TARGET_COMPILER_SPEC}"
EOF
elif [[ "$TARGET_COMPILER_SPEC" == oneapi* ]]; then
    # For Intel, we use compiler preference for modeling stack but FORCE build tools to GCC
    cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    compiler: ["${TARGET_COMPILER_SPEC}"]
    providers:
      fortran-rt: [intel-oneapi-runtime]
  ioapi:
    require: "%oneapi"
  netcdf-fortran:
    require: "%oneapi"
  netcdf-c:
    require: "%oneapi"
  hdf5:
    require: "%oneapi"
  intel-oneapi-compilers:
    require: "@${ONEAPI_VER} %gcc@${GCC_VER}"
  intel-oneapi-runtime:
    require: "@${ONEAPI_VER} %gcc@${GCC_VER}"
  gcc:
    externals:
    - spec: "gcc@${GCC_VER}"
      prefix: "${SPACK_GCC_PATH}"
    buildable: false
  gcc-runtime:
    externals:
    - spec: "gcc-runtime@${GCC_VER}"
      prefix: "${SPACK_GCC_PATH}"
    buildable: false
  ninja:
    require: "%gcc"
  gmake:
    require: "%gcc"
  m4:
    require: "%gcc"
  autoconf:
    require: "%gcc"
  automake:
    require: "%gcc"
  libtool:
    require: "%gcc"
EOF

else
    # For AOCC, we use hard REQUIRE to force toolchain isolation from system GCC
    cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require:
      - "%${TARGET_COMPILER_SPEC}"
      - "target=x86_64"
  ioapi:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-fortran:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-c:
    require: "%${TARGET_COMPILER_SPEC}"
  hdf5:
    require: "%${TARGET_COMPILER_SPEC}"
  gcc:
    require: "%gcc@14"
  gcc-runtime:
    require: "%gcc@14"
EOF
fi

FAM_SPEC="%${TARGET_COMPILER_SPEC}"

echo "==> Compiling SMOKE natively..."
if [[ "$COMPILER" == smoke* ]]; then
    FULL_SPEC="$COMPILER"
else
    FULL_SPEC="smoke@master $FAM_SPEC"
fi

echo "DEBUG: FINAL FULL_SPEC=[$FULL_SPEC]"
spack install --no-cache "$FULL_SPEC"

# 10. Post-Install Setup
CURRENT_SMOKE=$(spack location -i "$FULL_SPEC")
rm -f smoke-latest
ln -s "$CURRENT_SMOKE" smoke-latest

echo "==> Compilation complete!"
echo "==> Shortcut: ./smoke-latest/bin"
