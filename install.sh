#!/bin/bash
set -e

# ==============================================================================
# AUTHORITATIVE SMOKE SPACK DEPLOYMENT ENGINE
# ------------------------------------------------------------------------------
# USAGE:
#   ./install.sh %gcc               # Compiles SMOKE 5.2.1 with GCC 14
#   ./install.sh %aocc              # Compiles SMOKE 5.2.1 with AOCC 5.1
#   ./install.sh %intel             # Compiles SMOKE 5.2.1 with Intel oneAPI (or %oneapi)
#
#   ./install.sh "smoke@master %gcc"  # Compiles latest master with GCC 14
#   ./install.sh "smoke@5.2.1 %aocc"  # Compiles stable 5.2.1 with AOCC 5.1
#
# CUSTOM VERSIONS:
#   1. Edit ./packages/smoke/package.py
#   2. Add a new 'version("my-ver", ...)' line
#   3. Run ./install.sh "smoke@my-ver %gcc"
# ------------------------------------------------------------------------------
# RATIONALE:
# This script enforces absolute toolchain parity by isolating the build from the
# host environment and bootstrapping a modern toolchain (GCC 14) from source.
# It solves the "Split Toolchain" bug where Spack might use Intel for C but 
# fall back to a stale host GCC for Fortran.
# ==============================================================================

# 1. Environment Isolation
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${PWD}/.spack-cache"
export SPACK_ROOT="${PWD}/spack"
unset PYTHONPATH # Prevent contamination from host Spack or Python libs
mkdir -p "$SPACK_USER_CACHE_PATH"

# 2. Scope & Paths
INSTALL_ROOT="${PWD}/install"
mkdir -p "$INSTALL_ROOT"

# 2b. Auto-Provision Spack
if [[ ! -d "$SPACK_ROOT" ]]; then
    echo "==> Spack not found at $SPACK_ROOT. Cloning from GitHub..."
    git clone -c feature.manyFiles=true https://github.com/spack/spack.git "$SPACK_ROOT" || {
        echo "ERROR: Failed to clone Spack. Please check your internet connection."
        exit 1
    }
fi

# 3. Source Spack
source "$SPACK_ROOT/share/spack/setup-env.sh"

# 4. Repository Registration
# We force-refresh the repository and clean the metadata cache to prevent
# stale path errors (e.g., "No module named spack_repo").
echo "==> Refreshing Spack repository registration..."
spack clean -m
spack repo remove smoke_v52 >/dev/null 2>&1 || true
spack repo add --scope site "$PWD"
spack repo list

# 5. Toolchain Selection
ARG1="${1:-%gcc}"
if [[ "$ARG1" == "%intel" || "$ARG1" == "%oneapi" ]]; then
    COMPILER="%oneapi"
elif [[ "$ARG1" == "%aocc" ]]; then
    COMPILER="%aocc"
elif [[ "$ARG1" == "%gcc" ]]; then
    COMPILER="%gcc"
else
    COMPILER="$ARG1"
fi
echo "==> Preparing Spack for SMOKE Compilation with $COMPILER at $INSTALL_ROOT"

# 6. Authoritative Bootstrapping
# We find system compilers ONLY for the initial bootstrap of GCC 14.
# Once GCC 14 is built, it serves as the foundational 'site' compiler for 
# all subsequent optimized toolchains (AOCC, oneAPI).
spack compiler find --scope site
spack install --no-cache gcc@14.3.0

# Register GCC 14 as the site-supported foundation for C++ and Fortran runtimes.
GCC_DIR=$(spack find --format "{prefix}" gcc@14.3.0 | head -n 1)
spack compiler add --scope site "$GCC_DIR"

