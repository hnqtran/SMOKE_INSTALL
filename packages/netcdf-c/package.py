# SMOKE Portable Toolchain - Focused NetCDF-C Recipe
# Optimized for Linux x86_64, zero-dependency static builds, and MPI scalability.

from spack.package import *
import os

class NetcdfC(AutotoolsPackage):
    """NetCDF-C library. Streamlined for SMOKE Portability and Scalability."""

    homepage = "https://www.unidata.ucar.edu/software/netcdf"
    url = "https://github.com/Unidata/netcdf-c/archive/refs/tags/v4.9.2.tar.gz"

    version("4.9.2", sha256="bc104d101278c68b303359b3dc4192f81592ae8640f1aee486921138f7f88cb7")
    version("4.8.1", sha256="bc018cc30d5da402622bf76462480664c6668b55eb16ba205a0dfb8647161dd0")

    variant("shared", default=False, description="Enable shared library")
    variant("mpi", default=False, description="Enable parallel I/O support")
    variant("pic", default=True, description="Produce position-independent code")

    depends_on("hdf5+hl")
    depends_on("hdf5+mpi", when="+mpi")
    depends_on("zlib-api")
    depends_on("m4", type="build")

    def flag_handler(self, name, flags):
        if "+pic" in self.spec:
            if name == "cflags":
                flags.append(self.compiler.cc_pic_flag)
        return flags, None, None

    def configure_args(self):
        spec = self.spec
        config_args = [
            "--enable-static",
            "--enable-netcdf-4",
            "--disable-dap",
            "--disable-parallel-tests",
            "--with-hdf5={0}".format(spec["hdf5"].prefix),
        ]

        if "+shared" in spec:
            config_args.append("--enable-shared")
        else:
            config_args.append("--disable-shared")

        if "+mpi" in spec:
            config_args.append("--enable-parallel-tests")
            config_args.append("CC={0}".format(spec["mpi"].mpicc))

        # Sealed Transitive Linking for Portable Static Binaries
        if "~shared" in spec:
            libs = []
            libs.append("-L{0}".format(spec["hdf5"].prefix.lib))
            libs.append("-lhdf5_hl -lhdf5")
            libs.append("-lz")
            libs.append("-lm -lpthread")
            config_args.append("LIBS={0}".format(" ".join(libs)))

        return config_args

    @property
    def libs(self):
        return find_libraries("libnetcdf", root=self.prefix, shared=False, recursive=True)
