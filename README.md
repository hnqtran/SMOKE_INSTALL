# SMOKE Spack-Driven Build Engine

This repository contains Spack-driven configuration frameworks to compile the Sparse Matrix Operator Kernel Emissions (SMOKE) modeling system and the Models-3 Input/Output Applications Programming Interface (I/O API). 

It offers two distinct build options depending on your environment, role, and deployment needs:

---

## Build Option Comparison

| Feature | `local_build/` (Recommended) | `portable_build/` (Developer Track) |
| :--- | :--- | :--- |
| **Execution Environment** | Runs directly on your host system / cluster. | Runs inside a Rocky Linux 8 container (Apptainer). |
| **Linking Style** | Standard shared or static libraries. | Enforces strictly static linking (`~shared`). |
| **System Compatibility** | **High compatibility with local system.** Maximizes performance by compiling for the host's microarchitecture. | **Universal Linux compatibility.** Generates generic `x86_64` binaries to run across different distributions. |
| **Supported Compilers** | **GCC**, **Intel oneAPI**, and **AOCC**. | **GCC** (via bootstrapped toolchain). |
| **Primary Audience** | **Majority of users** deploying SMOKE on a specific local server, workstation, or cluster. | **SMOKE developers** who need to build a single release binary that runs on most Linux systems. |

---

## 1. Local Build Track (`local_build/`)

> [!TIP]
> **Recommended for the majority of users.** 
> Sourcing from local compilers and runtime setups ensures that the generated binaries are fully compatible with your system's specific GPU/CPU microarchitectures, MPI setups, and batch scheduler configurations.

For detailed instructions on compiler bootstrapping (GCC, Intel, or AOCC) and environment building, see the sub-directory documentation:
*   `local_build/README.md`

### Quick Start (GCC Example)
```bash
cd local_build
./build_foundation_gcc.sh
./local_build_gcc.sh --smoke-version=5.2.1
```

---

## 2. Portable Build Track (`portable_build/`)

> [!IMPORTANT]
> **Recommended only for SMOKE developers.**
> This track compiles dependencies inside a secure, containerized enclave to produce fully self-contained static binaries. It is ideal for compiling release executables that must run on external cluster nodes with different OS distributions or library states.

For detailed instructions on obtaining the golden Rocky Linux 8 image and running the containerized build, see the sub-directory documentation:
*   `portable_build/README.md`

### Quick Start
```bash
cd portable_build
apptainer pull rocky8_build.sif docker://spack/rockylinux8
./portable_build_gcc.sh --smoke-version=5.2.1
```
