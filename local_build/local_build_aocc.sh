#!/bin/bash
# Optimized for Portability and AOCC Performance using specialized project recipes

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
COMPILER_NAME="aocc"
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
SPACK_GCC_PATH="${PROJECT_ROOT}/gcc-latest"
GCC_VER="14.3.0"
AOCC_PREFIX="${PROJECT_ROOT}/aocc-latest"

# --- 1a. Toolchain Validation ---
if [ ! -d "${SPACK_GCC_PATH}" ]; then
    log "ERROR: GCC 14 Toolchain NOT found at ${SPACK_GCC_PATH}"
    log "Please run: ./build_foundation_gcc.sh"
    exit 1
fi

if [ ! -d "${AOCC_PREFIX}" ]; then
    log "ERROR: AOCC 5.1.0 Toolchain NOT found at ${AOCC_PREFIX}"
    log "Please run: ./build_foundation_aocc.sh"
    exit 1
fi

log "Toolchain validation successful."

if [ "$CLEAN_BUILD" = true ]; then
    log "Performing clean build reset..."
    rm -rf "${MY_INSTALL_ROOT}"
    rm -rf "${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}" "${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    log "Removing Spack environment: ${ENV_NAME}"
    rm -rf "${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
fi

# --- 2. Initialize Spack & Build Foundations ---
if [ ! -d "${SPACK_ROOT}" ]; then
    log "Spack not found at ${SPACK_ROOT}. Cloning fresh Spack..."
    git clone -b releases/latest https://github.com/spack/spack.git "${SPACK_ROOT}"
fi

# NOTE: External spack-packages repository is bypassed in V2
# if [ ! -d "${PROJECT_ROOT}/spack-packages" ]; then
#     log "Cloning additional spack-packages repository..."
#     git clone -b develop https://github.com/spack/spack-packages.git "${PROJECT_ROOT}/spack-packages"
# fi

