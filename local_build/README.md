# SMOKE Spack-Driven Local Build System

This directory contains the Spack-driven build engine for compiling the Sparse Matrix Operator Kernel Emissions (SMOKE) modeling system and its dependency, the Models-3 Input/Output Applications Programming Interface (I/O API), across three compiler toolchains: **GCC**, **Intel oneAPI**, and **AOCC**.

---

## Architecture Overview

The build process is divided into two logical phases:
1. **Foundation Bootstrapping (`build_foundation_*.sh`)**: Builds or registers the base compiler within a dedicated Spack configuration and symlinks the binaries locally.
2. **Enclave Building (`local_build_*.sh`)**: Creates isolated Spack environments (enclaves) using unique metadata and config directories to compile dependency libraries (HDF5, NetCDF) and build the final target binaries (`ioapi` and `smoke`).

---

## 1. Compiler Bootstrapping Scripts

Before compiling the modeling packages, you must bootstrap or link the compilers using the foundation scripts.

### GCC Foundation
*   **Script**: `build_foundation_gcc.sh`
*   **Description**: Builds a self-contained GCC 14 toolchain.
*   **Usage**:
    ```bash
    ./build_foundation_gcc.sh [custom_install_path] [--num-jobs=N]
    ```
*   **Output**: Symlinks to the compiler binaries are created at `./gcc-latest`.

### AOCC Foundation
*   **Script**: `build_foundation_aocc.sh`
*   **Description**: Installs the AMD Optimizing C/C++ Compiler (AOCC) using the bootstrapped GCC foundation compiler.
*   **Usage**:
    ```bash
    ./build_foundation_aocc.sh [custom_install_path]
    ```
*   **Output**: Symlinks to the compiler binaries are created at `./aocc-latest`.

### Intel oneAPI Foundation
*   **Script**: `build_foundation_intel.sh`
*   **Description**: Bootstraps the Intel oneAPI compilers (such as `icx` and `ifx`) and applies patches to decouple the suite from host-level GCC dependency conflicts.
*   **Usage**:
    ```bash
    ./build_foundation_intel.sh [custom_install_path] [version]
    ```
*   **Output**: Symlinks to the compiler binaries are created at `./intel-latest`.

---

## 2. Enclave Local Build Scripts

Once the foundations are prepared, use the enclave scripts to configure dependency hierarchies and build the application stack.

*   `local_build_gcc.sh`: Targets the GCC compiler. Installs libraries in `install_gcc/`.
*   `local_build_aocc.sh`: Targets the AOCC compiler. Installs libraries in `install_aocc/`.
*   `local_build_intel.sh`: Targets the Intel oneAPI compiler suite. Installs libraries in `install_intel/`.

### Shared Arguments & Command Flags
All enclave scripts accept the following runtime flags:
*   `--rebuild`: Performs a clean rebuild, purging the respective install tree and environment configurations.
*   `--ioapi`: Forces uninstallation and recompilation of the I/O API package.
*   `--ioapi-large`: (AOCC/Intel only) Rebuilds I/O API with expanded grid bounds (`PARMS3-LARGE.EXT` definitions) for CMAQ-DDM/ISAM runs.
*   `--smoke`: Forces uninstallation and recompilation of SMOKE.
*   `--smoke-version=[version]`: Specifies the exact SMOKE version to build (e.g. `5.2.1`, `dev`, `dev-omp`).

> [!IMPORTANT]
> Any SMOKE version specified via the `--smoke-version` argument (including `5.2.1`) **must** be explicitly defined in the local Spack package recipe at `packages/smoke/package.py`. Refer to the **Custom Spack Package Recipes** section below on how to add or check version definitions.

---

## 3. Custom Spack Package Recipes (`packages/`)

The local `packages/` directory is a custom Spack repository (namespace: `smoke_v52`) defined by `packages/repo.yaml`. It contains custom-written package recipes optimized for the high-performance scientific modeling stack:

*   **`packages/smoke/package.py`**:
    *   Defines the compilation recipe for SMOKE.
    *   **Verifying and Adding Versions**: Versions are declared using Spack's `version()` helper function. If you need to build a new version (e.g., `5.3.0`), you must append a new declaration containing its source URL and checksum, for example:
        ```python
        version("5.3.0",
                url="https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv530_Release.tar.gz",
                sha256="<sha256_hash>")
        ```
    *   Enforces direct tree-synchronization from local source trees for `dev` versions to ensure uncommitted changes are accurately staged.
    *   Generates a custom compiler-specific `Makeinclude` configuration file mapping correct build flags (`-Ofast`, LTO, and memory model settings) dynamically.
    *   Patches dependency ordering in SMOKE's main `Makefile` to prevent compiler race conditions.
*   **`packages/ioapi/package.py`**:
    *   Contains instructions for checking out and compiling the Models-3 I/O API version `3.2`.
    *   Supports the `+large` variant which swaps `PARMS3.EXT` for the expanded grid limits defined in `PARMS3-LARGE.EXT` (required for CMAQ ISAM/DDM configurations).
    *   Dynamically patches compiler flag injections for AOCC, GCC, and Intel, bypassing hardcoded GCC CRT object path leaks on non-standard Linux distributions.
    *   Applies AMD/AOCC patches (logfile initialization improvements in `initlog3.F`) and corrects OpenMP shared-scoping issues within legacy Fortran files.
*   **`packages/hdf5/package.py`, `packages/netcdf-c/package.py`, `packages/netcdf-fortran/package.py`**:
    *   Specialized local package overrides to ensure matching library variants (`+shared`, `~mpi`, `+fortran`, `~dap`) are compiled consistently across compiler chains, preventing mismatched libraries or runtime linking (RPATH) failures.

---

## 4. How to Compile SMOKE

Follow the steps below for the desired compiler track.

### Option A: Compiling with GCC
1. **Bootstrap GCC 14**:
    ```bash
    ./build_foundation_gcc.sh
    ```
2. **Compile SMOKE**:
    ```bash
    ./local_build_gcc.sh --smoke-version=5.2.1
    ```

### Option B: Compiling with AOCC
1. **Ensure GCC base exists**, then **Bootstrap AOCC**:
    ```bash
    ./build_foundation_gcc.sh
    ./build_foundation_aocc.sh
    ```
2. **Compile SMOKE**:
    ```bash
    ./local_build_aocc.sh --smoke-version=5.2.1
    ```

### Option C: Compiling with Intel oneAPI
1. **Ensure GCC base exists**, then **Bootstrap Intel compilers**:
    ```bash
    ./build_foundation_gcc.sh
    ./build_foundation_intel.sh
    ```
2. **Compile SMOKE**:
    ```bash
    ./local_build_intel.sh --smoke-version=5.2.1
    ```

---

## 5. Expected Outputs
Upon successful compilation, target directories will be generated containing the binaries and symlinks to libraries:
*   `install_gcc/smoke-latest/bin`
*   `install_aocc/smoke-latest/bin`
*   `install_intel/smoke-latest/bin`
