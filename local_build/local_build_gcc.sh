#!/bin/bash
# local_build_gcc.sh - Spack-Driven GCC Unified Enclave (V2 - Local Packages)
# Hardened for Production: Hermetic, Isolated, and Deadlock-Proof

set -euo pipefail

log() { echo "==> $1"; }

# --- 0. Argument Parsing ---
CLEAN_BUILD=false
REBUILD_IOAPI=false
REBUILD_SMOKE=false
SMOKE_VERSION=""
SMOKE_VERSION_EXPLICIT=false
SMOKE_COMPONENTS=""

for arg in "$@"; do
    case $arg in
        --rebuild) CLEAN_BUILD=true ;;
        --ioapi)       REBUILD_IOAPI=true ;;
        --smoke)       REBUILD_SMOKE=true ;;
        --smoke-version=*) SMOKE_VERSION="${arg#*=}"; SMOKE_VERSION_EXPLICIT=true ;;
        --smoke-*) 
            component="${arg#--smoke-}"
            if [ "$component" != "version" ]; then
                SMOKE_COMPONENTS="${SMOKE_COMPONENTS} ${component}"
            fi
            ;;
    esac
done

# Dynamic enclave naming
COMPILER_NAME="gcc"
ENCLAVE_SUFFIX="${COMPILER_NAME}_enclave"
STACK_SUFFIX="${COMPILER_NAME}"

# --- 1. Paths & Versions ---
PROJECT_ROOT="$PWD"
SPACK_ROOT="${PROJECT_ROOT}/spack"
ENV_NAME="smoke-${COMPILER_NAME}-enclave"
MY_INSTALL_ROOT="${PROJECT_ROOT}/install_${STACK_SUFFIX}"

# --- 1a. Infer Default SMOKE Version (if not specified) ---
if [ -z "$SMOKE_VERSION" ]; then
    SMOKE_VERSION=$(grep -v '^[[:space:]]*#' "${PROJECT_ROOT}/packages/smoke/package.py" | grep 'version.*preferred=True' | sed -E 's/.*version\("([^"]+)".*/\1/' | head -1 || true)
    if [ -z "$SMOKE_VERSION" ]; then
        SMOKE_VERSION=$(grep -v '^[[:space:]]*#' "${PROJECT_ROOT}/packages/smoke/package.py" | grep 'version(' | sed -E 's/.*version\("([^"]+)".*/\1/' | head -1 || true)
    fi
    log "SMOKE version not specified, inferred default: ${SMOKE_VERSION}"
fi

log "Using SMOKE version: ${SMOKE_VERSION}"

# If --smoke-version was explicitly specified, automatically trigger rebuild
if [ "$SMOKE_VERSION_EXPLICIT" = true ]; then
    log "Explicit SMOKE version specified: automatically enabling rebuild..."
    REBUILD_SMOKE=true
fi

# Purge stale git archive cache when building dev versions,
# so Spack re-archives from current HEAD instead of a stale snapshot.
SMOKE_VERSION_BASE="${SMOKE_VERSION%%+*}"
if [ "$SMOKE_VERSION_BASE" = "dev" ] || [ "$SMOKE_VERSION_BASE" = "dev-omp" ]; then
    if [ "$SMOKE_VERSION_BASE" = "dev-omp" ]; then
        SMOKE_DEV_PATH_RESOLVED="${SMOKE_DEV_OMP_PATH:-/proj/ie/proj/SMOKE/htran/SMOKE_OpenMP}"
    else
        SMOKE_DEV_PATH_RESOLVED="${SMOKE_DEV_PATH:-/proj/ie/proj/SMOKE/htran/SMOKE_MASTER}"
    fi
    SMOKE_GIT_CACHE="${SPACK_ROOT}/var/spack/cache/_source-cache/git${SMOKE_DEV_PATH_RESOLVED}"
    if [ -d "$SMOKE_GIT_CACHE" ]; then
        log "Purging stale git archive cache for ${SMOKE_VERSION_BASE} source: ${SMOKE_GIT_CACHE}"
        rm -rf "$SMOKE_GIT_CACHE"
    fi
fi


