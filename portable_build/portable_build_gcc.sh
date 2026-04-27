#!/bin/bash
set -euo pipefail

# SMOKE Independent Portable Build Orchestrator (Apptainer/RockyLinux 8)
# Track: GCC Toolchain with Foundation Caching
# Enforces complete static linking and x86_64 generic architecture.

# --- DOCUMENTATION ---
# This script utilizes several persistent layers to ensure isolation and speed:
#
# 1. .foundation_cache (The Toolchain Layer)
#    - Mapped to: /opt/foundation
#    - Role: Stores the bootstrapped GCC 14 compiler and its runtime.
#    - Benefit: Saves ~20-30 mins. Registered as a Spack 'Upstream'.
#
# 2. .build_cache (The Application Layer)
#    - Mapped to: /opt/build_cache
#    - Role: Stores binary 'blobs' of SMOKE and libraries (NetCDF, HDF5, etc.).
#    - Benefit: Saves ~30-60 mins. Registered as a Spack 'Mirror'.
#
# 3. .spack_home (The User Layer)
#    - Mapped to: /root (or container $HOME)
#    - Role: Persists Spack metadata, GPG keys, and local configuration.
#
# 4. .apptainer_cache (The Image Layer)
#    - Role: Stores downloaded Docker/OCI layers.
#    - Benefit: Prevents re-downloading the ~70MB base image from Docker Hub.
#
# 5. .apptainer_tmp (The Workspace Layer)
#    - Role: Temporary staging area for building the .sif image.
#    - Benefit: Prevents 'No space left on device' errors in the host /tmp.
# ---------------------

# --- Configuration & Paths ---
OS_IMAGE="rocky8_build.sif"
INSTALL_ROOT="./install_gcc"
FOUNDATION_CACHE="${PWD}/.foundation_cache"
BUILD_CACHE="${PWD}/.build_cache"
SPACK_HOME_DIR="${PWD}/.spack_home"
CACHE_DIR="${PWD}/.apptainer_cache"
TMP_DIR="${PWD}/.apptainer_tmp"

log() { echo "==> [PORTABLE] $1"; }

# --- Argument Parsing ---
REBUILD_ALL=false
REBUILD_LIBS=false
REBUILD_IOAPI=false
REBUILD_SMOKE=false
BUILD_JOBS=$(nproc 2>/dev/null || echo 4)
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --rebuild-all) REBUILD_ALL=true; shift ;;
        --rebuild-libs) REBUILD_LIBS=true; shift ;;
        --rebuild-ioapi) REBUILD_IOAPI=true; shift ;;
        --rebuild-smoke) REBUILD_SMOKE=true; shift ;;
        --jobs) BUILD_JOBS="$2"; shift 2 ;;
        *) POSITIONAL_ARGS+=("$1") ; shift ;;
    esac
done

