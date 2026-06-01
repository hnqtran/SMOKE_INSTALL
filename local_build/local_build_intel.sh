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
SMOKE_VERSION_EXPLICIT=false
SMOKE_COMPONENTS=""
REBUILD_IOAPI_LARGE=false

for arg in "$@"; do
    case $arg in
        --rebuild) CLEAN_BUILD=true ;;
        --ioapi) REBUILD_IOAPI=true ;;
        --ioapi-large) REBUILD_IOAPI_LARGE=true ;;
        --smoke) REBUILD_SMOKE=true ;;
        --smoke-version=*) SMOKE_VERSION="${arg#*=}"; SMOKE_VERSION_EXPLICIT=true ;;
        --smoke-*)
            component="${arg#--smoke-}"
            if [ "$component" != "version" ]; then
                SMOKE_COMPONENTS="${SMOKE_COMPONENTS} ${component}"
            fi
            ;;
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
log "Using SMOKE version: ${SMOKE_VERSION}"

# If --smoke-version was explicitly specified, automatically trigger rebuild
if [ "$SMOKE_VERSION_EXPLICIT" = true ]; then
    log "Explicit SMOKE version specified: automatically enabling rebuild..."
    REBUILD_SMOKE=true
fi

# Purge stale git archive cache when building dev versions,
# so Spack re-archives from current SMOKE_MASTER HEAD instead of a stale snapshot.
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
# CUSTOMIZE: Update this path to point to your pre-installed Intel oneAPI compiler
# Default: Uses symlink in PROJECT_ROOT (e.g., ${PROJECT_ROOT}/intel-latest)
# Alternative: Set to absolute path like /opt/intel/oneapi or /usr/local/intel-2025.3.2
INTEL_PREFIX="${PROJECT_ROOT}/intel-latest"

# Extract version from compiler binary output
INTEL_VER=$("${INTEL_PREFIX}/bin/icx" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "2025.3.2")
# Extract major.minor for path construction (e.g., "2025.3" from "2025.3.2")
INTEL_VER_MM=$(echo "${INTEL_VER}" | cut -d. -f1-2)

log "Detected Intel oneAPI version: ${INTEL_VER}"
if [ ! -d "${INTEL_PREFIX}" ]; then
    log "ERROR: Intel oneAPI Toolchain NOT found at ${INTEL_PREFIX}"
    log "Please run: ./build_foundation_intel.sh"
    exit 1
fi

log "Toolchain validation successful."

# --- 2. Isolation Strategy (Hermetic Enclave) ---
# We force Spack to ignore ALL site and user configurations to avoid conflicts.
export SPACK_DISABLE_LOCAL_CONFIG=1

# Isolate site-level configuration to prevent leaks from problematic site/packages.yaml
export SPACK_SYSTEM_CONFIG_PATH="${PROJECT_ROOT}/.spack_site_config_empty"
mkdir -p "${SPACK_SYSTEM_CONFIG_PATH}"

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
      smoke: "{name}-{version}{package.omp_suffix}-{compiler.name}-{hash:7}"
      all: "{name}-{version}-{compiler.name}-{hash:7}"
  build_stage:
    - "$PROJECT_ROOT/spack-stage"
EOF
    
    # 4. Manual Toolchain Registration (Deterministic)
    log "Registering existing Intel toolchains..."
    # We do NOT use 'spack compiler find' to avoid discovery of problematic site compilers.
    # We hard-code the compilers.yaml for absolute reproducibility.
    INTEL_BIN_DIR="${INTEL_PREFIX}/compiler/${INTEL_VER_MM}/bin"
    cat <<EOF > "${SPACK_USER_CONFIG_PATH}/compilers.yaml"
