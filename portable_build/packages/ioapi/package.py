from spack.package import *
import os

class Ioapi(MakefilePackage):
    """Models-3/EDSS Input/Output Applications Programming Interface."""

    homepage = "https://www.cmascenter.org/ioapi/"
    git = "https://github.com/cjcoats/ioapi-3.2"
    version("3.2", branch="master")

    depends_on("c", type="build")
    depends_on("cxx", type="build")
    depends_on("fortran", type="build")

    # Generic dependencies (allow variants to be controlled by orchestrator)
    depends_on("hdf5~mpi+cxx+fortran+hl")
    depends_on("netcdf-c~mpi~dap")
    depends_on("netcdf-fortran")
    depends_on("sed", type="build")
    depends_on("gmake", type="build")
    depends_on("zlib")
    conflicts("^zlib-ng", msg="SMOKE runtime stack must use classic static zlib, not zlib-ng")

    def setup_build_environment(self, env):
        # Ultra-Compatibility: Static runtimes and legacy hash style
        env.append_flags('LDFLAGS', '-static-libgfortran -static-libgcc -static-libstdc++ -Wl,--hash-style=both')
        # Force allow-multiple-definition for static NetCDF-4.6+ conflicts
        # This must be in LDFLAGS to hit the linking phase of m3tools
        env.append_flags('LDFLAGS', '-Wl,--allow-multiple-definition')
        # Ensure static HDF5 can find dlopen/dlclose
        env.append_flags('LIBS', '-ldl')

    def get_ioapi_bin(self, spec):
        name = spec.compiler.name.lower()
        if 'oneapi' in name or 'intel' in name:
            return 'Linux2_x86_64ifx'
        if 'gcc' in name:
            return 'Linux2_x86_64'
        elif 'aocc' in name or spec.satisfies('%aocc'):
            return 'Linux2_x86_64aoccflang'
        return 'Linux2_x86_64'

    def edit(self, spec, prefix):
        os.symlink("Makefile.template", "Makefile")
        BIN = self.get_ioapi_bin(spec)
        temp_source_dir = self.stage.source_path
        
        makefile = FileFilter("Makefile")
        # Ensure correct BASEDIR and INSTALL paths are set
        makefile.filter(r'^#\s*(BASEDIR\s*=\s*\${PWD})', f'BASEDIR = {temp_source_dir}')
        makefile.filter(r'^\s*(BASEDIR\s*=\s*\${PWD})', r'#\1')
        makefile.filter(r'^#\s*(INSTALL\s*=\s*\${HOME})', f'INSTALL = {prefix}')
        makefile.filter(r'^#\s*(LIBINST\s*=\s*\$\(INSTALL\)/\$\(BIN\))', r'\1')
        makefile.filter(r'^#\s*(BININST\s*=\s*\$\(INSTALL\)/\$\(BIN\))', r'\1')
        makefile.filter(r'^#\s*(CPLMODE\s*=\s*nocpl.*)', r'\1')
        libs = []
        libs.append("-static-libgfortran -static-libgcc -static-libstdc++ -Wl,--hash-style=both")
        libs.append("-Wl,--allow-multiple-definition")
        libs.append("-L{0}".format(spec["netcdf-fortran"].prefix.lib))
        libs.append("-lnetcdff")
        libs.append("-L{0}".format(spec["netcdf-c"].prefix.lib))
        libs.append("-lnetcdf")
        libs.append("-L{0}".format(spec["hdf5"].prefix.lib))
        libs.append("-lhdf5_hl")
        libs.append("-lhdf5")
        libs.append("-L{0}".format(spec["zlib"].prefix.lib))
        libs.append("-lz")
        libs.append("-lm")
        libs.append("-ldl")
        makefile.filter(r'^\s*(NCFLIBS\s*=.*)', f'NCFLIBS = {" ".join(libs)}')

        makefile.filter("^configure:.*", "configure:")

        makesed = FileFilter(os.path.join(temp_source_dir, 'ioapi', 'Makefile.nocpl.sed'))
        makesed.filter(r'^\s*(BASEDIR\s*=\s*\${HOME}/ioapi-3.2)', f'BASEDIR = {temp_source_dir}')
        makesed.filter(r'^\s*MAKEINCLUDE.\$\(BIN\)', f'MAKEINCLUDE.{BIN}')

        m3toolsed = FileFilter(os.path.join(temp_source_dir, 'm3tools', 'Makefile.nocpl.sed'))
        m3toolsed.filter(r'^\s*(BASEDIR\s*=\s*\${HOME}/ioapi-3.2)', f'BASEDIR = {temp_source_dir}')
        
        makeinc_path = os.path.join(temp_source_dir, 'ioapi', f'Makeinclude.{BIN}')
        makeinc = FileFilter(makeinc_path)
        
        # Inject AOCC-specific flags to resolve relocation errors (Finding #201)
        env_flags = ' -fPIC -mcmodel=medium' if spec.satisfies('%aocc') else ''

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

        makeinc.filter(r'^CC\s*=.*',  f'CC  = {self.compiler.cc}{env_flags}')
        makeinc.filter(r'^CXX\s*=.*', f'CXX = {self.compiler.cxx}{env_flags}')
        makeinc.filter(r'^FC\s*=.*',  f'FC  = {self.compiler.fc}{env_flags}')
        
        # Inject the static runtimes into NCFLIBS to ensure they hit the linking phase of m3tools
        makeinc.filter(r'^(NCFLIBS\s*=.*)', r'\1 ' + static_runtime)

        # Force allow-multiple-definition for static NetCDF-4.6+ conflicts
        filter_file(r'^FOPTFLAGS\s*=\s*', 'FOPTFLAGS = -Wl,--allow-multiple-definition ', makeinc_path)

        # The native Makeinclude.Linux2_x86_64aoccflang has GCCOBJ with distro-specific
        # GCC CRT paths. These are already handled by AOCC's linker, so we remove the
        # entire multi-line GCCOBJ block to avoid "no such file" errors on other distros.
        import subprocess
        gccrt = os.path.dirname(
            subprocess.check_output(['gcc', '-print-libgcc-file-name']).decode().strip()
        )
        makeinc.filter(r'^GCCRT\s*=.*', f'GCCRT = {gccrt}')

        # Surgically remove multi-line GCCOBJ block (handles line-continuation backslashes)
        # Also remove incompatible AOCC flags that cause build failures in modern Flang
        if 'aocc' in spec.compiler.name.lower():
            # Apply filters to EVERYTHING in the ioapi directory to catch hardcoded flags
            for root, dirs, files in os.walk(os.path.join(temp_source_dir, 'ioapi')):
                for f in files:
                    if 'Makefile' in f or 'Makeinclude' in f:
                        filter_file(r'-fno-automatic', '', os.path.join(root, f))
                        filter_file(r'-std=legacy', '', os.path.join(root, f))

        with open(makeinc_path, 'r') as f:
            raw_lines = f.readlines()
        clean_lines = []
        skip_continuation = False
        for line in raw_lines:
            if line.startswith('GCCOBJ'):
                # Replace entire GCCOBJ assignment with empty
                clean_lines.append('GCCOBJ =\n')
                skip_continuation = line.rstrip().endswith('\\')
            elif skip_continuation:
                skip_continuation = line.rstrip().endswith('\\')
                # skip this continuation line entirely
            else:
                clean_lines.append(line)
        with open(makeinc_path, 'w') as f:
            f.writelines(clean_lines)

        with open(os.path.join(temp_source_dir, 'ioapi', 'sortic.c'), 'r') as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            if line.strip().startswith('#include "parms3.h"'):
                lines.insert(i + 1, '#include <stdlib.h>\n')
                break
        with open(os.path.join(temp_source_dir, 'ioapi', 'sortic.c'), 'w') as f:
            f.writelines(lines)

        # Brute Force Linkage: Replace any dynamic OpenMP flags with our absolute static paths
        # across the entire source tree to prevent host library leakage.
        # CRITICAL: We remove -fopenmp from the link phase (Makefiles/Makeincludes) 
        # because it triggers implicit dynamic linkage.
        for root, dirs, files in os.walk(self.stage.source_path):
            for f in files:
                if 'Makefile' in f or 'Makeinclude' in f:
                    _fpath = os.path.join(root, f)
                    filter_file(r'-lgomp', static_runtime, _fpath)
                    # Force static linkage by replacing the dynamic flag with the static archive path
                    filter_file(r'-fopenmp', static_runtime, _fpath)

        make("configure")
        make("dirs")
        make("fix")

    def build(self, spec, prefix):
        # IOAPI Fortran modules must be compiled sequentially.
        import os
        env = os.environ.copy()
        env['MAKEFLAGS'] = '-j1'
        BIN = self.get_ioapi_bin(spec)
        print(f"DEBUG: Using BIN={BIN} for compiler={spec.compiler.name}")
        # Explicitly pass BIN to ensure it overrides defaults without modifying the source Makefile
        make(f'BIN={BIN}', '-j1', extra_env=env)

    def install(self, spec, prefix):
        BIN = self.get_ioapi_bin(spec)
        # Explicitly pass BIN to ensure it overrides defaults without modifying the source Makefile
        make(f'BIN={BIN}', "install", "-j1")
        mkdirp(prefix.include.fixed132)
        install("ioapi/*.EXT", prefix.include)
        install("ioapi/fixed_src/*.EXT", prefix.include.fixed132)
