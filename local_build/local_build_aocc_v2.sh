#!/bin/bash
# local_build_aocc_v2.sh - Spack-Driven AOCC Unified Enclave
# Optimized for Portability and AOCC Performance

set -euo pipefail

log() { echo "==> $1"; }

# --- 0. Argument Parsing ---
CLEAN_BUILD=false
REBUILD_IOAPI=false
REBUILD_SMOKE=false

for arg in "$@"; do
    case $arg in
        --clean-build) CLEAN_BUILD=true ;;
        --ioapi)       REBUILD_IOAPI=true ;;
        --smoke)       REBUILD_SMOKE=true ;;
    esac
done

# --- 1. Paths & Versions ---
PROJECT_ROOT="$PWD"
SPACK_ROOT="${PROJECT_ROOT}/spack"
ENV_NAME="smoke-enclave"
MY_INSTALL_ROOT="${PROJECT_ROOT}/install_aocc_stack_v2"

# Expected toolchain locations (via stable symlinks)
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
    if [ -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
        source "${SPACK_ROOT}/share/spack/setup-env.sh"
        spack env remove -y "${ENV_NAME}" || true
        
        # Force fresh recompilation by wiping the Spack store and DB
        log "Wiping Spack store and database to force recompilation..."
        rm -rf "${SPACK_ROOT}/opt/spack"
        rm -rf "${SPACK_ROOT}/var/spack/cache"
        rm -f "${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/spack.lock"
    fi
fi

# --- 2. Initialize Spack & Build Foundations ---
if [ ! -d "${SPACK_ROOT}" ]; then
    log "Spack not found at ${SPACK_ROOT}. Cloning fresh Spack..."
    git clone -b releases/latest https://github.com/spack/spack.git "${SPACK_ROOT}"
fi

if [ ! -d "${PROJECT_ROOT}/spack-packages" ]; then
    log "Cloning additional spack-packages repository..."
    git clone -b develop https://github.com/spack/spack-packages.git "${PROJECT_ROOT}/spack-packages"
fi

if [ -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
    source "${SPACK_ROOT}/share/spack/setup-env.sh"
    
    # Ensure our custom repo is added
    if ! spack repo list | grep -q "spack-packages"; then
        log "Adding custom Spack repository..."
        spack repo add "${PROJECT_ROOT}/spack-packages/repos/spack_repo" || true
    fi
    
    # Create environment if it doesn't exist
    if ! spack env list | grep -q "${ENV_NAME}"; then
        log "Initializing Spack environment: ${ENV_NAME}"
        
        # 1. Register existing AOCC and GCC as compilers/externals
        log "Registering existing AOCC and GCC toolchains..."
        spack compiler find "${AOCC_PREFIX}"
        spack compiler find "${SPACK_GCC_PATH}"
        
        # 2. Find system build tools to avoid redundant builds
        log "Identifying system build tools (cmake, gmake, etc.)..."
        spack external find cmake gmake pkgconf autoconf automake m4 libtool perl python
        
        spack env create "${ENV_NAME}"
    fi
    
    spack env activate "${ENV_NAME}"
    
    # Ensure foundations are added and installed
    log "Ensuring foundations are installed with AOCC..."
    spack add curl %aocc@5.1.0 zlib %aocc@5.1.0 hdf5~mpi~fortran %aocc@5.1.0 netcdf-c %aocc@5.1.0
    spack install --fail-fast
else
    log "Error: Spack not found at ${SPACK_ROOT}"
    exit 1
fi

# The "view" directory is where Spack symlinks all libraries together
FOUNDATION_VIEW="${SPACK_ROOT}/var/spack/environments/${ENV_NAME}/.spack-env/view"
log "Using Spack Foundation View: ${FOUNDATION_VIEW}"

# --- 3. Toolchain Configuration ---
export BIN=Linux2_x86_64aoccflang
export CC="${AOCC_PREFIX}/bin/clang"
export CXX="${AOCC_PREFIX}/bin/clang++"
export FC="${AOCC_PREFIX}/bin/flang"
export F77="${AOCC_PREFIX}/bin/flang"

# Optimization flags for AOCC
export OPT_FLAGS="-O3 -march=native -mtune=native --gcc-toolchain=${SPACK_GCC_PATH} -B${SPACK_GCC_PATH}/lib/gcc/x86_64-pc-linux-gnu/${GCC_VER}"
export CFLAGS="$OPT_FLAGS -fPIC"
export CXXFLAGS="$OPT_FLAGS -fPIC"
export FFLAGS="$OPT_FLAGS -fPIC"

# Unified RPATHs including both the Spack View and GCC runtime
export BASE_LDFLAGS="-Wl,-rpath,${MY_INSTALL_ROOT}/lib -L${MY_INSTALL_ROOT}/lib -Wl,-rpath,${FOUNDATION_VIEW}/lib -Wl,-rpath,${FOUNDATION_VIEW}/lib64 -L${FOUNDATION_VIEW}/lib -L${FOUNDATION_VIEW}/lib64 -Wl,-rpath,${SPACK_GCC_PATH}/lib64 -L${SPACK_GCC_PATH}/lib64"
export LDFLAGS="${BASE_LDFLAGS}"
export CPPFLAGS="-I${FOUNDATION_VIEW}/include"

mkdir -p "$MY_INSTALL_ROOT/lib" "$MY_INSTALL_ROOT/include" "$MY_INSTALL_ROOT/bin"

# --- 4. NetCDF-Fortran (Manual Patching for libtool/soname) ---
if [ ! -f "$MY_INSTALL_ROOT/lib/libnetcdff.so" ]; then
    log "Compiling NetCDF-Fortran (with AOCC patches)..."
    cd "$MY_INSTALL_ROOT"
    rm -rf netcdf-fortran-4.6.1 netcdf-fortran-4.6.1.tar.gz
    wget https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v4.6.1.tar.gz -O netcdf-fortran-4.6.1.tar.gz
    tar -xf netcdf-fortran-4.6.1.tar.gz
    cd netcdf-fortran-4.6.1
    # Note: CPPFLAGS already includes the Foundation View
    ./configure --prefix="$MY_INSTALL_ROOT" --enable-shared --enable-static
    
    # Critical AOCC libtool fixes
    log "Applying AOCC libtool patches..."
    sed -i 's/wl=""/wl="-Wl,"/g' libtool
    sed -i 's/\$wl-soname \$wl\$soname/\$wl-soname,\$soname/g' libtool
    sed -i 's/\$wl--whole-archive \$wl/\$wl--whole-archive,/g' libtool
    sed -i 's/\$wl--no-whole-archive \$wl/\$wl--no-whole-archive,/g' libtool
    
    make -j$(nproc)
    make install
    cd "${PROJECT_ROOT}"
else
    log "NetCDF-Fortran already exists. Skipping."
fi

# --- 5. IOAPI & M3Tools ---
if [ "$REBUILD_IOAPI" = true ] || [ ! -f "$MY_INSTALL_ROOT/lib/libioapi.a" ]; then
    log "Compiling IOAPI & M3Tools..."
    cd "$MY_INSTALL_ROOT"
    if [ ! -d "ioapi_v32" ]; then
        git clone --depth 1 https://github.com/cjcoats/ioapi-3.2.git ioapi_v32
    fi
    cd ioapi_v32
    if [ "$REBUILD_IOAPI" = true ]; then
        log "Cleaning existing IOAPI/M3Tools build for ${BIN}..."
        rm -rf "${MY_INSTALL_ROOT}/ioapi_v32/${BIN}"
        rm -f "$MY_INSTALL_ROOT/lib/libioapi.a"
    fi
    mkdir -p "$BIN"
    
    # Inject toolchain paths into IOAPI Makeinclude
    sed -i "s|aocc = .*|aocc = $AOCC_PREFIX/bin|g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    sed -i "s|^ARCHFLAGS =|ARCHFLAGS = $OPT_FLAGS -fPIC |g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    sed -i "s|^ARCHLIB.*=.*|ARCHLIB = -lm -lpthread -lc|g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    
    cd ioapi
    sed -i "s|^BASEDIR.*=.*|BASEDIR = ..|g" Makefile.nocpl
    # Link against foundation view
    make -f Makefile.nocpl OBJDIR="${MY_INSTALL_ROOT}/ioapi_v32/${BIN}" BIN="${BIN}" \
         NETCDF_LIB="-L${FOUNDATION_VIEW}/lib -lnetcdf" \
         NETCDF_INC="-I${FOUNDATION_VIEW}/include"
    
    cp "../$BIN/libioapi.a" "$MY_INSTALL_ROOT/lib/"
    cp "../$BIN"/*.mod "$MY_INSTALL_ROOT/include/"
    
    cd ../m3tools
    sed -i "s|^BASEDIR.*=.*|BASEDIR = ..|g" Makefile.nocpl
    # Ensure m3tools links against both NetCDF-C and NetCDF-Fortran with RPATH
    sed -i "s|^ LIBS = .*| LIBS = -L\${OBJDIR} -lioapi -L$MY_INSTALL_ROOT/lib -lnetcdff ${BASE_LDFLAGS} -lnetcdf -lcurl \$(OMPLIBS) \$(ARCHLIB) \$(ARCHLIBS)|g" Makefile.nocpl
    
    make -f Makefile.nocpl OBJDIR="${MY_INSTALL_ROOT}/ioapi_v32/${BIN}" BIN="${BIN}" LFLAGS="${BASE_LDFLAGS}"
    cp "$MY_INSTALL_ROOT/ioapi_v32/$BIN"/* "$MY_INSTALL_ROOT/bin/" || true
    cd "${PROJECT_ROOT}"
else
    log "IOAPI/M3Tools already built. Skipping."
fi

# --- 6. SMOKE ---
if [ "$REBUILD_SMOKE" = true ] || [ ! -f "$MY_INSTALL_ROOT/bin/smkinven" ]; then
    log "Compiling SMOKE (AOCC Dynamic)..."
    cd "$MY_INSTALL_ROOT"
    if [ ! -d "smoke" ]; then
        git clone --depth 1 https://github.com/CEMPD/SMOKE.git smoke
    fi
    cd smoke/src
    git checkout Makefile Makeinclude
    
    export SMK_HOME="${MY_INSTALL_ROOT}/smoke"
    export IOBASE="${MY_INSTALL_ROOT}/ioapi_v32"
    export IODIR="${IOBASE}/ioapi"
    export IOBIN="${IOBASE}/${BIN}"
    export IOINC="${IODIR}/fixed_src"
    if [ "$REBUILD_SMOKE" = true ]; then
        log "Cleaning existing SMOKE build for ${BIN}..."
        rm -rf "${SMK_HOME}/${BIN}"
    fi
    mkdir -p "${SMK_HOME}/${BIN}"
    
    # Precision Patching for SMOKE Makeinclude
    sed -i "s|^BASEDIR.*=.*|BASEDIR = $PWD|g" Makeinclude
    sed -i "s|^IOBASE.*=.*|IOBASE = $IOBASE|g" Makeinclude
    sed -i "s|^ EFLAG.*=.*| EFLAG = -ffixed-line-length-132 -fno-backslash|g" Makeinclude
    # Inject both local NetCDF-Fortran and Spack Foundation paths
    sed -i "s|^LDFLAGS.*=.*|LDFLAGS = \${IFLAGS} \${DEFINEFLAGS} \${ARCHFLAGS} -L$MY_INSTALL_ROOT/lib -lnetcdff ${BASE_LDFLAGS} -lnetcdf -lcurl|g" Makeinclude
    
    unset LDFLAGS
    # Sequential make to ensure .mod file consistency
    make BIN=$BIN
    cp "$SMK_HOME/$BIN"/* "$MY_INSTALL_ROOT/bin/" || true
    cd "${PROJECT_ROOT}"
else
    log "SMOKE already built. Skipping."
fi

log "Spack-Driven Unified Enclave Build Complete!"
log "Authoritative Enclave: $MY_INSTALL_ROOT"
log "Foundation Layer: $FOUNDATION_VIEW"
