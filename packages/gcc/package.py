# SMOKE Portable Toolchain - Focused GCC Recipe
# A streamlined, single-file Spack package for modern GCC (12-15).
# Optimized for Linux x86_64 and 100% binary portability.

from spack.package import *
import os

class Gcc(AutotoolsPackage):
    """The GNU Compiler Collection. High-performance, portable edition for SMOKE."""

    homepage = "https://gcc.gnu.org"
    url = "https://ftp.gnu.org/gnu/gcc/gcc-14.3.0/gcc-14.3.0.tar.xz"

    version("14.3.0", sha256="e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a")
    
    compiler_wrapper_link_paths = {"c": "gcc", "cxx": "g++", "fortran": "gfortran"}

    variant("piclibs", default=False, description="Enforce PIC for all static runtime libraries")
    variant(
        "languages",
        default="c,c++,fortran",
        values=("ada", "brig", "c", "c++", "d", "fortran", "go", "java", "jit", "lto", "objc", "obj-c++"),
        multi=True,
        description="Metadata compatibility for solver"
    )

    provides("c", "cxx", when="languages=c,c++")
    provides("c", when="languages=c")
    provides("cxx", when="languages=c++")
    provides("fortran", when="languages=fortran")

    depends_on("gmp")
    depends_on("mpfr")
    depends_on("mpc")
    depends_on("zlib")
    depends_on("zstd")
    depends_on("diffutils", type="build")
    depends_on("perl", type="build")

    # Spack Toolchain Metadata
    c_names = ["gcc"]
    cxx_names = ["g++"]
    fortran_names = ["gfortran"]
    rpath_arg = "-Wl,-rpath,"
    linker_arg = "-Wl,"
    pic_flag = "-fPIC"
    def archspec_name(self):
        return "gcc"
    verbose_flags = ["-v"]
    implicit_rpath_libs = ["libgcc", "libgfortran"]
    stdcxx_libs = ("-lstdc++",)
    debug_flags = ["-g", "-gstabs+", "-gstabs", "-gxcoff+", "-gxcoff", "-gvms"]
    opt_flags = ["-O", "-O0", "-O1", "-O2", "-O3", "-Os", "-Ofast", "-Og"]
    version_argument = ("-dumpfullversion", "-dumpversion")

    compiler_wrapper_link_paths = {
        "c": os.path.join("gcc", "gcc"),
        "cxx": os.path.join("gcc", "g++"),
        "fortran": os.path.join("gcc", "gfortran"),
    }

    @property
    def cc(self):
        return os.path.join(self.prefix.bin, "gcc")

    @property
    def cxx(self):
        return os.path.join(self.prefix.bin, "g++")

    @property
    def fortran(self):
        return os.path.join(self.prefix.bin, "gfortran")

    def patch(self):
        # 1. Surgical PIC Enforcement for Portability
        if "+piclibs" in self.spec:
            for libdir in ["libquadmath", "libgcc", "libgfortran", "libstdc++-v3"]:
                mfile = os.path.join(self.stage.source_path, libdir, "Makefile.in")
                if os.path.isfile(mfile):
                    filter_file(r'^(CFLAGS\s*=.*)', r'\1 -fPIC', mfile)
                    filter_file(r'^(CPPFLAGS\s*=.*)', r'\1 -fPIC', mfile)
                    filter_file(r'^(DEFS\s*=.*)', r'\1 -fPIC', mfile)
                    filter_file(r'^(FCFLAGS\s*=.*)', r'\1 -fPIC', mfile)

        # 2. Universal Linux Fixincludes
        fix_h = "libgcc/config/i386/pthread-mutex.h"
        if os.path.isfile(fix_h):
             filter_file(r'#define\s+PTHREAD_MUTEX_INITIALIZER\s+.*', 
                         '#define PTHREAD_MUTEX_INITIALIZER { { 0, 0, 0, 0, 0, 0, { 0, 0 } } }', 
                         fix_h, error_on_num_diffs=False)

    def setup_build_environment(self, env):
        zlib = self.spec["zlib"]
        env.append_path("CPPFLAGS", "-I{0}".format(zlib.prefix.include))
        env.append_path("LDFLAGS", "-L{0}".format(zlib.prefix.lib))

    def configure_args(self):
        spec = self.spec
        
        args = [
            "--with-pkgversion=SMOKE-Portable",
            "--disable-multilib",
            "--disable-nls",
            "--with-system-zlib",
            "--with-zlib={0}".format(spec["zlib"].prefix),
            "--enable-languages=c,c++,fortran",
            "--with-gmp={0}".format(spec["gmp"].prefix),
            "--with-mpfr={0}".format(spec["mpfr"].prefix),
            "--with-mpc={0}".format(spec["mpc"].prefix),
            "--with-zstd={0}".format(spec["zstd"].prefix),
            "--disable-bootstrap",
        ]
        
            
        return args
