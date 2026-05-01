#!/bin/bash
# local_build_intel_v2.sh - Spack-Driven Intel oneAPI Unified Enclave (V2)
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
        --ioapi) REBUILD_IOAPI=true ;;
        --smoke) REBUILD_SMOKE=true ;;
        --smoke-version=*) SMOKE_VERSION="${arg#*=}" ;;
    esac
done

# --- 0a. Dynamic Enclave Variables ---
COMPILER_NAME="intel"
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

# --- 1b. Expected toolchain locations (via stable symlinks) ---
INTEL_PREFIX="${PROJECT_ROOT}/intel-latest"

# --- 1a. Toolchain Validation ---
if [ ! -d "${INTEL_PREFIX}" ]; then
    log "ERROR: Intel oneAPI Toolchain NOT found at ${INTEL_PREFIX}"
    log "Please run: ./build_foundation_intel.sh"
    exit 1
fi

log "Toolchain validation successful."

# --- 2. Isolation Strategy (Hermetic Enclave) ---
# We force Spack to ignore ALL site and user configurations to avoid conflicts.
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}"
export SPACK_USER_CONFIG_PATH="${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"

mkdir -p "${SPACK_USER_CACHE_PATH}" "${SPACK_USER_CONFIG_PATH}"

if [ "$CLEAN_BUILD" = true ]; then
    log "Performing clean build reset..."
    rm -rf "${MY_INSTALL_ROOT}"
    rm -rf "${SPACK_USER_CACHE_PATH}" "${SPACK_USER_CONFIG_PATH}"
    mkdir -p "${SPACK_USER_CACHE_PATH}" "${SPACK_USER_CONFIG_PATH}"
    log "Removing Spack environment: ${ENV_NAME}"
    rm -rf "${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
fi

# --- 3. Initialize Spack ---
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
    
    # 4. Manual Toolchain Registration (Deterministic)
    log "Registering existing Intel toolchains..."
    # We do NOT use 'spack compiler find' to avoid discovery of problematic site compilers.
    # We hard-code the compilers.yaml for absolute reproducibility.
    INTEL_BIN_DIR="${INTEL_PREFIX}/compiler/2025.3/bin"
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/compilers.yaml"
compilers:
- compiler:
    spec: oneapi@2025.3.2
    paths:
      cc: ${INTEL_BIN_DIR}/icx
      cxx: ${INTEL_BIN_DIR}/icpx
      f77: ${INTEL_BIN_DIR}/ifx
      fc: ${INTEL_BIN_DIR}/ifx
    operating_system: ${DETECTED_OS}
    target: ${DETECTED_TARGET}
    modules: []
    environment: {}
    flags: {}
    extra_rpaths: []
EOF

    # 5. Environment Orchestration
    log "Purging stale Spack environment: ${ENV_NAME}"
    spack -C "${SPACK_USER_CONFIG_PATH}" env remove -y "${ENV_NAME}" || true
    # Mask host compilers from Spack's discovery path early
    SAFE_PATH=$(echo "$PATH" | tr ":" "\n" | grep -vE "gcc|llvm|aocc" | tr "\n" ":" | sed 's/:$//')

    log "Identifying system build tools (cmake, gmake, etc.)..."
    env PATH="$SAFE_PATH" spack -C "${SPACK_USER_CONFIG_PATH}" external find --scope site cmake gmake pkgconf autoconf automake m4 libtool perl python
    
    log "Initializing fresh Spack environment: ${ENV_NAME}"
    spack -C "${SPACK_USER_CONFIG_PATH}" env create "${ENV_NAME}"
    
    # Register compilers and packages in spack.yaml for better isolation
    log "Configuring spack.yaml for Intel enclave..."
    ENV_DIR="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
  compilers:
  - compiler:
      spec: oneapi@2025.3.2
      paths:
        cc: ${INTEL_BIN_DIR}/icx
        cxx: ${INTEL_BIN_DIR}/icpx
        f77: ${INTEL_BIN_DIR}/ifx
        fc: ${INTEL_BIN_DIR}/ifx
      operating_system: ${DETECTED_OS}
      target: ${DETECTED_TARGET}
      modules: []
      environment: {}
      flags: {}
      extra_rpaths: []
  packages:
    intel-oneapi-compilers:
      externals:
      - spec: intel-oneapi-compilers@2025.3.2
        prefix: ${INTEL_PREFIX}
        extra_attributes:
          compilers:
            c: ${INTEL_PREFIX}/compiler/2025.3/bin/icx
            cxx: ${INTEL_PREFIX}/compiler/2025.3/bin/icpx
            fortran: ${INTEL_PREFIX}/compiler/2025.3/bin/ifx
      buildable: false
    #We do NOT register the runtime as external to avoid conflicts with Spack's internal dependency resolution and to ensure we get the correct variants for our foundations.
    #intel-oneapi-runtime:
    #  externals:
    #  - spec: intel-oneapi-runtime@2025.3.2
    #    prefix: ${INTEL_PREFIX}/compiler/2025.3
    #  buildable: false
    gcc:
      externals: []
      buildable: false
    llvm:
      buildable: false
    aocc:
      buildable: false
  specs: []
  view: true
  concretizer:
    unify: true
EOF
    
    # 6. Build foundations (skip if only rebuilding IOAPI or SMOKE)
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Building foundation layer (curl, zlib, hdf5, netcdf-c, netcdf-fortran)..."
        # Ensure foundations are installed with Intel oneAPI via local recipes
        # Note: Using variants that match 'ioapi' and 'smoke' requirements to avoid redundant builds
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add curl %oneapi@2025.3.2
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add zlib %oneapi@2025.3.2
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add hdf5+shared~mpi+cxx+fortran+hl %oneapi@2025.3.2
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-c~mpi+shared~dap %oneapi@2025.3.2
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-fortran+shared %oneapi@2025.3.2
        
        log "Performing foundation installation (this may take time)..."
        env PATH="$SAFE_PATH" TERM=dumb \
            spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
    else
        log "Skipping foundation build (using existing installations)..."
    fi
    
    # 7. Build IOAPI and SMOKE
    # Force selective rebuild by uninstalling and re-adding flagged packages
    if [ "$REBUILD_IOAPI" = true ]; then
        log "Forcing IOAPI rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove ioapi >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y ioapi >/dev/null 2>&1 || true
        log "Re-adding IOAPI..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %oneapi@2025.3.2
    fi
    if [ "$REBUILD_SMOKE" = true ]; then
        log "Forcing SMOKE rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove smoke >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y smoke >/dev/null 2>&1 || true
        log "Re-adding SMOKE version ${SMOKE_VERSION}..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %oneapi@2025.3.2
    fi
    
    # If no rebuild flags, ensure both are in specs
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Ensuring IOAPI and SMOKE are in environment..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %oneapi@2025.3.2
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %oneapi@2025.3.2
    fi
    
    log "Installing packages (rebuilding only flagged packages)..."
    env PATH="$SAFE_PATH" TERM=dumb \
        spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

log "Spack-Driven Unified Intel Enclave Build Complete!"
log "Authoritative Enclave: ${MY_INSTALL_ROOT}"
log "Foundation Layer: ${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"
