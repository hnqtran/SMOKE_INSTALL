#!/bin/bash
# local_build_aocc.sh - Hardened Hybrid AOCC Build (Dynamic Enclave)
set -euo pipefail

log() { echo "==> $1"; }

# --- 1. Environment Discovery ---
export SPACK_GCC_PATH="/proj/ie/proj/SMOKE/htran/SMOKE_SPACK/local_build/gcc_14/gcc-14.3.0-llvm-5ypbe3b"
export GCC_VER="14.3.0"

# --- 2. Stage 1: Legacy AOCC Bootstrap ---
if [ ! -L "aocc-latest" ]; then
    log "Stage 1: Bootstrapping AOCC using legacy engine..."
    chmod +x build_foundation_aocc.sh
    ./build_foundation_aocc.sh
else
    log "AOCC Toolchain already exists in aocc-latest. Skipping Stage 1."
fi

AOCC_PREFIX=$(readlink -f aocc-latest)
log "AOCC Toolchain established at $AOCC_PREFIX"

# --- 3. Stage 2: Unified Dynamic Enclave Build ---
export MY_INSTALL_ROOT="$PWD/install_aocc_stack"
mkdir -p "$MY_INSTALL_ROOT/lib" "$MY_INSTALL_ROOT/include" "$MY_INSTALL_ROOT/bin"

export BIN=Linux2_x86_64aoccflang
export CC="$AOCC_PREFIX/bin/clang"
export CXX="$AOCC_PREFIX/bin/clang++"
export FC="$AOCC_PREFIX/bin/flang"
export F77="$AOCC_PREFIX/bin/flang"

export OPT_FLAGS="-O3 -march=native -mtune=native --gcc-toolchain=${SPACK_GCC_PATH} -B${SPACK_GCC_PATH}/lib/gcc/x86_64-pc-linux-gnu/${GCC_VER}"
export CFLAGS="$OPT_FLAGS -fPIC"
export CXXFLAGS="$OPT_FLAGS -fPIC"
export FFLAGS="$OPT_FLAGS -fPIC"
export BASE_LDFLAGS="-L$MY_INSTALL_ROOT/lib -Wl,-rpath,$MY_INSTALL_ROOT/lib -L${SPACK_GCC_PATH}/lib64 -Wl,-rpath,${SPACK_GCC_PATH}/lib64"

# --- 4. HDF5 ---
if [ ! -f "$MY_INSTALL_ROOT/lib/libhdf5.so" ]; then
    log "Compiling HDF5..."
    cd "$MY_INSTALL_ROOT"
    rm -rf hdf5-hdf5-1_14_3 hdf5-1.14.3.tar.gz
    wget https://github.com/HDFGroup/hdf5/archive/refs/tags/hdf5-1_14_3.tar.gz -O hdf5-1.14.3.tar.gz
    tar -xf hdf5-1.14.3.tar.gz
    cd hdf5-hdf5-1_14_3
    ./configure --prefix="$MY_INSTALL_ROOT" --enable-fortran --enable-cxx --enable-shared --enable-static --without-szlib --disable-tests
    make -j$(nproc)
    make install
    cd ..
else
    log "HDF5 already exists. Skipping."
fi

# --- 5. NetCDF-C ---
if [ ! -f "$MY_INSTALL_ROOT/lib/libnetcdf.so" ]; then
    log "Compiling NetCDF-C..."
    cd "$MY_INSTALL_ROOT"
    rm -rf netcdf-c-4.9.2 netcdf-c-4.9.2.tar.gz
    wget https://github.com/Unidata/netcdf-c/archive/refs/tags/v4.9.2.tar.gz -O netcdf-c-4.9.2.tar.gz
    tar -xf netcdf-c-4.9.2.tar.gz
    cd netcdf-c-4.9.2
    CPPFLAGS="-I$MY_INSTALL_ROOT/include" ./configure --prefix="$MY_INSTALL_ROOT" --enable-shared --enable-static --disable-dap --disable-nczarr --disable-byterange --disable-s3
    make -j$(nproc)
    make install
    cd ..
else
    log "NetCDF-C already exists. Skipping."
fi