compilers:
- compiler:
    spec: oneapi@${INTEL_VER}
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
    # Only attempt removal if we didn't already do a clean reset (which already deleted the environment)
    if [ "$CLEAN_BUILD" = true ] && spack -C "${SPACK_USER_CONFIG_PATH}" env list | grep -q "${ENV_NAME}"; then
        log "Purging stale Spack environment: ${ENV_NAME}"
        spack -C "${SPACK_USER_CONFIG_PATH}" env remove -y "${ENV_NAME}" || true
        sleep 1  # Give Spack time to release locks and clean up
    fi
    # Mask host compilers from Spack's discovery path early
    SAFE_PATH=$(echo "$PATH" | tr ":" "\n" | grep -vE "gcc|llvm|aocc|intel" | tr "\n" ":" | sed 's/:$//')

    log "Identifying system build tools (cmake, gmake, etc.)..."
    env PATH="$SAFE_PATH" spack -C "${SPACK_USER_CONFIG_PATH}" external find --scope site cmake gmake pkgconf autoconf automake m4 libtool perl python
    
    log "Initializing fresh Spack environment: ${ENV_NAME}"
    # Only create if it doesn't exist after cleanup attempt
    if ! spack -C "${SPACK_USER_CONFIG_PATH}" env list | grep -q "${ENV_NAME}"; then
        spack -C "${SPACK_USER_CONFIG_PATH}" env create "${ENV_NAME}"
    fi
    
    # Register compilers and packages in spack.yaml for better isolation
    log "Configuring spack.yaml for Intel enclave..."
    ENV_DIR="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}"
    mkdir -p "${ENV_DIR}"
    cat <<EOF > "${ENV_DIR}/spack.yaml"
spack:
  compilers:
  - compiler:
      spec: oneapi@${INTEL_VER}
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
    all:
      require: "%oneapi@${INTEL_VER}"
    intel-oneapi-compilers:
      externals:
      - spec: intel-oneapi-compilers@${INTEL_VER}
        prefix: ${INTEL_PREFIX}
        extra_attributes:
          compilers:
            c: ${INTEL_PREFIX}/compiler/${INTEL_VER_MM}/bin/icx
            cxx: ${INTEL_PREFIX}/compiler/${INTEL_VER_MM}/bin/icpx
            fortran: ${INTEL_PREFIX}/compiler/${INTEL_VER_MM}/bin/ifx
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
  view:
    default:
      root: .spack-env/view
      projections:
        smoke: '{name}-{version}{package.omp_suffix}'
        all: '{name}-{version}'
  concretizer:
    unify: true
    reuse: false
