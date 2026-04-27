from spack.package import *
import os

class Smoke(MakefilePackage):
    """The Sparse Matrix Operator Kernel Emissions (SMOKE) Modeling System."""

    homepage = "https://www.cmascenter.org/smoke/"
    git = "https://github.com/CEMPD/SMOKE.git"

    maintainers = ["cmascenter"]

    version("master", branch="master")
    version("5.2.1", preferred=False,
            url="https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv521_Sep2025.tar.gz",
            sha256="195aff8e25970ad1cbb051b32cc063bdf5639791e6da31538d2076408ff719df")

    depends_on("c", type="build")
    depends_on("fortran", type="build")

    depends_on("ioapi@3.2")
    depends_on("zlib")
    depends_on("netcdf-c")
    depends_on("netcdf-fortran")
    depends_on("hdf5")
    conflicts("^zlib-ng", msg="SMOKE runtime stack must use classic static zlib, not zlib-ng")

    def edit(self, spec, prefix):
        ioapi = spec['ioapi'].prefix
        netcdff = spec['netcdf-fortran'].prefix
        netcdfc = spec['netcdf-c'].prefix
        hdf5    = spec['hdf5'].prefix
        zlib    = spec['zlib'].prefix

        # Determine SMOKE compiler flags based on its own compiler
        name = spec.compiler.name.lower()
        # Ultra-Compatibility: Static runtimes, legacy hashes, and collision overrides
        link_flags = " -static-libgfortran -static-libgcc -static-libstdc++ -Wl,--hash-style=both -Wl,--allow-multiple-definition"
        if 'gcc' in name:
            eflag    = "-ffixed-line-length-132 -fno-backslash -fallow-argument-mismatch"
        elif 'oneapi' in name or 'intel' in name:
            eflag    = "-extend-source 132 -zero"
        elif 'aocc' in name:
            eflag    = "-ffixed-line-length-132 -fno-backslash -mcmodel=medium"
        else:
            eflag    = ""

        # Determine IOAPI binary layout (matched with the mandated AOCC toolchain)
        if 'oneapi' in name or 'intel' in name:
            ioapi_bin = 'Linux2_x86_64ifx'
        elif 'aocc' in name:
            ioapi_bin = 'Linux2_x86_64aoccflang'
        else:
            ioapi_bin = 'Linux2_x86_64'

        # Finding #192: Deep Discovery of Foundation Static Runtimes
        import glob
        gcc_lib64 = None
        # Deep search for libgomp.a in foundation or near compiler
        potential_paths = glob.glob('/opt/foundation/**/lib64/libgomp.a', recursive=True)
        if potential_paths:
            gcc_lib64 = os.path.dirname(potential_paths[0])
        
        if not gcc_lib64:
             _cc_dir = os.path.dirname(self.compiler.cc)
             _path = os.path.join(os.path.dirname(_cc_dir), 'lib64')
             if os.path.exists(os.path.join(_path, 'libgomp.a')):
                 gcc_lib64 = _path
        
        if not gcc_lib64:
             gcc_lib64 = "/usr/lib64"

        print(f"==> [DEBUG] Discovered GCC Lib64: {gcc_lib64}")
        static_runtime = f"{os.path.join(gcc_lib64, 'libgomp.a')} {os.path.join(gcc_lib64, 'libquadmath.a')} -lpthread -ldl"

        makeinclude = f"""
BASEDIR = {self.stage.source_path}/src
INCDIR  = $(BASEDIR)/inc
OBJDIR  = {self.stage.source_path}/build

IOBASE  = {ioapi}
IODIR   = $(IOBASE)/ioapi
IOINC   = $(IOBASE)/include/fixed132
IOBIN   = lib

F90 = {self.compiler.fc}
CC  = {self.compiler.cc}

IFLAGS = -I$(IOINC) -I$(INCDIR) -I$(OBJDIR) -I{ioapi}/lib -I{ioapi}/{ioapi_bin} -I{netcdff}/include
EFLAG = {eflag}
FFLAGS = $(IFLAGS) $(EFLAG) -O3 -fopenmp
LDFLAGS = $(IFLAGS) -fopenmp
ARFLAGS = rv

LIBS    = -L$(OBJDIR) -lfileset -lsmoke -lemmod -lfileset -lsmoke -L{ioapi}/lib -lioapi -L{netcdff}/lib -lnetcdff -L{netcdfc}/lib -lnetcdf -L{hdf5}/lib -lhdf5_hl -lhdf5 -L{zlib}/lib -lz -ldl {static_runtime} {link_flags}
VPATH = $(OBJDIR)

MODBEIS3   = modbeis3.mod
MODBIOG    = modbiog.mod
MODCNTRL   = modcntrl.mod
MODDAYHR   = moddayhr.mod
MODELEV    = modelev.mod
MODEMFAC   = modemfac.mod
MODINFO    = modinfo.mod
MODGRID    = modgrid.mod
MODLISTS   = modlists.mod
MODMERGE   = modmerge.mod
MODMET     = modmet.mod
MODMOBIL   = modmobil.mod
MODREPBN   = modrepbn.mod
MODREPRT   = modreprt.mod
MODSOURC   = modsourc.mod
MODSPRO    = modspro.mod
MODSTCY    = modstcy.mod
MODSURG    = modsurg.mod
MODTAG     = modtag.mod
MODTMPRL   = modtmprl.mod
MODXREF    = modxref.mod
MODFILESET = modfileset.mod
MODGRDLIB  = modgrdlib.mod
"""
        # Patch SMOKE source to relax strict OpenMP scoping that fails on AOCC/Flang
        # specifically in genrprt.f and genlgmat.f (custom ported versions).
        for fpath in ['src/emqa/genrprt.f', 'src/grdmat/genlgmat.f']:
            full_path = os.path.join(self.stage.source_path, fpath)
            if os.path.exists(full_path):
                filter_file(r'DEFAULT\(\s*NONE\s*\)', 'DEFAULT( SHARED )', full_path)

        mkdirp("build")
        with open("src/Makeinclude", "w") as f:
            f.write(makeinclude)

        # Brute Force Linkage: Replace any dynamic OpenMP flags with our absolute static paths
        # across the entire source tree to prevent host library leakage.
        # CRITICAL: We remove -fopenmp from the link phase (Makefiles/Makeincludes) 
        # because it triggers implicit dynamic linkage.
        for root, dirs, files in os.walk(self.stage.source_path):
            for f in files:
                if 'Makefile' in f or 'Makeinclude' in f:
                    _fpath = os.path.join(root, f)
                    # Replace shortcut flags with absolute paths
                    filter_file(r'-lgomp', static_runtime, _fpath)
                    # For -fopenmp, we replace it with the static archive ONLY if it's likely a link line
                    # or just remove it if we already have the static runtime in the command.
                    # In SMOKE, we'll replace it with the static runtime to be safe.
                    filter_file(r'-fopenmp', static_runtime, _fpath)

        # Patch the SMOKE src/Makefile to enforce library build ordering:
        # SLIB (libsmoke) depends on FLIB (libfileset, which defines modfileset.mod)
        # Without this, make -j1 may still build SLIB before FLIB since no explicit
        # dependency exists between them in the original Makefile.
        smk_makefile = FileFilter("src/Makefile")
        smk_makefile.filter(
            r'^\$\{SLIB\}:\s*\$\{LIBOBJ\}',
            '${SLIB}: ${FLIB} ${LIBOBJ}'
        )

    def build(self, spec, prefix):
        with working_dir("src"):
            # SMOKE's Fortran modules must be compiled in strict dependency order.
            # Older Flang (AOCC) does not support parallel module compilation.
            # Use fully sequential build to guarantee correct .mod file generation order.
            make(parallel=False)

    def install(self, spec, prefix):
        mkdirp(prefix.bin)
        for binary in os.listdir("build"):
            if not binary.endswith(".o") and not binary.endswith(".mod") and not binary.endswith(".a"):
                install(join_path("build", binary), prefix.bin)