# --- 6. NetCDF-Fortran ---
if [ ! -f "$MY_INSTALL_ROOT/lib/libnetcdff.so" ]; then
    log "Compiling NetCDF-Fortran..."
    cd "$MY_INSTALL_ROOT"
    rm -rf netcdf-fortran-4.6.1 netcdf-fortran-4.6.1.tar.gz
    wget https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v4.6.1.tar.gz -O netcdf-fortran-4.6.1.tar.gz
    tar -xf netcdf-fortran-4.6.1.tar.gz
    cd netcdf-fortran-4.6.1
    LDFLAGS="$BASE_LDFLAGS" CPPFLAGS="-I$MY_INSTALL_ROOT/include" ./configure --prefix="$MY_INSTALL_ROOT" --enable-shared --enable-static
    sed -i 's/wl=""/wl="-Wl,"/g' libtool
    sed -i 's/\$wl-soname \$wl\$soname/\$wl-soname,\$soname/g' libtool
    sed -i 's/\$wl--whole-archive \$wl/\$wl--whole-archive,/g' libtool
    sed -i 's/\$wl--no-whole-archive \$wl/\$wl--no-whole-archive,/g' libtool
    make -j$(nproc)
    make install
    cd ..
else
    log "NetCDF-Fortran already exists. Skipping."
fi

# --- 7. IOAPI & M3Tools ---
if [ ! -f "$MY_INSTALL_ROOT/lib/libioapi.a" ]; then
    log "Compiling IOAPI & M3Tools..."
    cd "$MY_INSTALL_ROOT"
    if [ ! -d "ioapi_v32" ]; then
        git clone --depth 1 https://github.com/cjcoats/ioapi-3.2.git ioapi_v32
    fi
    cd ioapi_v32
    mkdir -p "$BIN"
    sed -i "s|aocc = .*|aocc = $AOCC_PREFIX/bin|g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    sed -i "s|^ARCHFLAGS =|ARCHFLAGS = $OPT_FLAGS -fPIC |g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    sed -i "s|^ARCHLIB.*=.*|ARCHLIB = -lm -lpthread -lc|g" ioapi/Makeinclude.Linux2_x86_64aoccflang
    cd ioapi
    sed -i "s|^BASEDIR.*=.*|BASEDIR = $(dirname "$PWD")|g" Makefile.nocpl
    make -f Makefile.nocpl OBJDIR="$MY_INSTALL_ROOT/ioapi_v32/$BIN" BIN="$BIN"
    cp "../$BIN/libioapi.a" "$MY_INSTALL_ROOT/lib/"
    cp "../$BIN"/*.mod "$MY_INSTALL_ROOT/include/"
    cd ../m3tools
    sed -i "s|^BASEDIR.*=.*|BASEDIR = $(dirname "$PWD")|g" Makefile.nocpl
    sed -i "s|^ LIBS = .*| LIBS = -L\${OBJDIR} -lioapi -lnetcdff -lnetcdf \$(OMPLIBS) \$(ARCHLIB) \$(ARCHLIBS)|g" Makefile.nocpl
    make -f Makefile.nocpl OBJDIR="$MY_INSTALL_ROOT/ioapi_v32/$BIN" BIN="$BIN" LFLAGS="$BASE_LDFLAGS"
    cp "$MY_INSTALL_ROOT/ioapi_v32/$BIN"/* "$MY_INSTALL_ROOT/bin/" || true
    cd ..
else
    log "IOAPI/M3Tools already built. Skipping."
fi

# --- 8. SMOKE ---
if [ ! -f "$MY_INSTALL_ROOT/bin/smkinven" ]; then
    log "Compiling SMOKE (Dynamic)..."
    cd "$MY_INSTALL_ROOT"
    if [ ! -d "smoke" ]; then
        git clone --depth 1 https://github.com/CEMPD/SMOKE.git smoke
    fi
    cd smoke/src
    git checkout Makefile Makeinclude
    
    export SMK_HOME="$(dirname "$PWD")"
    export IOBASE="$MY_INSTALL_ROOT/ioapi_v32"
    export IODIR="$IOBASE/ioapi"
    export IOBIN="$IOBASE/$BIN"
    export IOINC="$IODIR/fixed_src"
    mkdir -p "$SMK_HOME/$BIN"
    
    sed -i "s|^BASEDIR.*=.*|BASEDIR = $PWD|g" Makeinclude
    sed -i "s|^IOBASE.*=.*|IOBASE = $IOBASE|g" Makeinclude
    sed -i "s|^ EFLAG.*=.*| EFLAG = -ffixed-line-length-132 -fno-backslash|g" Makeinclude
    sed -i "s|^LDFLAGS.*=.*|LDFLAGS = \${IFLAGS} \${DEFINEFLAGS} \${ARCHFLAGS} $BASE_LDFLAGS|g" Makeinclude
    sed -i "s|^ARCHFLAGS.*=.*|ARCHFLAGS = $OPT_FLAGS -fPIC|g" $IODIR/Makeinclude.$BIN
    
    unset LDFLAGS
    make BIN=$BIN
    cp "$SMK_HOME/$BIN"/* "$MY_INSTALL_ROOT/bin/" || true
else
    log "SMOKE already built. Skipping."
fi

log "Dynamic Enclave Build Complete in $MY_INSTALL_ROOT"