EOF
    
    # 6. Build foundations (skip if only rebuilding IOAPI or SMOKE)
    if [ "$REBUILD_IOAPI" = false ] && [ "$REBUILD_SMOKE" = false ]; then
        log "Building foundation layer (curl, zlib, hdf5, netcdf-c, netcdf-fortran)..."
        # Ensure foundations are installed with Intel oneAPI via local recipes
        # Note: Using variants that match 'ioapi' and 'smoke' requirements to avoid redundant builds
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add curl %oneapi@${INTEL_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add zlib %oneapi@${INTEL_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add libaec %oneapi@${INTEL_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add hdf5+shared~mpi+cxx+fortran+hl+szip %oneapi@${INTEL_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-c~mpi+shared~dap+szip %oneapi@${INTEL_VER}
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add netcdf-fortran+shared %oneapi@${INTEL_VER}
        
        log "Performing foundation installation (this may take time)..."
        env PATH="$SAFE_PATH" TERM=dumb \
            spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null
    else
        log "Skipping foundation build (using existing installations)..."
    fi
    
    # 7. Build IOAPI and SMOKE
    # Determine IOAPI variant based on SMOKE version
    IOAPI_VARIANT="~openmp"
    if [[ "${SMOKE_VERSION}" == *"dev-omp"* ]] || [[ "${SMOKE_VERSION}" == *"+openmp"* ]]; then
        IOAPI_VARIANT="+openmp"
    fi

    # Force selective rebuild by uninstalling and re-adding flagged packages
    if [ "$REBUILD_IOAPI" = true ]; then
        log "Forcing IOAPI rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove ioapi >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y ioapi >/dev/null 2>&1 || true
        log "Re-adding IOAPI with ${IOAPI_VARIANT}..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi${IOAPI_VARIANT} %oneapi@${INTEL_VER}
    fi
    if [ "$REBUILD_IOAPI_LARGE" = true ]; then
        log "Forcing IOAPI-large rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove "ioapi${IOAPI_VARIANT}+large" >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y "ioapi+large" >/dev/null 2>&1 || true
        log "Re-adding IOAPI-large with ${IOAPI_VARIANT}+large..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "ioapi${IOAPI_VARIANT}+large" %oneapi@${INTEL_VER}
    fi
    if [ "$REBUILD_SMOKE" = true ]; then
        log "Forcing SMOKE rebuild: removing from environment and uninstalling..."
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove smoke@=${SMOKE_VERSION} >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" uninstall -f -y --all smoke@=${SMOKE_VERSION} >/dev/null 2>&1 || true
        # Remove stale lock file so the concretizer re-solves from the updated spack.yaml
        rm -f "${ENV_DIR}/spack.lock"
        log "Re-adding SMOKE version ${SMOKE_VERSION}..."
        export SMOKE_BUILD_COMPONENTS="${SMOKE_COMPONENTS}"
        # Use @= (exact version) to prevent CLingo from satisfying @dev with a different version
        SMOKE_SPEC_REBUILD="smoke@=${SMOKE_VERSION}"
        if [[ ! "${SMOKE_VERSION}" =~ "+" ]] && [[ ! "${SMOKE_VERSION}" =~ "~" ]]; then
            if [ "${SMOKE_VERSION}" = "dev-omp" ]; then
                SMOKE_SPEC_REBUILD="smoke@=${SMOKE_VERSION}+openmp"
            else
                SMOKE_SPEC_REBUILD="smoke@=${SMOKE_VERSION}~openmp"
            fi
        fi
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "${SMOKE_SPEC_REBUILD}" %oneapi@${INTEL_VER}
    fi

    # Ensure specified versions are added to the environment
    # We remove existing entries first to ensure variant changes (like switching from +openmp to ~openmp) are respected.
    log "Ensuring IOAPI and SMOKE are in environment..."
    spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add ioapi${IOAPI_VARIANT} %oneapi@${INTEL_VER}
    if [ "$REBUILD_IOAPI_LARGE" = true ]; then
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "ioapi${IOAPI_VARIANT}+large" %oneapi@${INTEL_VER}
    fi
    export SMOKE_BUILD_COMPONENTS="${SMOKE_COMPONENTS}"
    for sv in ${SMOKE_VERSION}; do
        # Remove existing entries for THIS specific version to ensure variant changes
        # (like switching from +openmp to ~openmp) are respected.
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove "smoke@=${sv%%+*}" >/dev/null 2>&1 || true
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" remove "smoke@=${sv%%~*}" >/dev/null 2>&1 || true

        # If no variant (+/-) is specified in the version string, explicitly append ~openmp
        # to prevent Spack from defaulting to an existing +openmp installation.
        # Use @= (exact version) to prevent CLingo from satisfying @dev with a different version.
        if [ "$sv" = "dev-omp" ] || [[ "$sv" == *"+openmp"* ]]; then
            SPEC_TO_ADD="smoke@=${sv%%+*}+openmp"
        else
            SPEC_TO_ADD="smoke@=${sv%%~*}~openmp"
        fi
        spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" add "${SPEC_TO_ADD}" %oneapi@${INTEL_VER}
    done
    
    log "Installing packages (rebuilding only flagged packages)..."
    env PATH="$SAFE_PATH" TERM=dumb \
        spack -C "${SPACK_USER_CONFIG_PATH}" --no-color -e "${ENV_NAME}" install --fail-fast < /dev/null

    log "Creating stable symlinks in ${MY_INSTALL_ROOT}..."
    if [ -d "${MY_INSTALL_ROOT}" ]; then
        pushd "${MY_INSTALL_ROOT}" > /dev/null
        
        # 1. Symlink for IOAPI (simple "ioapi" link to the latest build)
        IOAPI_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i ioapi %oneapi@${INTEL_VER} 2>/dev/null || true)
        if [ -n "$IOAPI_PATHS" ]; then
            # Use mapfile to safely split newline-separated paths (handles spaces in paths)
            mapfile -t IOAPI_PATH_ARR <<< "$IOAPI_PATHS"
            I_PATH=$(ls -dt "${IOAPI_PATH_ARR[@]}" 2>/dev/null | head -n 1)
            I_DIR=$(basename "$I_PATH")
            IOAPI_LINK_NAME="ioapi"
            if [ "${IOAPI_VARIANT}" = "+openmp" ]; then
                IOAPI_LINK_NAME="ioapi-omp"
            fi
            ln -sfn "$I_DIR" "${IOAPI_LINK_NAME}"
            log "  Created simple symlink: ${IOAPI_LINK_NAME} -> ${I_DIR}"
        fi

        # 1b. Symlink for IOAPI-large (only when --ioapi-large was requested)
        if [ "$REBUILD_IOAPI_LARGE" = true ]; then
            IOAPI_LARGE_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i "ioapi+large" %oneapi@${INTEL_VER} 2>/dev/null || true)
            if [ -n "$IOAPI_LARGE_PATHS" ]; then
                mapfile -t IOAPI_LARGE_PATH_ARR <<< "$IOAPI_LARGE_PATHS"
                IL_PATH=$(ls -dt "${IOAPI_LARGE_PATH_ARR[@]}" 2>/dev/null | head -n 1)
                IL_DIR=$(basename "$IL_PATH")
                IOAPI_LARGE_LINK_NAME="ioapi-large"
                if [ "${IOAPI_VARIANT}" = "+openmp" ]; then
                    IOAPI_LARGE_LINK_NAME="ioapi-omp-large"
                fi
                ln -sfn "$IL_DIR" "${IOAPI_LARGE_LINK_NAME}"
                log "  Created simple symlink: ${IOAPI_LARGE_LINK_NAME} -> ${IL_DIR}"
            fi
        fi

        # 2. Symlinks for SMOKE (explicitly for each requested version)
        for sv in ${SMOKE_VERSION}; do
            # Resolve the spec matching the installation
            SPEC_TO_LINK="smoke@=${sv}"
            if [[ ! "$sv" =~ "+" ]] && [[ ! "$sv" =~ "~" ]]; then
                if [ "$sv" = "dev-omp" ]; then SPEC_TO_LINK="smoke@=${sv}+openmp"
                else SPEC_TO_LINK="smoke@=${sv}~openmp"; fi
            fi

            S_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i "${SPEC_TO_LINK}" %oneapi@${INTEL_VER} 2>/dev/null || true)
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

        # 3. Symlinks for foundation libraries (hdf5, netcdf-c, netcdf-fortran)
        for pkg in hdf5 netcdf-c netcdf-fortran; do
            P_PATHS=$(spack -C "${SPACK_USER_CONFIG_PATH}" -e "${ENV_NAME}" location -i "${pkg}" %oneapi@${INTEL_VER} 2>/dev/null || true)
            if [ -n "$P_PATHS" ]; then
                mapfile -t P_PATH_ARR <<< "$P_PATHS"
                P_PATH=$(ls -dt "${P_PATH_ARR[@]}" 2>/dev/null | head -n 1)
                P_DIR=$(basename "$P_PATH")
                P_STABLE=$(echo "$P_DIR" | sed -E 's/-[^-]+-[a-z0-9]{7,}$//')
                if [ "$P_STABLE" != "$P_DIR" ]; then
                    ln -sfn "$P_DIR" "$P_STABLE"
                    log "  Created symlink for ${pkg}: ${P_STABLE} -> ${P_DIR}"
                else
                    log "  Warning: Could not determine stable symlink name from '${P_DIR}' (regex matched nothing)"
                fi
            else
                log "  Warning: Could not locate installation path for ${pkg}"
            fi
        done
        popd > /dev/null
    fi
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

log "Spack-Driven Unified Intel Enclave Build Complete!"
log "Authoritative Enclave: ${MY_INSTALL_ROOT}"
log "Foundation Layer: ${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"
