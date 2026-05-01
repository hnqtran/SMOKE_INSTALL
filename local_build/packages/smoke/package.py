from spack.package import *
import os

class Smoke(MakefilePackage):
    """The Sparse Matrix Operator Kernel Emissions (SMOKE) Modeling System."""

    # To add a new version:
    # 1. Spack method: spack checksum smoke@<VERSION>
    # 2. Manual: curl -L <URL> | sha256sum
    # 3. Python:
    #    python3 -c "
    #    import hashlib, urllib.request
    #    url = 'https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv530_Release.tar.gz'
    #    sha256 = hashlib.sha256(urllib.request.urlopen(url).read()).hexdigest()
    #    print(sha256)"
    # Then add: version("5.3.0", url="...", sha256="<hash>")

    homepage = "https://www.cmascenter.org/smoke/"
    git = "https://github.com/CEMPD/SMOKE.git"

    maintainers = ["cmascenter"]

    version("master", branch="master") # This is the default version used when no version is specified, of if no other version is marked as preferred. 
    version("5.2.1", preferred=False,
            url="https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv521_Sep2025.tar.gz",
            sha256="195aff8e25970ad1cbb051b32cc063bdf5639791e6da31538d2076408ff719df")
    version("dev",
            url="file:///proj/ie/proj/SMOKE/htran/SMOKE_MASTER",
            sha256="0" * 64)

    depends_on("c", type="build")
    depends_on("fortran", type="build")

    depends_on("ioapi@3.2")
    depends_on("zlib")
    depends_on("netcdf-c+shared")
    depends_on("netcdf-fortran+shared")
    depends_on("hdf5+shared")

    def edit(self, spec, prefix):
        ioapi = spec['ioapi'].prefix
        netcdff = spec['netcdf-fortran'].prefix
        netcdfc = spec['netcdf-c'].prefix
        hdf5    = spec['hdf5'].prefix
        zlib    = spec['zlib'].prefix

        # Determine SMOKE compiler flags based on its own compiler
        name = spec.compiler.name.lower()
        if 'gcc' in name:
            eflag    = "-ffixed-line-length-132 -fno-backslash -fallow-argument-mismatch"
        elif 'oneapi' in name or 'intel' in name:
            eflag    = "-extend-source 132 -zero"
        elif 'aocc' in name or 'clang' in name or 'llvm' in name:
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

SMKLIB = -L$(OBJDIR) -lsmoke
IOLIB = -L$(IOBASE)/lib -lioapi -L{netcdff}/lib -lnetcdff -L{netcdfc}/lib -lnetcdf -L{hdf5}/lib -lhdf5_hl -lhdf5 -L{zlib}/lib -lz

LIBS = -L$(OBJDIR) -lfileset -lsmoke -lemmod -lfileset -lsmoke $(IOLIB) 
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
