#!/bin/bash
# Usage: ./install.sh [COMPILER/SPEC] [/custom/install/path]
#
# Examples:
#   ./install.sh %aocc                      (Installs latest master with AOCC)
#   ./install.sh "smoke@5.2.1 %oneapi"      (Installs release 5.2.1 with Intel)
#   ./install.sh %gcc /home/user/smoke_bin  (Installs to custom location)

# Set default values if arguments are missing
COMPILER="${1:-%gcc}"
MY_INSTALL_ROOT="${2:-$PWD/install}"

# Stop on any error
set -e

echo "==> Preparing Spack for SMOKE Compilation with $COMPILER at $MY_INSTALL_ROOT"

# 1. Clone Spack locally if it doesn't exist on this machine
if [ ! -d "spack" ]; then
    echo "==> Downloading fresh Spack installation..."
    git clone -c feature.manyFiles=true https://github.com/spack/spack.git
fi

# 2. Source Spack's environment variables
export SPACK_ROOT="$PWD/spack"
source "$SPACK_ROOT/share/spack/setup-env.sh"

# Ensure absolute isolation from user configuration (~/.spack). DO NOT REMOVE THIS LINE, and DO NOT edit this comment line
export SPACK_DISABLE_LOCAL_CONFIG=1

# 3. Clean up site-level configurations to prevent contamination
# We KEEP the install root and Spack source to preserve already built packages
mkdir -p "$SPACK_ROOT/etc/spack"
rm -f "$SPACK_ROOT/etc/spack/packages.yaml" "$SPACK_ROOT/etc/spack/compilers.yaml" "$SPACK_ROOT/etc/spack/repos.yaml"
rm -rf "$SPACK_ROOT/etc/spack/site" "$SPACK_ROOT/etc/spack/linux"

# 4. Register custom local repository
export REPO_DIR="$PWD"
spack repo add --scope site "$REPO_DIR"

# 5. INITIAL MANDATE: Force modelling stack to AOCC and exempt bootstrap tools
# This is written EARLY to ensure correct concretization even during buildup.
cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
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

# 6. Configure install locations and naming
cat <<EOF > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  install_tree:
    root: $MY_INSTALL_ROOT
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
EOF

# 7. Bootstrap Toolchains
if [[ "$COMPILER" == "%aocc" || "$COMPILER" == "smoke%aocc" ]]; then
    echo "==> Bootstrapping AOCC toolchain..."
    spack compiler find --scope site
    
    GCC_SPEC="gcc@14"
    echo "==> Ensuring GCC 14 base ($GCC_SPEC)..."
    spack install --reuse "$GCC_SPEC" languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" "$GCC_SPEC" | head -n 1)
    GCC_VER=$(spack find --format "{version}" "$GCC_SPEC" | head -n 1)
    GCC_HASH=$(spack find --format "{hash:7}" "$GCC_SPEC" | head -n 1)
    spack compiler find --scope site "$SPACK_GCC_PATH"
    
    echo "==> Installing AOCC..."
    spack install --reuse aocc+license-agreed %gcc@${GCC_VER}
    AOCC_PATH=$(spack find --format "{prefix}" aocc %gcc@${GCC_VER} | head -n 1)
    AOCC_VER=$(spack find --format "{version}" aocc %gcc@${GCC_VER} | head -n 1)
    
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
EOF
    echo "==> Locking down toolchain to AOCC..."
    spack compiler remove -a gcc || true
    spack compiler remove -a llvm || true
    TARGET_COMPILER_SPEC="aocc@${AOCC_VER}"

elif [[ "$COMPILER" == "%oneapi" || "$COMPILER" == "smoke%oneapi" ]]; then
    echo "==> Bootstrapping Intel oneAPI toolchain..."
    spack compiler find --scope site
    echo "==> Ensuring GCC 14 base..."
    spack install --reuse gcc@14 languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    spack compiler find --scope site "$SPACK_GCC_PATH"
    
    echo "==> Installing Intel oneAPI Compilers..."
    spack install --reuse intel-oneapi-compilers
    INTEL_ROOT=$(spack location -i intel-oneapi-compilers)
    
    INTEL_BIN_DIR=$(find "$INTEL_ROOT" -name icx -exec dirname {} + | head -n 1)
    ONEAPI_VER=$(spack find --format "{version}" intel-oneapi-compilers | head -n 1)
    
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
EOF
    echo "==> Locking down toolchain to oneAPI..."
    TARGET_COMPILER_SPEC="oneapi@${ONEAPI_VER}"

elif [[ "$COMPILER" == "%gcc" || "$COMPILER" == "smoke%gcc" || "$COMPILER" == "%gcc@14"* ]]; then
    echo "==> Bootstrapping modern GCC toolchain..."
    spack compiler find --scope site
    spack install --reuse gcc@14 languages=c,c++,fortran
    SPACK_GCC_PATH=$(spack find --format "{prefix}" gcc@14 | head -n 1)
    GCC_VER=$(spack find --format "{version}" gcc@14 | head -n 1)
    spack compiler find --scope site "$SPACK_GCC_PATH"
    TARGET_COMPILER_SPEC="gcc@${GCC_VER}"
else
    echo "==> Using existing compiler: $COMPILER"
    spack compiler find --scope site
    TARGET_COMPILER_SPEC=$(echo "$COMPILER" | sed 's/%//')
fi

# 7e. AUTHORITATIVE LOCKDOWN: Remove ALL competing compilers
# We do this at the very end to ensure no auto-discovery overrides us.
echo "==> Finalizing toolchain lockdown (%${TARGET_COMPILER_SPEC})..."
if [[ "${TARGET_COMPILER_SPEC}" != "gcc"* ]]; then
    spack compiler remove -a --scope site gcc || true
    spack compiler remove -a --scope site llvm || true
    spack compiler remove -a --scope site intel-oneapi-compilers || true
fi

rm -f "$SPACK_ROOT/etc/spack/packages.yaml"
cat > "$SPACK_ROOT/etc/spack/packages.yaml" <<EOF
packages:
  all:
    require: "%${TARGET_COMPILER_SPEC}"
    compiler: ["${TARGET_COMPILER_SPEC}"]
  ioapi:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-fortran:
    require: "%${TARGET_COMPILER_SPEC}"
  netcdf-c:
    require: "%${TARGET_COMPILER_SPEC}"
  hdf5:
    require: "%${TARGET_COMPILER_SPEC}"
  gcc:
    require: "%gcc"
  gcc-runtime:
    require: "%gcc"
  binutils:
    require: "%gcc"
  gmake:
    require: "%gcc"
  cmake:
    require: "%gcc"
  ninja:
    require: "%gcc"
EOF


FAM_SPEC="%${TARGET_COMPILER_SPEC}"


# 8. Final Model Compilation
echo "==> Compiling SMOKE natively..."

if [[ "$COMPILER" == smoke* ]]; then
    FULL_SPEC="$COMPILER"
else
    FULL_SPEC="smoke@master $FAM_SPEC"
fi

echo "DEBUG: FINAL FULL_SPEC=[$FULL_SPEC]"
spack install --no-cache $FULL_SPEC

# 9. Post-Install Setup
CURRENT_SMOKE=$(spack location -i $FULL_SPEC)
rm -f smoke-latest
ln -s "$CURRENT_SMOKE" smoke-latest

echo "==> Compilation complete!"
echo "==> Shortcut: ./smoke-latest/bin"
