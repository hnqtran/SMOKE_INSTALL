# SMOKE Spack-Driven Portable Build System (GCC Track)

This directory contains the Apptainer (Singularity) containerized build engine for compiling the Sparse Matrix Operator Kernel Emissions (SMOKE) modeling system and the Models-3 Input/Output Applications Programming Interface (I/O API). 

Using container isolation under **Rocky Linux 8**, this build track enforces strictly static linking (`~shared` variants) and generates generic `x86_64` microarchitecture binaries to guarantee complete portability across different High-Performance Computing (HPC) nodes.

---

## Prerequisites: Obtaining the Container Image

Before launching compilation, the Rocky Linux 8 container image (`rocky8_build.sif`) must be present in the build directory. You can pull the pre-configured Spack image from Docker Hub:

```bash
apptainer pull rocky8_build.sif docker://spack/rockylinux8
```

---

## Persistent Isolation & Cache Layers

The build environment utilizes multiple persistence layers on the host directory to achieve isolation, speed, and bypass network storage limits:

1.  **`.foundation_cache/`** (Mapped to `/opt/foundation` inside the container):
    *   Stores the bootstrapped modern GCC 14 compiler stack. Once built, it is registered as an upstream Spack installation, saving ~20-30 minutes on subsequent runs.
2.  **`.build_cache/`** (Mapped to `/opt/build_cache` inside the container):
    *   Stores binary package database blobs (HDF5, NetCDF, etc.) to act as a local mirror, avoiding redundant source compilations.
3.  **`.spack_home/`** (Mapped to `$HOME` inside the container):
    *   Persists Spack environment database indices, metadata, and GPG verification keys.
4.  **`.apptainer_cache/` & `.apptainer_tmp/`**:
    *   Prevents image layer re-downloads and relocates staging workspaces away from the host's `/tmp` to avoid directory disk space exhaustion.

---

## 1. Local Build Orchestration Script

*   **Script**: `portable_build_gcc.sh`
*   **Description**: Host-side orchestrator that mounts local paths into the Rocky Linux 8 container image (`rocky8_build.sif`), sets up toolchain wrappers, redirects build stages to high-capacity local scratch disk `/tmp`, and invokes Spack to install the static modeling stack.
*   **Usage**:
    ```bash
    ./portable_build_gcc.sh [compiler_spec] [flags]
    ```

### Command Flags
*   `--rebuild-all`: Wipes all localized caches, toolchains, and installation trees to perform a clean, fresh bootstrap.
*   `--rebuild-libs`: Surgically uninstalls and rebuilds the support libraries (Zlib, HDF5, NetCDF-C, and NetCDF-Fortran).
*   `--rebuild-ioapi`: Surgically uninstalls and rebuilds the I/O API library.
*   `--rebuild-smoke`: Surgically uninstalls and rebuilds the SMOKE suite.
*   `--smoke-version [version]`: Specifies the target SMOKE version to build. Must be `master`, `5.2.1`, or a dynamically injected version. (Defaults to `master`).
*   `--add-version [version] [url]`: Dynamically injects a custom SMOKE version spec with its tarball URL into the package recipe, computing its checksum automatically.
*   `--jobs [N]`: Sets the number of parallel compilation threads (defaults to the core count).

> [!IMPORTANT]
> The only SMOKE versions pre-defined in the package recipe are `master` and `5.2.1`. Dynamic versions must be registered via the `--add-version` flag at build time. Variants such as `dev`, `dev-omp`, `+openmp`, or `+large` are **not** defined or available in the portable build track.

---

## 2. Custom Spack Package Recipes (`packages/`)

The custom Spack repository (namespace: `smoke_v52`) is defined at the root of the portable build directory by `repo.yaml`, with its custom recipes located in the `packages/` directory:

*   **`packages/smoke/package.py`**:
    *   Defines the compilation recipe for SMOKE.
    *   **Verifying and Adding Versions**: Versions are declared using Spack's `version()` helper function. If you need to build a new version (e.g., `5.3.0`), you can use the `--add-version` flag, which appends a declaration containing its source URL and checksum:
        ```python
        version("5.3.0",
                url="https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv530_Release.tar.gz",
                sha256="<sha256_hash>")
        ```
    *   Generates a custom C/Fortran `Makeinclude` configuration file mapping static compilation flags dynamically.
*   **`packages/ioapi/package.py`**:
    *   Contains instructions for compiling the Models-3 I/O API version `3.2` without dynamic runtime or shared variants.
*   **`packages/hdf5/package.py`, `packages/netcdf-c/package.py`, `packages/netcdf-fortran/package.py`**:
    *   Specialized local package overrides to ensure matching library variants (`~shared`, `~mpi`, `+fortran`, `~dap`) are compiled consistently across compiler chains, preventing mismatched libraries or runtime linking failures.

---

## 3. How to Compile SMOKE

Ensure that `rocky8_build.sif` is present in the build directory before running compilation.

1.  **Run Compilation**:
    ```bash
    ./portable_build_gcc.sh --smoke-version=5.2.1
    ```

---

## 4. Expected Outputs
Upon successful compilation, target directories will be generated containing the static binaries:
*   `install_gcc/smoke-latest/bin`
