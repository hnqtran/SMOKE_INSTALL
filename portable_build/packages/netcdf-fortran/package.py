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

    variant("shared", default=False, description="Enable shared library (Disabled for portability)")
    variant("pic", default=True, description="Produce position-independent code")
    variant("mpi", default=False, description="Enable MPI support")
    variant("doc", default=False, description="Generate documentation")

    depends_on("netcdf-c")
    depends_on("netcdf-c+mpi", when="+mpi")
    depends_on("hdf5")
    depends_on("hdf5+mpi", when="+mpi")
    depends_on("zlib")
    depends_on("mpi", when="+mpi")

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
            flags.append("-static-libgcc -static-libgfortran -Wl,-Bstatic -lgomp -Wl,-Bdynamic -lpthread")
            
        return flags, None, None

    def configure_args(self):
        spec = self.spec
        config_args = ["--enable-static", "--disable-parallel-tests"]
        
        if "+shared" in spec:
            config_args.append("--enable-shared")
        else:
            config_args.append("--disable-shared")

        if "+mpi" in spec:
            config_args.append("CC={0}".format(spec["mpi"].mpicc))
            config_args.append("FC={0}".format(spec["mpi"].mpifc))
            config_args.append("F77={0}".format(spec["mpi"].mpif77))

        # Ensure we link against the static netcdf-c and its transitive deps
        nc_c = spec["netcdf-c"]
        if "~shared" in nc_c:
            # Manually inject dependency paths to bypass dynamic linker requirements
            libs = []
            libs.append("-L{0}".format(nc_c.prefix.lib))
            libs.append("-lnetcdf")
            libs.append("-L{0}".format(spec["hdf5"].prefix.lib))
            libs.append("-lhdf5_hl -lhdf5")
            libs.append("-L{0}".format(spec["zlib"].prefix.lib))
            libs.append("-lz")
            libs.append("-lm -lpthread")
            
            config_args.append("LIBS={0}".format(" ".join(libs)))

            cppflags = []
            cppflags.append("-I{0}".format(spec["netcdf-c"].prefix.include))
            cppflags.append("-I{0}".format(spec["hdf5"].prefix.include))
            cppflags.append("-I{0}".format(spec["zlib"].prefix.include))
            config_args.append("CPPFLAGS={0}".format(" ".join(cppflags)))

        return config_args

    @property
    def libs(self):
        return find_libraries("libnetcdff", root=self.prefix, shared=False, recursive=True)
