from spack.package import *
import os
import sys

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
    # 

    homepage = "https://www.cmascenter.org/smoke/"
    git = "https://github.com/CEMPD/SMOKE.git"

    maintainers = ["cmascenter"]

    version("master", branch="master") # This is the default version used when no version is specified, of if no other version is marked as preferred. 
    version("5.2.1", preferred=False,
            url="https://github.com/CEMPD/SMOKE/archive/refs/tags/SMOKEv521_Sep2025.tar.gz",
            sha256="195aff8e25970ad1cbb051b32cc063bdf5639791e6da31538d2076408ff719df")
    version("dev", git="file://" + os.getenv("SMOKE_DEV_PATH", "/proj/ie/proj/SMOKE/htran/SMOKE_MASTER"), branch="master")
    version("dev-omp", git="file://" + os.getenv("SMOKE_DEV_OMP_PATH", "/proj/ie/proj/SMOKE/htran/SMOKE_OpenMP"), branch="master")

    variant("openmp", default=False, description="Build with OpenMP support")
    
    depends_on("c", type="build")
    depends_on("fortran", type="build")

    depends_on("ioapi@3.2+openmp", when="+openmp")
    depends_on("ioapi@3.2~openmp", when="~openmp")
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

        # --- NEW: Full Sync from Local Source (dev version only) ---
        # Since 'dev' versions often have untracked or locally modified files,
        # we manually sync the entire tree from the source path to the stage.
        # We only do this for '@dev' to avoid corrupting standard releases.
        if spec.satisfies("@dev") or spec.satisfies("@dev-omp"):
            # Reuse local git path defined in the version() declarations above
            src_path = self.versions[spec.version]['git'].replace('file://', '')
            if os.path.exists(src_path):
                # Using install_tree to sync all files into the stage. 
                # This is safer and more robust in a Spack environment.
                install_tree(src_path, self.stage.source_path)

        # Determine SMOKE compiler flags based on its own compiler
        name = spec.compiler.name.lower()
        if 'gcc' in name:
            eflag    = "-ffixed-line-length-132 -fno-backslash -fallow-argument-mismatch"
            optflag  = "-Ofast -march=native -funroll-loops -fno-stack-arrays -DFLDMN=1 -DFSTR_L=int -DNEED_ARGS=1"
        elif 'oneapi' in name or 'intel' in name:
            eflag    = "-extend-source 132 -zero"
            optflag  = "-O3 -DFLDMN=1 -DFSTR_L=int -DNEED_ARGS=1"
        elif 'aocc' in name or 'clang' in name or 'llvm' in name:
            eflag    = "-ffixed-line-length-132 -fno-backslash -mcmodel=medium"
            # AOCC: Use optimized flags matching the working Makeinclude
            optflag  = "-Ofast -march=native -flto=auto -ffast-math -funroll-loops -DFLDMN=1 -DFSTR_L=long -DNEED_ARGS=1"
        else:
            eflag    = ""
            optflag  = "-O3"

        # Determine IOAPI binary layout (matched with the mandated AOCC toolchain)
        ioapi_bin = self.smk_bin

        # Use an absolute build directory at the top level of the stage
        abs_build_path = join_path(self.stage.source_path, self.build_path)

        # Ensure the build directory exists at the top level of the stage
        mkdirp(abs_build_path)
        
        # Use compiler-specific OpenMP flag if available, fallback to -fopenmp
        _omp_flags = getattr(self.compiler, "openmp_flags", ["-fopenmp"])
        omp_flag = _omp_flags[0] if spec.satisfies("+openmp") else ""
        link_omp = _omp_flags[0]  # Always link OMP to resolve ioapi symbols
        
        # Additional optimization link flags (e.g. LTO)
        link_extra = "-flto" if "aocc" in name else ""
        
        makeinclude = f"""
BASEDIR = {self.stage.source_path}/src
INCDIR  = $(BASEDIR)/inc
OBJDIR  = {abs_build_path}

IOBASE  = {ioapi}
IODIR   = $(IOBASE)/ioapi
IOINC   = $(IOBASE)/include/fixed132
IOBIN   = {ioapi_bin}

F90 = {os.environ["FC"]}
CC  = {os.environ["CC"]}

IFLAGS = -I$(IOINC) -I$(INCDIR) -I$(OBJDIR) -I$(IOBASE)/$(IOBIN) -I{netcdff}/include
EFLAG = {eflag}
FFLAGS = $(IFLAGS) $(EFLAG) {optflag} {omp_flag}
LDFLAGS = $(IFLAGS) {link_omp} {link_extra}
ARFLAGS = rv

SMKLIB = -L$(OBJDIR) -lsmoke
IOLIB = -L$(IOBASE)/$(IOBIN) -lioapi -L{netcdff}/lib -lnetcdff -L{netcdfc}/lib -lnetcdf -L{hdf5}/lib -lhdf5_hl -lhdf5 -L{zlib}/lib -lz

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
MODMBSET   = modmbset.mod 
MODMERGE   = modmerge.mod 
MODMET     = modmet.mod 
MODMOBIL   = modmobil.mod 
MODMVSMRG  = modmvsmrg.mod 
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
        # Write the configuration directly to the src/ directory
        with working_dir("src"):
            # Always write the standard Makeinclude (required by all versions)
            with open("Makeinclude", "w") as f:
                f.write(makeinclude)
            
            # DEEP CLEAN: Remove all binary artifacts from the source tree.
            # SMOKE's 'make clean' only cleans OBJDIR, which is not enough if 
            # objects exist in source subdirectories (e.g. src/emqa/).
            if spec.satisfies("@dev") or spec.satisfies("@dev-omp"):
                # Search from the stage root to catch everything
                with working_dir(self.stage.source_path):
                    find = which('find')
                    if find:
                        find('.', '-name', '*.o', '-o', '-name', '*.mod', '-o', '-name', '*.a', '-delete')
        
        # Patch the SMOKE src/Makefile to enforce library build ordering:
        # SLIB (libsmoke) depends on FLIB (libfileset, which defines modfileset.mod)
        makefile_path = "src/Makefile"
            
        if os.path.exists(makefile_path):
            smk_makefile = FileFilter(makefile_path)
            # Only filter if the target pattern exists to avoid errors on older versions
            smk_makefile.filter(
                r'^\$\{SLIB\}:\s*\$\{LIBOBJ\}',
                '${SLIB}: ${FLIB} ${LIBOBJ}'
            )
        

    def build(self, spec, prefix):
        components = os.environ.get('SMOKE_BUILD_COMPONENTS', '').strip().split()
        
        with working_dir("src"):
            makefile = "Makefile"
            
            if components and components != ['']:
                # Build only specified components with correct Makefile
                for comp in components:
                    if comp:  # Skip empty strings
                        print(f"DEBUG: building component {comp}", file=sys.stderr)
                        make("-f", makefile, comp, parallel=False)
            else:
                # Full build with correct Makefile
                print(f"DEBUG: full build, no specific components", file=sys.stderr)
                make("-f", makefile, parallel=False)

    def install(self, spec, prefix):
        # Determine arch-specific bin directory (matching IOAPI convention)
        arch_bin = self.smk_bin
        target_bin = join_path(prefix, arch_bin)
        mkdirp(target_bin)
        
        # Collect binaries from the absolute build directory
        build_dir = join_path(self.stage.source_path, self.build_path)
        if not os.path.exists(build_dir):
            build_dir = join_path(self.stage.source_path, "src")
        
        for binary in os.listdir(build_dir):
            bin_path = join_path(build_dir, binary)
            if os.path.isfile(bin_path) and os.access(bin_path, os.X_OK):
                if not binary.endswith(".o") and not binary.endswith(".mod") and not binary.endswith(".a"):
                    install(bin_path, target_bin)
        
        # Create compatibility symlink for Spack/User discovery (bin -> $BIN)
        with working_dir(prefix):
            if not os.path.exists('bin'):
                os.symlink(arch_bin, 'bin')

    @property
    def smk_bin(self):
        """Returns the architecture-specific binary directory name, matching IOAPI."""
        name = self.spec.compiler.name.lower()
        if 'oneapi' in name or 'intel' in name:
            return 'Linux2_x86_64ifx'
        elif 'aocc' in name or self.spec.satisfies('%aocc'):
            return 'Linux2_x86_64aoccflang'
        return 'Linux2_x86_64'

    @property
    def build_path(self):
        """Returns the relative path to the build directory."""
        return "build_omp" if self.spec.satisfies("+openmp") else "build"

    @property
    def omp_suffix(self):
        """Returns a suffix for the view directory if OpenMP is enabled.
        Skipped when the version string already ends in '-omp' (e.g. dev-omp)
        to avoid double-suffix directory names like smoke-dev-omp-omp-aocc-<hash>.
        """
        if not self.spec.satisfies("+openmp"):
            return ""
        if str(self.spec.version).endswith("-omp"):
            return ""
        return "-omp"
