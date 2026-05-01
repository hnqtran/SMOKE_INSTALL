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

for arg in "$@"; do
    case $arg in
        --rebuild) CLEAN_BUILD=true ;;
        --ioapi)       REBUILD_IOAPI=true ;;
        --smoke)       REBUILD_SMOKE=true ;;
        --smoke-version=*) SMOKE_VERSION="${arg#*=}" ;;
    esac
done

# --- 0a. Dynamic Enclave Variables ---
PROJECT_ROOT="$PWD"
SPACK_ROOT="${PROJECT_ROOT}/spack"

# Dynamic enclave naming
COMPILER_NAME="gcc"
ENCLAVE_SUFFIX="${COMPILER_NAME}_enclave"
STACK_SUFFIX="${COMPILER_NAME}"

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

# --- 1b. Expected toolchain locations (via stable symlinks) ---
SPACK_GCC_PATH="${PROJECT_ROOT}/gcc-latest"
GCC_VER="14.3.0"

# --- 1a. Toolchain Validation ---
if [ ! -d "${SPACK_GCC_PATH}" ]; then
    log "ERROR: GCC Toolchain NOT found at ${SPACK_GCC_PATH}"
    log "Please run: ./build_foundation_gcc.sh"
    exit 1
fi

log "Toolchain validation successful."

if [ "$CLEAN_BUILD" = true ]; then
    log "Performing clean build reset..."
    rm -rf "${MY_INSTALL_ROOT}"
    rm -rf "${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}" "${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    mkdir -p "${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}" "${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
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
    
    log "Detecting local system architecture..."
    DETECTED_OS=$(spack arch --operating-system)
    DETECTED_TARGET=$(spack arch --target)
    log "Detected OS: ${DETECTED_OS}, Target: ${DETECTED_TARGET}"

    # --- 2a. Isolation Strategy (Hermetic Enclave) ---
    export SPACK_DISABLE_LOCAL_CONFIG=1
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
  install_missing_compilers: false
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
  build_stage:
    - "$PROJECT_ROOT/spack-stage"
EOF
    
    # 3. Manual Toolchain Registration (Deterministic)
    log "Registering existing GCC toolchain..."
    # We hard-code the compilers.yaml for absolute reproducibility.
    GCC_BIN_DIR="${SPACK_GCC_PATH}/bin"
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/compilers.yaml"
compilers:
- compiler:
    spec: gcc@${GCC_VER}
    paths:
      cc: ${GCC_BIN_DIR}/gcc
      cxx: ${GCC_BIN_DIR}/g++
      f77: ${GCC_BIN_DIR}/gfortran
      fc: ${GCC_BIN_DIR}/gfortran
    operating_system: ${DETECTED_OS}
    target: ${DETECTED_TARGET}
    modules: []
    environment: {}
    flags: {}
    extra_rpaths: []
EOF

    # 4. Environment Orchestration
    log "Purging stale Spack environment: ${ENV_NAME}"
    spack -C "${SPACK_USER_CONFIG_PATH}" env remove -y "${ENV_NAME}" || true
    # Mask host compilers from Spack's discovery path early
    SAFE_PATH=$(echo "$PATH" | tr ":" "\n" | grep -vE "gcc|llvm|aocc|intel" | tr "\n" ":" | sed 's/:$//')

    log "Identifying system build tools (cmake, gmake, etc.)..."
    env PATH="$SAFE_PATH" spack -C "${SPACK_USER_CONFIG_PATH}" external find --scope site cmake gmake pkgconf autoconf automake m4 libtool perl python
    
    log "Initializing fresh Spack environment: ${ENV_NAME}"
    spack -C "${SPACK_USER_CONFIG_PATH}" env create "${ENV_NAME}"
    
    # Register compilers and packages in spack.yaml for better isolation
    log "Configuring spack.yaml for GCC enclave..."
    ENV_DIR="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
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
      operating_system: ${DETECTED_OS}
      target: ${DETECTED_TARGET}
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
  view: true
  concretizer:
    unify: true
EOF
    
    # 5. Build foundations (skip if only rebuilding IOAPI or SMOKE)
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Building foundation layer (curl, zlib, hdf5, netcdf-c, netcdf-fortran)..."
        # Ensure foundations are installed with GCC via local recipes
        # Note: Using variants that match 'ioapi' and 'smoke' requirements to avoid redundant builds
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add curl %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add zlib %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add hdf5+shared~mpi+cxx+fortran+hl %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-c~mpi+shared~dap %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-fortran+shared %gcc@${GCC_VER}
        
        log "Performing foundation installation (this may take time)..."
        env PATH="$SAFE_PATH" TERM=dumb \
            spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
    else
        log "Skipping foundation build (using existing installations)..."
    fi
    
    # 6. Build IOAPI and SMOKE
    # Force selective rebuild by uninstalling and re-adding flagged packages
    if [ "$REBUILD_IOAPI" = true ]; then
        log "Forcing IOAPI rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove ioapi >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y ioapi >/dev/null 2>&1 || true
        log "Re-adding IOAPI..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %gcc@${GCC_VER}
    fi
    if [ "$REBUILD_SMOKE" = true ]; then
        log "Forcing SMOKE rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove smoke >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y smoke >/dev/null 2>&1 || true
        log "Re-adding SMOKE version ${SMOKE_VERSION}..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %gcc@${GCC_VER}
    fi
    
    # If no rebuild flags, ensure both are in specs
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Ensuring IOAPI and SMOKE are in environment..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %gcc@${GCC_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %gcc@${GCC_VER}
    fi
    
    log "Installing packages (rebuilding only flagged packages)..."
    env PATH="$SAFE_PATH" TERM=dumb \
        spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

log "Spack-Driven Unified GCC Enclave Build Complete!"
log "Authoritative Enclave: ${MY_INSTALL_ROOT}"
log "Foundation Layer: ${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"

