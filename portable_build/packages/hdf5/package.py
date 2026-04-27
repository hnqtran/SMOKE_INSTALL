# SMOKE Portable Toolchain - Focused HDF5 Recipe
# Optimized for Linux x86_64, zero-dependency static builds, and MPI scalability.

from spack.package import *
import os

class Hdf5(CMakePackage):
    """HDF5 library. Streamlined for SMOKE Portability and Scalability."""

    homepage = "https://support.hdfgroup.org"
    url = "https://support.hdfgroup.org/releases/hdf5/v1_14/v1_14_5/downloads/hdf5-1.14.5.tar.gz"

    version("1.14.5", sha256="ec2e13c52e60f9a01491bb3158cb3778c985697131fc6a342262d32a26e58e44")
    version("1.14.3", sha256="09cdb287aa7a89148c1638dd20891fdbae08102cf433ef128fd345338aa237c7")

    variant("shared", default=False, description="Enable shared library")
    variant("mpi", default=False, description="Enable MPI support")
    variant("hl", default=True, description="Enable the high-level library (Required for NetCDF)")
    variant("fortran", default=False, description="Enable Fortran support")
    variant("cxx", default=True, description="Enable C++ support")
    variant("ipo", default=False, description="Enable IPO support")
    variant("java", default=False, description="Enable Java support")
    variant("map", default=False, description="Enable MAP support")
    variant("szip", default=False, description="Enable szip support")
    variant("threadsafe", default=False, description="Enable threadsafe support")
    variant("tools", default=True, description="Build tools")
    variant("pic", default=True, description="Produce position-independent code")

    depends_on("zlib")
    depends_on("mpi", when="+mpi")
    depends_on("cmake@3.18:", type="build")

    def flag_handler(self, name, flags):
        if "+pic" in self.spec:
            if name in ["cflags", "cxxflags", "fflags"]:
                flags.append("-fPIC")
        if name == "ldflags":
            flags.append("-static-libgcc -static-libstdc++ -Wl,-Bstatic -lgomp -Wl,-Bdynamic -lpthread")
        return flags, None, None

    def cmake_args(self):
        spec = self.spec
        args = [
            self.define("HDF5_BUILD_EXAMPLES", False),
            self.define("BUILD_TESTING", False),
            self.define_from_variant("BUILD_SHARED_LIBS", "shared"),
            self.define("ONLY_SHARED_LIBS", False),
            self.define_from_variant("HDF5_ENABLE_PARALLEL", "mpi"),
            self.define_from_variant("HDF5_BUILD_HL_LIB", "hl"),
            self.define_from_variant("HDF5_BUILD_FORTRAN", "fortran"),
            self.define_from_variant("HDF5_BUILD_CPP_LIB", "cxx"),
            self.define("HDF5_ENABLE_Z_LIB_SUPPORT", True),
            self.define("ALLOW_UNSUPPORTED", True),
        ]

        if "+mpi" in spec:
            args.append(self.define("MPI_C_COMPILER", spec["mpi"].mpicc))
            if "+fortran" in spec:
                args.append(self.define("MPI_Fortran_COMPILER", spec["mpi"].mpifc))

        return args

    @property
    def libs(self):
        libraries = ["libhdf5"]
        if "+hl" in self.spec:
            libraries.insert(0, "libhdf5_hl")
        if "+fortran" in self.spec:
            libraries.insert(0, "libhdf5_fortran")
            if "+hl" in self.spec:
                libraries.insert(0, "libhdf5_hl_fortran")
        
        return find_libraries(libraries, root=self.prefix, shared=False, recursive=True)
