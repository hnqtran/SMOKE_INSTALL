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

    variant("shared", default=True, description="Enable shared library")
    variant("mpi", default=False, description="Enable parallel I/O support")
    variant("pic", default=True, description="Produce position-independent code")
    variant("dap", default=False, description="Enable OPeNDAP support")
    variant("byterange", default=False, description="Enable byterange support")
    variant("blosc", default=False, description="Enable blosc support")
    variant("szip", default=False, description="Enable szip support")
    variant("zstd", default=False, description="Enable zstd support")
    variant("fsync", default=False, description="Enable fsync support")
    variant("hdf4", default=False, description="Enable hdf4 support")
    variant("jna", default=False, description="Enable jna support")
    variant("logging", default=False, description="Enable logging support")
    variant("nczarr_zip", default=False, description="Enable nczarr_zip support")
    variant("optimize", default=True, description="Enable optimization support")
    variant("parallel-netcdf", default=False, description="Enable parallel-netcdf support")

    depends_on("hdf5+hl")
    depends_on("hdf5+mpi", when="+mpi")
    depends_on("zlib")
    depends_on("m4", type="build")
    depends_on("curl")
    depends_on("cmake@3.18:", type="build")
    depends_on("c", type="build")
    depends_on("cxx", type="build")

    def flag_handler(self, name, flags):
        if "+pic" in self.spec:
            if name == "cflags":
                flags.append("-fPIC")
        if name == "ldflags":
            flags.append("-lpthread")
        return flags, None, None

    def configure_args(self):
        spec = self.spec
        config_args = [
            "--enable-static",
            "--enable-netcdf-4",
            "--disable-dap",
            "--disable-libxml2",
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

        # Explicitly handle hardening variants to satisfy concretizer and build system
        for var in ["byterange", "blosc", "szip", "zstd", "dap"]:
            if "+" + var in spec:
                config_args.append("--enable-" + var)
            else:
                config_args.append("--disable-" + var)


        return config_args

    @property
    def libs(self):
        return find_libraries("libnetcdf", root=self.prefix, shared=False, recursive=True)
