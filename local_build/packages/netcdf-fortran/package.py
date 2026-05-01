# SMOKE Portable Toolchain - Focused NetCDF-Fortran Recipe
# Optimized for Linux x86_64, zero-dependency static builds, and GitHub-readiness.

from spack.package import *
import os

class NetcdfFortran(AutotoolsPackage):
    """NetCDF-Fortran library. Streamlined for SMOKE Portability."""

    homepage = "https://www.unidata.ucar.edu/software/netcdf"
    url = "https://downloads.unidata.ucar.edu/netcdf-fortran/4.6.1/netcdf-fortran-4.6.1.tar.gz"

    version("4.6.2", sha256="df26b99d9003c93a8bc287b58172bf1c279676f8c10d6dd0daf8bc7204877096")
    version("4.6.1", sha256="b50b0c72b8b16b140201a020936aa8aeda5c79cf265c55160986cd637807a37a")
    version("4.5.3", sha256="123a5c6184336891e62cf2936b9f2d1c54e8dee299cfd9d2c1a1eb05dd668a74")

    variant("shared", default=True, description="Enable shared library")
    variant("pic", default=True, description="Produce position-independent code")
    variant("mpi", default=False, description="Enable MPI support")
    variant("doc", default=False, description="Generate documentation")

    depends_on("netcdf-c")
    depends_on("netcdf-c+mpi", when="+mpi")
    depends_on("hdf5")
    depends_on("hdf5+mpi", when="+mpi")
    depends_on("zlib")
    depends_on("mpi", when="+mpi")
    depends_on("cmake@3.18:", type="build")
    depends_on("c", type="build")
    depends_on("fortran", type="build")

    def flag_handler(self, name, flags):
        spec = self.spec
        if name == "fflags":
            # Mandatory fix for modern GCC argument strictness
            if spec.satisfies("%gcc@10:") or spec.satisfies("%aocc") or spec.satisfies("%intel-oneapi-compilers"):
                flags.append("-fallow-argument-mismatch")
            if "+pic" in spec:
                flags.append("-fPIC")
        elif name == "cflags" and "+pic" in spec:
            flags.append("-fPIC")
        elif name == "ldflags":
            flags.append("-lpthread")
            
        return flags, None, None

    def configure_args(self):
        spec = self.spec
        config_args = ["--enable-static", "--disable-parallel-tests"]
        
        if "+shared" in spec:
            config_args.append("--enable-shared")
        else:
            config_args.append("--disable-shared")

        # Use Spack's compiler configuration with safe attribute access
        # Only set compilers that exist in the current compiler spec
        if hasattr(self.compiler, 'cc') and self.compiler.cc:
            config_args.append("CC={0}".format(self.compiler.cc))
        if hasattr(self.compiler, 'cxx') and self.compiler.cxx:
            config_args.append("CXX={0}".format(self.compiler.cxx))
        if hasattr(self.compiler, 'fc') and self.compiler.fc:
            config_args.append("FC={0}".format(self.compiler.fc))
        if hasattr(self.compiler, 'f77') and self.compiler.f77:
            config_args.append("F77={0}".format(self.compiler.f77))

        if "+mpi" in spec:
            config_args.append("CC={0}".format(spec["mpi"].mpicc))
            config_args.append("FC={0}".format(spec["mpi"].mpifc))
            config_args.append("F77={0}".format(spec["mpi"].mpif77))

        return config_args

    def edit(self, spec, prefix):
        # Apply AOCC libtool patches for proper linking
        # AOCC/Clang needs explicit -Wl, prefixes in libtool for linker flags
        if spec.satisfies("%aocc"):
            filter_file(r'wl=""', 'wl="-Wl,"', "libtool")
            filter_file(r'\$wl-soname \$wl\$soname', r'$wl-soname,$soname', "libtool")
            filter_file(r'\$wl--whole-archive \$wl', r'$wl--whole-archive,', "libtool")
            filter_file(r'\$wl--no-whole-archive \$wl', r'$wl--no-whole-archive,', "libtool")

    @property
    def libs(self):
        return find_libraries("libnetcdff", root=self.prefix, shared=False, recursive=True)