if [ -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
    source "${SPACK_ROOT}/share/spack/setup-env.sh"
    export SPACK_DISABLE_LOCAL_CONFIG=1
    
    # Isolate site-level configuration to prevent leaks from problematic site/packages.yaml
    export SPACK_SYSTEM_CONFIG_PATH="${PROJECT_ROOT}/.spack_site_config_empty"
    mkdir -p "${SPACK_SYSTEM_CONFIG_PATH}"
    
    export SPACK_USER_CACHE_PATH="${PROJECT_ROOT}/.spack_cache_${ENCLAVE_SUFFIX}"
    export SPACK_USER_CONFIG_PATH="${PROJECT_ROOT}/.spack_config_${ENCLAVE_SUFFIX}"
    mkdir -p "${SPACK_USER_CACHE_PATH}" "${SPACK_USER_CONFIG_PATH}"
    
    # Ensure our custom repo is added (priority for our local recipes)
    if ! spack -C "${SPACK_USER_CONFIG_PATH}" repo list | grep -q "smoke_v52"; then
        log "Adding authoritative local package repository..."
        spack -C "${SPACK_USER_CONFIG_PATH}" repo add "${PROJECT_ROOT}/packages" || true
    fi

    log "Configuring enclave install path and local build stage..."
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/config.yaml"
config:
  install_tree:
    root: "$MY_INSTALL_ROOT"
    projections:
      all: "{name}-{version}-{compiler.name}-{hash:7}"
  build_stage:
    - "$PROJECT_ROOT/spack-stage"
EOF
    
    # 1. Register existing AOCC and GCC as compilers
    log "Registering existing AOCC and GCC toolchains..."
    
    # Detect architecture for manual compiler config
    SPACK_TARGET=$(spack -C "${SPACK_USER_CONFIG_PATH}" arch -t)
    SPACK_OS=$(spack -C "${SPACK_USER_CONFIG_PATH}" arch -o)
    
    cat > "${SPACK_USER_CONFIG_PATH}/compilers.yaml" <<EOF
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
- compiler:
    spec: aocc@5.1.0
    paths:
      cc: ${AOCC_PREFIX}/bin/clang
      cxx: ${AOCC_PREFIX}/bin/clang++
      f77: ${AOCC_PREFIX}/bin/flang
      fc: ${AOCC_PREFIX}/bin/flang
    flags: {}
    operating_system: ${SPACK_OS}
    target: ${SPACK_TARGET}
    modules: []
    environment: {}
    extra_rpaths: []
EOF

    # 1b. Exclude the 'aocc' package to avoid concretization conflict with the compiler
    # We must do this at the environment level to override any site/user externals
    log "Enforcing enclave policy: Ignoring 'aocc' package..."
    
    # Create/Re-create environment to clear stale metadata
    if spack -C "${SPACK_USER_CONFIG_PATH}" env list | grep -q "${ENV_NAME}"; then
        log "Purging stale Spack environment: ${ENV_NAME}"
        spack -C "${SPACK_USER_CONFIG_PATH}" env remove -y "${ENV_NAME}" || true
    fi
    
    log "Initializing fresh Spack environment: ${ENV_NAME}"
    # Mask host compilers from Spack's discovery path early
    SAFE_PATH=$(echo "$PATH" | tr ":" "\n" | grep -vE "gcc|llvm|aocc|intel" | tr "\n" ":" | sed 's/:$//')

    log "Identifying system build tools (cmake, gmake, etc.)..."
    env PATH="$SAFE_PATH" spack -C "${SPACK_USER_CONFIG_PATH}" external find --scope site cmake gmake pkgconf autoconf automake m4 libtool perl python
    
    spack -C "${SPACK_USER_CONFIG_PATH}" env create "${ENV_NAME}"
    
    log "Configuring spack.yaml for AOCC enclave..."
    ENV_DIR="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
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
  - compiler:
      spec: aocc@5.1.0
      paths:
        cc: ${AOCC_PREFIX}/bin/clang
        cxx: ${AOCC_PREFIX}/bin/clang++
        f77: ${AOCC_PREFIX}/bin/flang
        fc: ${AOCC_PREFIX}/bin/flang
      operating_system: ${SPACK_OS}
      target: ${SPACK_TARGET}
      modules: []
      environment: {}
      extra_rpaths: []
  packages:
    all:
      require: "%aocc@5.1.0"
      providers:
        c: [gcc]
        cxx: [gcc]
        fortran: [gcc]
    aocc:
      buildable: false
      externals: []
    gcc:
      externals: []
      buildable: false
    llvm:
      buildable: false
    intel-oneapi-compilers:
      buildable: false
  specs: []
  view: true
  concretizer:
    unify: when_possible
EOF
    
    # 6. Build foundations (skip if only rebuilding IOAPI or SMOKE)
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Building foundation layer (curl, zlib, hdf5, netcdf-c, netcdf-fortran)..."
        # Ensure foundations are installed with AOCC via local recipes
        # Note: Using variants that match 'ioapi' and 'smoke' requirements to avoid redundant builds
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add curl %aocc@5.1.0
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add zlib %aocc@5.1.0
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add hdf5+shared~mpi+cxx+fortran+hl %aocc@5.1.0
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-c~mpi+shared~dap %aocc@5.1.0
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-fortran+shared %aocc@5.1.0
        
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
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %aocc@5.1.0
    fi
    if [ "$REBUILD_SMOKE" = true ]; then
        log "Forcing SMOKE rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove smoke >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y smoke >/dev/null 2>&1 || true
        log "Re-adding SMOKE version ${SMOKE_VERSION}..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %aocc@5.1.0
    fi
    
    # If no rebuild flags, ensure both are in specs
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Ensuring IOAPI and SMOKE are in environment..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi %aocc@5.1.0
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add smoke@${SMOKE_VERSION} %aocc@5.1.0
    fi
    
    log "Installing packages (rebuilding only flagged packages)..."
    env PATH="$SAFE_PATH" TERM=dumb \
        spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

log "Spack-Driven Unified AOCC Enclave Build Complete!"
log "Authoritative Enclave: ${MY_INSTALL_ROOT}"
log "Foundation Layer: ${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"