# --- 1b. Expected toolchain locations (via stable symlinks) ---
# CUSTOMIZE: Update this path to point to your pre-installed GCC compiler
# Default: Uses symlink in PROJECT_ROOT (e.g., ${PROJECT_ROOT}/gcc-latest)
# Alternative: Set to absolute path like /usr/local/gcc-14.3.0 or /opt/gcc-14
SPACK_GCC_PATH="${PROJECT_ROOT}/gcc-latest"

# Detect GCC version dynamically
# Parse from gcc --version output (e.g., "gcc (GCC) 14.3.0")
GCC_VER=$(${SPACK_GCC_PATH}/bin/gcc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "14.3.0")

log "Detected GCC version: ${GCC_VER}"

# --- 1a. Toolchain Validation ---
if [ ! -d "${SPACK_GCC_PATH}" ]; then
    log "ERROR: GCC ${GCC_VER} Toolchain NOT found at ${SPACK_GCC_PATH}"
    log "Please run: ./build_foundation_gcc.sh"
    exit 1
fi

log "Toolchain validation successful."

if [ "$CLEAN_BUILD" = true ]; then
    log "Performing clean build reset..."
    rm -rf "${MY_INSTALL_ROOT}"
    rm -rf "${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}" "${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    #mkdir -p "${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}" "${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    log "Removing Spack environment: ${ENV_NAME}"
    rm -rf "${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
fi

# --- 2. Initialize Spack ---
if [ ! -d "${SPACK_ROOT}" ]; then
    log "Spack not found at ${SPACK_ROOT}. Cloning fresh Spack..."
    git clone -b releases/latest https://github.com/spack/spack.git "${SPACK_ROOT}"
fi

if [ -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
    source "${SPACK_ROOT}/share/spack/setup-env.sh" # spack command now is available to use
    export SPACK_DISABLE_LOCAL_CONFIG=1
        
    # Isolate site-level configuration to prevent leaks from problematic site/packages.yaml
    export SPACK_SYSTEM_CONFIG_PATH="${PROJECT_ROOT}/.spack_site_config_empty"
    mkdir -p "${SPACK_SYSTEM_CONFIG_PATH}"

    export SPACK_USER_CACHE_PATH="${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}"
    export SPACK_USER_CONFIG_PATH="${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    mkdir -p "${SPACK_USER_CACHE_PATH}" "${SPACK_USER_CONFIG_PATH}"

    # Ensure our local specialized repo is added
    if ! spack -C "${SPACK_USER_CONFIG_PATH}" repo list | grep -q "smoke_v52"; then
        log "Adding local specialized Spack repository..."
        spack -C "${SPACK_USER_CONFIG_PATH}" repo add "${PROJECT_ROOT}/packages" || true
    fi

    log "Configuring enclave install path and local build stage..."
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/config.yaml"
config:
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      smoke: "{name}-{version}{package.omp_suffix}-{compiler.name}-{hash:7}"
      all: "{name}-{version}-{compiler.name}-{hash:7}"
  build_stage:
    - "$PROJECT_ROOT/spack-stage"
EOF
    
    # 3. Manual Toolchain Registration (Deterministic)
    log "Registering existing GCC toolchain..."
    # We hard-code the compilers.yaml for absolute reproducibility.
    GCC_BIN_DIR="${SPACK_GCC_PATH}/bin"
    # Detect architecture for manual compiler config
    SPACK_TARGET=$(spack -C "${SPACK_USER_CONFIG_PATH}" arch -t)
    SPACK_OS=$(spack -C "${SPACK_USER_CONFIG_PATH}" arch -o)
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/compilers.yaml"
compilers:
- compiler:
    spec: gcc@${GCC_VER}
    paths:
      cc: ${GCC_BIN_DIR}/gcc
      cxx: ${GCC_BIN_DIR}/g++
      f77: ${GCC_BIN_DIR}/gfortran
      fc: ${GCC_BIN_DIR}/gfortran
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    flags: {}
    extra_rpaths: []
EOF

    # 4. Environment Orchestration
    # Only attempt removal if we didn't already do a clean reset (which already deleted the environment)
    if [ "$CLEAN_BUILD" = true ] && spack -C "${SPACK_USER_CONFIG_PATH}" env list | grep -q "${ENV_NAME}"; then
        log "Purging stale Spack environment: ${ENV_NAME}"
        spack -C "${SPACK_USER_CONFIG_PATH}" env remove -y "${ENV_NAME}" || true
        sleep 1  # Give Spack time to release locks
    fi
    log "Initializing fresh Spack environment: ${ENV_NAME}"
    # Only create if it doesn't exist after cleanup attempt
    if ! spack -C "${SPACK_USER_CONFIG_PATH}" env list | grep -q "${ENV_NAME}"; then
        spack -C "${SPACK_USER_CONFIG_PATH}" env create "${ENV_NAME}"
    fi
    # Mask host compilers from Spack's discovery path early
    SAFE_PATH=$(echo "$PATH" | tr ":" "\n" | grep -vE "gcc|llvm|aocc|intel" | tr "\n" ":" | sed 's/:$//')

    log "Identifying system build tools (cmake, gmake, etc.)..."
    env PATH="$SAFE_PATH" spack -C "${SPACK_USER_CONFIG_PATH}" external find --scope site cmake gmake pkgconf autoconf automake m4 libtool perl python
    
    
    # Register compilers and packages in spack.yaml for better isolation
    log "Configuring spack.yaml for GCC enclave..."
    ENV_DIR="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
    mkdir -p "${ENV_DIR}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
  compilers:
  - compiler:
      spec: gcc@${GCC_VER}
      paths:
        cc: ${GCC_BIN_DIR}/gcc
        cxx: ${GCC_BIN_DIR}/g++
        f77: ${GCC_BIN_DIR}/gfortran
        fc: ${GCC_BIN_DIR}/gfortran
      operating_system: ${SPACK_OS}
      target: ${SPACK_TARGET}
      modules: []
      environment: {}
      flags: {}
      extra_rpaths: []
  packages:
    llvm:
      buildable: false
    aocc:
      buildable: false
    intel-oneapi-compilers:
      buildable: false
  specs: []
  view:
    default:
      root: .spack-env/view
      projections:
        smoke: '{name}-{version}{package.omp_suffix}'
        ioapi: '{name}-{version}{package.omp_suffix}'
        all: '{name}-{version}'
  concretizer:
    unify: true
    reuse: false
EOF
    
    # 5. Build foundations (skip if only rebuilding IOAPI or SMOKE)
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Building foundation layer (zlib, hdf5, netcdf-c, netcdf-fortran)..."
        # Ensure foundations are installed with GCC via local recipes
        # Note: Using variants that match 'ioapi' and 'smoke' requirements to avoid redundant builds
        # NOTE: curl omitted - netcdf-c ~dap disables curl dependency, IOAPI doesn't use curl
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add zlib %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add libaec %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add hdf5+shared~mpi+cxx+fortran+hl+szip %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-c~mpi+shared~dap+szip %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-fortran+shared %gcc@${GCC_VER}
        
        log "Performing foundation installation (this may take time)..."
        env PATH="$SAFE_PATH" TERM=dumb \
            spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
    else
        log "Skipping foundation build (using existing installations)..."
    fi
    
    # 6. Build IOAPI and SMOKE
    # Determine IOAPI variant: if building OpenMP SMOKE, we must use OpenMP IOAPI
    IOAPI_VARIANT="~openmp"
    if [[ "${SMOKE_VERSION}" == *"dev-omp"* ]] || [[ "${SMOKE_VERSION}" == *"+openmp"* ]]; then
        IOAPI_VARIANT="+openmp"
    fi

    # Force selective rebuild by uninstalling and re-adding flagged packages
    if [ "$REBUILD_IOAPI" = true ]; then
        log "Forcing IOAPI rebuild (variant ${IOAPI_VARIANT}): removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove ioapi >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y ioapi >/dev/null 2>&1 || true
        log "Re-adding IOAPI with ${IOAPI_VARIANT}..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "ioapi${IOAPI_VARIANT}" %gcc@${GCC_VER}
    fi
    if [ "$REBUILD_SMOKE" = true ]; then
        # If rebuilding, uninstall the specific version(s) requested to avoid purging the whole enclave
        for sv in ${SMOKE_VERSION}; do
            if [ "$sv" = "dev-omp" ] || [[ "$sv" == *"+openmp"* ]]; then
                SPEC_TO_CLEAN="smoke@=${sv%%+*}+openmp"
            else
                SPEC_TO_CLEAN="smoke@=${sv%%~*}~openmp"
            fi
            log "Purging ${SPEC_TO_CLEAN} for rebuild..."
            spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove "${SPEC_TO_CLEAN}" %gcc@${GCC_VER} >/dev/null 2>&1 || true
            spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" uninstall -y "${SPEC_TO_CLEAN}" %gcc@${GCC_VER} >/dev/null 2>&1 || true
            
            log "Re-adding ${SPEC_TO_CLEAN} to environment..."
            spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "${SPEC_TO_CLEAN}" %gcc@${GCC_VER}
        done
        # Remove stale lock file so the concretizer re-solves from the updated spack.yaml
        rm -f "${ENV_DIR}/spack.lock"
    fi
    
    # Ensure specified versions are added to the environment
    log "Ensuring IOAPI (variant ${IOAPI_VARIANT}) and SMOKE are in environment..."
    spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "ioapi${IOAPI_VARIANT}" %gcc@${GCC_VER}
    for sv in ${SMOKE_VERSION}; do
        # Add to environment if not already present (spack add is idempotent)
        if [ "$sv" = "dev-omp" ] || [[ "$sv" == *"+openmp"* ]]; then
            SPEC_TO_ADD="smoke@=${sv%%+*}+openmp"
        else
            SPEC_TO_ADD="smoke@=${sv%%~*}~openmp"
        fi
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "${SPEC_TO_ADD}" %gcc@${GCC_VER}
    done
    
    log "Installing packages (rebuilding only flagged packages)..."
    env PATH="$SAFE_PATH" TERM=dumb \
        spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null

    log "Creating stable symlinks in ${MY_INSTALL_ROOT}..."
    if [ -d "${MY_INSTALL_ROOT}" ]; then
        pushd "${MY_INSTALL_ROOT}" > /dev/null
        
        # 1. Symlinks for IOAPI (+/-openmp variants)
        for var in "~openmp" "+openmp"; do
            IOAPI_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i ioapi${var} %gcc@${GCC_VER} 2>/dev/null || true)
            if [ -n "$IOAPI_PATHS" ]; then
                # Use mapfile to safely split newline-separated paths (handles spaces in paths)
                mapfile -t IOAPI_PATH_ARR <<< "$IOAPI_PATHS"
                I_PATH=$(ls -dt "${IOAPI_PATH_ARR[@]}" 2>/dev/null | head -n 1)
                I_DIR=$(basename "$I_PATH")
                STABLE_NAME="ioapi"
                [ "$var" = "+openmp" ] && STABLE_NAME="ioapi-omp"
                ln -sfn "$I_DIR" "$STABLE_NAME"
                log "  Created symlink: ${STABLE_NAME} -> ${I_DIR}"
            fi
        done

        # 2. Symlinks for SMOKE (explicitly for each requested version)
        for sv in ${SMOKE_VERSION}; do
            # Resolve the spec matching the installation
            if [ "$sv" = "dev-omp" ] || [[ "$sv" == *"+openmp"* ]]; then
                SPEC_TO_LINK="smoke@=${sv%%+*}+openmp"
            else
                SPEC_TO_LINK="smoke@=${sv%%~*}~openmp"
            fi

            S_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i "${SPEC_TO_LINK}" %gcc@${GCC_VER} 2>/dev/null || true)
            if [ -n "$S_PATHS" ]; then
                # Use mapfile to safely split newline-separated paths (handles spaces in paths)
                mapfile -t S_PATH_ARR <<< "$S_PATHS"
                S_PATH=$(ls -dt "${S_PATH_ARR[@]}" 2>/dev/null | head -n 1)
                S_DIR=$(basename "$S_PATH")
                # Stable name is name-version (e.g., smoke-dev), stripping compiler and hash
                S_STABLE=$(echo "$S_DIR" | sed -E 's/-[^-]+-[a-z0-9]{7,}$//')
                if [ "$S_STABLE" != "$S_DIR" ]; then
                    ln -sfn "$S_DIR" "$S_STABLE"
                    log "  Created symlink for ${sv}: ${S_STABLE} -> ${S_DIR}"
                else
                    log "  Warning: Could not determine stable symlink name from '${S_DIR}' (regex matched nothing)"
                fi
            else
                log "  Warning: Could not locate installation path for ${SPEC_TO_LINK}"
            fi
        done
        popd > /dev/null
    fi
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

log "Spack-Driven Unified GCC Enclave Build Complete!"
log "Authoritative Enclave: ${MY_INSTALL_ROOT}"
log "Foundation Layer: ${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"