COMP_SPEC="${POSITIONAL_ARGS[0]:-%gcc}"
COMP_SPEC="${COMP_SPEC#%}" # Strip leading % if present
[[ "$INSTALL_ROOT" != /* ]] && INSTALL_ROOT="$PWD/$INSTALL_ROOT"

# --- Host-Side Preparation & Nuclear Cleanup ---
if [ "$REBUILD_ALL" = "true" ]; then
    log "NUCLEAR RESET: Purging ALL caches, installations, and toolchains..."
    rm -rf "$INSTALL_ROOT" "$SPACK_HOME_DIR" "$FOUNDATION_CACHE" spack smoke_spec.json
fi
mkdir -p "$SPACK_HOME_DIR" "$CACHE_DIR" "$TMP_DIR" "$FOUNDATION_CACHE" "$BUILD_CACHE"

# Sanitize Foundation Metadata (Finding #153-revised)
# Reconciles paths in the foundation database without pruning entries.
_HOST_FOUNDATION_DB="$FOUNDATION_CACHE/opt/spack/.spack-db/index.json"
if [ -f "$_HOST_FOUNDATION_DB" ]; then
    log "Relocating Foundation Metadata (Finding #153)..."
    python3 -c "
import json, os
db_path = '$_HOST_FOUNDATION_DB'
with open(db_path, 'r') as f:
    db = json.load(f)
if 'database' in db and 'installs' in db['database']:
    installs = db['database']['installs']
    for h, data in installs.items():
        if 'path' in data:
            data['path'] = data['path'].replace('/build/spack/opt/spack', '/opt/foundation/opt/spack')
with open(db_path, 'w') as f:
    json.dump(db, f)
" || true
fi

# --- Containerized Build Execution ---
log "Launching Container Enclave..."
apptainer exec --containall \
    --bind .:/build \
    --bind /tmp:/tmp \
    --bind "$FOUNDATION_CACHE":/opt/foundation \
    --bind "$BUILD_CACHE":/opt/build_cache \
    --bind "$SPACK_HOME_DIR":"$HOME" \
    --env COMP_SPEC="$COMP_SPEC" \
    --env REBUILD_ALL="$REBUILD_ALL" \
    --env REBUILD_LIBS="$REBUILD_LIBS" \
    --env REBUILD_IOAPI="$REBUILD_IOAPI" \
    --env REBUILD_SMOKE="$REBUILD_SMOKE" \
    --env BUILD_JOBS="$BUILD_JOBS" \
    "$OS_IMAGE" /bin/bash <<'EOF'
set -euo pipefail
log() { echo "==> [CONTAINER] $1"; }
cd /build

# Paths
SPACK_ROOT="/build/spack"
export SPACK_DISABLE_LOCAL_CONFIG=1

# --- Step 1: Spack & Repo Setup ---
if [ ! -d "spack" ]; then
    log "Downloading Spack v1.1.1..."
    git clone -b v1.1.1 --depth 1 https://github.com/spack/spack.git
fi
source "$SPACK_ROOT/share/spack/setup-env.sh"
log "DEBUG: Spack version: $(spack --version)"

log "Configuring Enclave..."
mkdir -p "$SPACK_ROOT/etc/spack"
rm -f "$SPACK_ROOT/etc/spack/"{config,packages,compilers,repos,upstreams}.yaml

# High-capacity staging and cache redirection is mandatory to prevent disk exhaustion in /proj (Finding #142)
log "DEBUG: Creating config.yaml with /tmp redirection..."
cat <<EOC > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: $BUILD_JOBS
  build_stage: [/tmp/tranhuy/spack-stage]
  source_cache: /tmp/tranhuy/spack-cache
  misc_cache: /tmp/tranhuy/spack-misc
  test_stage: /tmp/tranhuy/spack-test
  install_tree:
    root: /build/install_gcc
EOC

# --- Step 2: Repository Cleanup ---
log "DEBUG: Ensuring clean repository state..."
spack repo remove smoke_v52 2>/dev/null || true

# Register the local builtin repository to avoid network calls in isolated container
log "Registering local builtin repository..."
spack repo add --scope site /build/spack-packages/repos/spack_repo/builtin || true

log "Configuring Binary Mirror..."
spack mirror add local_cache file:///opt/build_cache 2>/dev/null || true
spack buildcache keys --install --trust 2>/dev/null || true

# --- Step 3: Toolchain & Upstream Registration ---
# We check for a marker file indicating a complete foundation build.
if [ -f "/opt/foundation/foundation_complete" ]; then
    log "Found established Foundation Cache at /opt/foundation. Synchronizing..."
    cat <<EOC > "$SPACK_ROOT/etc/spack/upstreams.yaml"
upstreams:
  foundation:
    install_tree: /opt/foundation/opt/spack
EOC
    log "DEBUG: Searching for GCC in foundation..."
    _GCC_BIN=$(find /opt/foundation -name gcc -type f -path "*/gcc-14*/bin/gcc" | head -n 1)
    
    if [ -n "$_GCC_BIN" ]; then
        FOUNDATION_VER=$("$_GCC_BIN" -dumpversion || echo "14.3.0")
        log "DEBUG: Found GCC $FOUNDATION_VER at $_GCC_BIN. Restoring Toolchain Wrappers..."
        
        # Re-create the wrappers that Spack expects at /build/toolchain_wrappers
        mkdir -p /build/toolchain_wrappers
        _GCC_DIR=$(dirname "$_GCC_BIN")
        for tool in gcc g++ gfortran; do
            cat <<EOW > "/build/toolchain_wrappers/$tool"
#!/bin/bash
exec "$_GCC_DIR/$tool" -B/opt/foundation/bin -L/opt/foundation/lib64 "\$@"
EOW
            chmod +x "/build/toolchain_wrappers/$tool"
        done

        # Manual registration of foundation toolchain using wrappers (Finding #149)
        # Pointing to wrappers ensures relocation stability in isolated containers.
        cat <<EOC > "$SPACK_ROOT/etc/spack/compilers.yaml"
compilers:
- compiler:
    spec: gcc@$FOUNDATION_VER
    paths:
      cc: /build/toolchain_wrappers/gcc
      cxx: /build/toolchain_wrappers/g++
      f77: /build/toolchain_wrappers/gfortran
      fc: /build/toolchain_wrappers/gfortran
    operating_system: rocky8
    target: x86_64
    modules: []
    environment: {}
    flags: {}
EOC
    fi
else
    log "No Foundation Cache found. Initiating Toolchain Recovery/Bootstrap phase..."
    
    # Step 3.1: Standard configuration for bootstrap
    cat <<EOC > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: $BUILD_JOBS
  install_tree:
    root: "$SPACK_ROOT/opt/spack"
EOC

    log "Registering bootstrap compiler..."
    # Manual registration of bootstrap compiler to avoid hanging discovery (Finding #2)
    cat <<EOC > "$SPACK_ROOT/etc/spack/compilers.yaml"
compilers:
- compiler:
    spec: gcc@8.5.0
    paths:
      cc: /usr/bin/gcc
      cxx: /usr/bin/g++
      f77: /usr/bin/gfortran
      fc: /usr/bin/gfortran
    operating_system: rocky8
    target: x86_64
    modules: []
    environment: {}
    flags: {}
EOC
    SYSTEM_GCC="/usr/bin/gcc"
    GCC_VER_BASE="8.5.0"
    SYSTEM_PREFIX="/usr"

    log "Aggressively patching toolchain metadata for resilience (Finding #16/19/20)..."
    # Resolve 'NoneType' errors by hardcoding system paths for bootstrap dependencies
    find "$SPACK_ROOT/var/spack/repos/builtin/packages" -name package.py | grep -E "gcc_runtime|compiler_wrapper" | xargs sed -i "s|Executable(compiler.cc)|Executable('/usr/bin/gcc')|g" || true

    log "Clearing existing solver constraints for bootstrap..."
    # Ensure no previous 'require' rules block the foundation build
    # We remove the site-level packages.yaml to ensure a Tabula Rasa (Finding #152)
    rm -f "$SPACK_ROOT/etc/spack/site/packages.yaml"

    log "Registering host toolchain externals..."
    cat <<EOC > /tmp/externals.yaml
packages:
  all:
    require: ["target=x86_64", "os=rocky8"]
  gcc:
    externals: [{spec: "gcc@$GCC_VER_BASE", prefix: $SYSTEM_PREFIX}]
    buildable: true
  gcc-runtime:
    externals: [{spec: "gcc-runtime@$GCC_VER_BASE", prefix: /usr}]
    buildable: true
EOC
    spack config --scope site add -f /tmp/externals.yaml

    log "Installing Modern Toolchain (GCC 14 + Binutils)..."
    spack --no-color install --reuse binutils@2.41 +ld +plugins %gcc@$GCC_VER_BASE target=x86_64
    spack --no-color install --reuse gcc@14.3.0 +piclibs %gcc@$GCC_VER_BASE target=x86_64

    FOUNDATION_VER="14.3.0"
    _GCC_BIN=$(find "$SPACK_ROOT/opt/spack" -name "gcc" -path "*/gcc-14*/bin/gcc" -type f | head -n 1)

    log "Checkpointing Foundation to persistent cache..."
    mkdir -p /opt/foundation/opt
    cp -rp "$SPACK_ROOT/opt/spack" /opt/foundation/opt/
    touch /opt/foundation/foundation_complete
    
    # Create relocation wrappers for the newly built foundation (Finding #149)
    mkdir -p /build/toolchain_wrappers
    _GCC_DIR=$(dirname "$_GCC_BIN")
    for tool in gcc g++ gfortran; do
        cat <<EOW > "/build/toolchain_wrappers/$tool"
#!/bin/bash
exec "$_GCC_DIR/$tool" -B/opt/foundation/bin -L/opt/foundation/lib64 "\$@"
EOW
        chmod +x "/build/toolchain_wrappers/$tool"
    done
    
    cat <<EOC > "$SPACK_ROOT/etc/spack/compilers.yaml"
compilers:
- compiler:
    spec: gcc@14.3.0
    paths:
      cc: /build/toolchain_wrappers/gcc
      cxx: /build/toolchain_wrappers/g++
      f77: /build/toolchain_wrappers/gfortran
      fc: /build/toolchain_wrappers/gfortran
    operating_system: rocky8
    target: x86_64
    modules: []
    environment: {}
    flags: {}
EOC
fi

# Step 3.2: Target the Modeling Stack installation directory (Finding #150)
# We isolate the Modeling Stack (NetCDF/SMOKE) in /build/install_gcc to ensure
# it can be packaged independently of the toolchain foundation.
cat <<EOC > "$SPACK_ROOT/etc/spack/config.yaml"
config:
  build_jobs: $BUILD_JOBS
  install_tree:
    root: "/build/install_gcc"
EOC

# --- Step 4: Solver Hardening ---
# We pin the GCC package version to match the bootstrapped toolchain to resolve Solver Ghosts (Finding #188)
log "DEBUG: Using Foundation GCC Version: $FOUNDATION_VER"

# Non-destructive configuration injection (Finding #106)
# This ensures that hardening rules are applied AFTER toolchain registration
# and preserves the compiler metadata migrated by the Spack engine.
cat <<EOC > /tmp/hardening.yaml
packages:
  gcc:
    require: "@$FOUNDATION_VER"
  all:
    require: ["%$COMP_SPEC", "target=x86_64"]
    variants: "+pic"
EOC
spack config --scope site add -f /tmp/hardening.yaml

# --- Step 5: Final SMOKE Build ---
log "DEBUG: Finalizing Repository Registration..."
spack repo add --scope site /build || true

FULL_SPEC="smoke@master %gcc@$FOUNDATION_VER target=x86_64 ^netcdf-c~shared ^netcdf-fortran~shared ^hdf5~shared ^zlib~shared"
log "DEBUG: Final Install Spec: $FULL_SPEC"

# Surgical Purges: Targeted uninstalls to allow rapid iteration without full stack rebuilds.
if [ "$REBUILD_LIBS" = "true" ]; then
    log "Surgical Purge: Dependent Libraries (NetCDF/HDF5/Zlib)"
    spack uninstall -a -y --force netcdf-fortran netcdf-c hdf5 zlib || true
fi
if [ "$REBUILD_IOAPI" = "true" ]; then
    log "Surgical Purge: ioapi"
    spack uninstall -a -y --force ioapi || true
fi
if [ "$REBUILD_SMOKE" = "true" ]; then
    log "Surgical Purge: smoke"
    spack uninstall -a -y --force smoke || true
fi

log "Installing SMOKE Suite..."
_INSTALL_FLAGS="--reuse"
[ "$REBUILD_ALL" = "true" ] && _INSTALL_FLAGS="--no-cache"

spack install $_INSTALL_FLAGS -v -j "$BUILD_JOBS" $FULL_SPEC
EOF

log "Build process complete."
