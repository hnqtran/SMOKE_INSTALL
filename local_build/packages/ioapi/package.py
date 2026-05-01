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

    # Generic dependencies (use +shared and +fortran for toolchain consistency)
    depends_on("hdf5+shared~mpi+cxx+fortran+hl")
    depends_on("netcdf-c~mpi+shared~dap")
    depends_on("netcdf-fortran+shared")
    depends_on("sed", type="build")
    depends_on("gmake", type="build")
    depends_on("zlib")

    def get_ioapi_bin(self, spec):
        name = spec.compiler.name.lower()
        if 'oneapi' in name or 'intel' in name:
            return 'Linux2_x86_64ifx'
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
        makefile.filter(r'^\s*(NCFLIBS\s*=\s*\-lnetcdff -lnetcdf)', r'#\1')
        makefile.filter(r'^#\s*(NCFLIBS\s*=\s*\-lnetcdff -lnetcdf -lhdf5_hl -lhdf5 -lz)', r'NCFLIBS = -lnetcdff -lnetcdf -lhdf5_hl -lhdf5 -lz -lm')

        makefile.filter("^configure:.*", "configure:")

        makesed = FileFilter(os.path.join(temp_source_dir, 'ioapi', 'Makefile.nocpl.sed'))
        makesed.filter(r'^\s*(BASEDIR\s*=\s*\${HOME}/ioapi-3.2)', f'BASEDIR = {temp_source_dir}')
        makesed.filter(r'^\s*MAKEINCLUDE.\$\(BIN\)', f'MAKEINCLUDE.{BIN}')

        m3toolsed = FileFilter(os.path.join(temp_source_dir, 'm3tools', 'Makefile.nocpl.sed'))
        m3toolsed.filter(r'^\s*(BASEDIR\s*=\s*\${HOME}/ioapi-3.2)', f'BASEDIR = {temp_source_dir}')
        
        makeinc_path = os.path.join(temp_source_dir, 'ioapi', f'Makeinclude.{BIN}')
        makeinc = FileFilter(makeinc_path)
        # Use actual compiler binary paths to avoid recursive variable expansion
        # Inject AOCC-specific flags to resolve relocation errors
        if 'aocc' in self.spec.compiler.name.lower() or self.spec.satisfies('%aocc') or 'clang' in self.spec.compiler.name.lower() or 'llvm' in self.spec.compiler.name.lower():
            env_flags = ' -fPIC -mcmodel=medium'
        else:
            env_flags = ''

        makeinc.filter(r'^CC\s*=.*',  f'CC  = {self.compiler.cc}{env_flags}')
        makeinc.filter(r'^CXX\s*=.*', f'CXX = {self.compiler.cxx}{env_flags}')
        makeinc.filter(r'^FC\s*=.*',  f'FC  = {self.compiler.fc}{env_flags}')

        if 'oneapi' in spec.compiler.name.lower() or 'intel' in spec.compiler.name.lower():
            # Resolve multiple definition errors for iargc/getarg with Intel ifx
            # Prepend the flag to avoid breaking line-continuation backslashes at the end of lines
            filter_file(r'^COPTFLAGS\s*=\s*', 'COPTFLAGS = -Wl,-allow-multiple-definition ', makeinc_path)
            filter_file(r'^FOPTFLAGS\s*=\s*', 'FOPTFLAGS = -Wl,-allow-multiple-definition ', makeinc_path)

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

        make("configure")
        make("dirs")
        make("fix")

    def build(self, spec, prefix):
        # IOAPI Fortran modules must be compiled sequentially.
        import os
        env = os.environ.copy()
        env['MAKEFLAGS'] = '-j1'
        BIN = self.get_ioapi_bin(spec)
        
        # Extract library directories from dependencies for explicit linking (especially for AOCC/ld.lld)
        ncf_lib_dirs = spec["netcdf-fortran"].libs.directories
        nc_lib_dirs = spec["netcdf-c"].libs.directories
        hdf5_lib_dirs = spec["hdf5"].libs.directories
        zlib_lib_dirs = spec["zlib"].libs.directories
        
        # Build LFLAGS with all library paths and RPATH for runtime discovery
        lib_flags = []
        rpath_flags = []
        for lib_dir in ncf_lib_dirs + nc_lib_dirs + hdf5_lib_dirs + zlib_lib_dirs:
            lib_flags.append(f'-L{lib_dir}')
            rpath_flags.append(f'-Wl,-rpath,{lib_dir}')
        
        lflags = ' '.join(lib_flags + rpath_flags)
        
        # Build NETCDF_LIB for NetCDF C library specifically
        nc_lib_flag = ' '.join([f'-L{d}' for d in nc_lib_dirs]) + ' -lnetcdf'
        
        # Explicitly pass BIN and library paths (with RPATH) to ensure they override defaults
        make(f'BIN={BIN}', f'LFLAGS={lflags}', f'NETCDF_LIB={nc_lib_flag}', '-j1', extra_env=env)

    def install(self, spec, prefix):
        BIN = self.get_ioapi_bin(spec)
        # Explicitly pass BIN to ensure it overrides defaults without modifying the source Makefile
        make(f'BIN={BIN}', "install", "-j1")
        mkdirp(prefix.include.fixed132)
        install("ioapi/*.EXT", prefix.include)
        install("ioapi/fixed_src/*.EXT", prefix.include.fixed132)