if [[ "$COMPILER" == "%aocc" ]]; then
    echo "==> Bootstrapping AOCC toolchain..."
    spack install --no-cache aocc@5.1.0 %gcc@14.3.0
    AOCC_DIR=$(spack find --format "{prefix}" aocc@5.1.0 | head -n 1)
    
    # Authoritative AOCC Site-Registration
    # We manually write compilers.yaml to ensure Spack has exact binary paths
    # and doesn't try to guess or search the system PATH during later phases.
    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: aocc@5.1.0
    paths:
      cc: $AOCC_DIR/bin/clang
      cxx: $AOCC_DIR/bin/clang++
      f77: $AOCC_DIR/bin/flang
      fc: $AOCC_DIR/bin/flang
    flags: {}
    operating_system: centos7
    target: x86_64
    modules: []
    environment: {}
    extra_rpaths: []
EOF
    TARGET_COMPILER_SPEC="aocc@5.1.0"
    FAM_SPEC="%aocc"

elif [[ "$COMPILER" == "%oneapi" ]]; then
    echo "==> Bootstrapping Intel oneAPI toolchain..."
    spack install --no-cache intel-oneapi-compilers@2025.3.2 %gcc@14.3.0
    INTEL_BASE=$(spack find --format "{prefix}" intel-oneapi-compilers@2025.3.2 | head -n 1)
    INTEL_BIN_DIR=$(find "$INTEL_BASE" -name "icx" -exec dirname {} \; | head -n 1)
    
    # Authoritative oneAPI Registration
    # Prevents the "ifx vs gfortran" split by mandating icx/ifx in a site-scope definition.
    cat > "$SPACK_ROOT/etc/spack/compilers.yaml" <<EOF
compilers:
- compiler:
    spec: oneapi@2025.3.2
    paths:
      cc: $INTEL_BIN_DIR/icx
      cxx: $INTEL_BIN_DIR/icpx
      f77: $INTEL_BIN_DIR/ifx
      fc: $INTEL_BIN_DIR/ifx
    flags: {}
    operating_system: centos7
    target: x86_64
    modules: []
    environment: {}
    extra_rpaths: []
EOF
    TARGET_COMPILER_SPEC="oneapi@2025.3.2"
    FAM_SPEC="%oneapi"

else
    echo "==> Using modern GCC toolchain..."
    TARGET_COMPILER_SPEC="gcc@14.3.0"
    FAM_SPEC="%gcc"
fi

# 7. Surgical Lockdown Phase
# CRITICAL: We remove all other compilers from Spack's site-scope.
echo "==> Locking down toolchain to $FAM_SPEC..."
spack compiler remove -a --scope site gcc@11.5.0 >/dev/null 2>&1 || true
spack compiler remove -a --scope site llvm >/dev/null 2>&1 || true
if [[ "$FAM_SPEC" != "%oneapi" ]]; then
    spack compiler remove -a --scope site oneapi >/dev/null 2>&1 || true
    spack compiler remove -a --scope site intel-oneapi-compilers >/dev/null 2>&1 || true
fi

# Authoritative Package Mandate
# We use 'require' and 'compiler' directives to forge an unbreakable link.
# We exempt core build tools (cmake, ninja, etc) to use GCC for stability.
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

echo "==> Finalizing toolchain lockdown (${TARGET_COMPILER_SPEC})..."

# 8. Final Model Compilation
echo "==> Compiling SMOKE natively..."

if [[ "$COMPILER" == smoke* ]]; then
    FULL_SPEC="$COMPILER"
else
    # Default to master for Intel oneAPI as requested, stability for others.
    if [[ "$FAM_SPEC" == "%oneapi" ]]; then
        FULL_SPEC="smoke@master $FAM_SPEC"
    else
        FULL_SPEC="smoke@5.2.1 $FAM_SPEC"
    fi
fi

echo "DEBUG: FINAL FULL_SPEC=[$FULL_SPEC]"
spack install --no-cache $FULL_SPEC

# 9. Post-Install Setup
# Create a shortcut to the latest build.
SMOKE_INSTALL=$(spack find --format "{prefix}" $FULL_SPEC | head -n 1)
rm -rf smoke-latest
ln -s "$SMOKE_INSTALL" smoke-latest

echo "==> Compilation complete!"
echo "==> Shortcut: ./smoke-latest/bin"
