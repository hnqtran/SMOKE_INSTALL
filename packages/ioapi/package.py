from spack.package import *
import os

class Ioapi(MakefilePackage):
    """Models-3/EDSS Input/Output Applications Programming Interface."""

    homepage = "https://www.cmascenter.org/ioapi/"
    git = "https://github.com/cjcoats/ioapi-3.2"
    version("3.2", branch="master")
    variant("shared", default=True, description="Build shared libraries")
    variant("mpi", default=False, description="Enable MPI support")

    depends_on("c", type="build")
    depends_on("cxx", type="build")
    depends_on("fortran", type="build")
    depends_on("gcc")

    # Generic dependencies (follow global variants for toolchain consistency)
    depends_on("hdf5~shared+cxx+fortran+hl")
    depends_on("hdf5+mpi", when="+mpi")
    depends_on("netcdf-c~shared~dap")
    depends_on("netcdf-c+mpi", when="+mpi")
    depends_on("netcdf-fortran")
    depends_on("netcdf-fortran+mpi", when="+mpi")
    depends_on("mpi", when="+mpi")
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
        if 'aocc' in self.spec.compiler.name.lower() or self.spec.satisfies('%aocc'):
            env_flags = ' -fPIC -mcmodel=medium'
        else:
            env_flags = ''

        makeinc.filter(r'^CC\s*=.*',  f'CC  = {spack_cc}{env_flags}')
        makeinc.filter(r'^CXX\s*=.*', f'CXX = {spack_cxx}{env_flags}')
        makeinc.filter(r'^FC\s*=.*',  f'FC  = {spack_fc}{env_flags}')

        # Surgically append the linker fix ONLY for static builds to resolve symbol overlaps
        if "~shared" in self.spec:
            comp = self.spec.compiler.name.lower()
            ld_flag = "-Wl,-allow-multiple-definition" if 'oneapi' in comp or 'intel' in comp else "-Wl,--allow-multiple-definition"
            
            # Add static runtime flags too for total portability
            gcc = self.spec['gcc']
            gcc_lib64 = os.path.join(gcc.prefix, "lib64")
            gcc_internal = os.path.join(gcc.prefix, "lib", "gcc", "x86_64-pc-linux-gnu", str(gcc.version))
            gcc_L = f"-L{gcc_lib64} -L{gcc_internal} -B{gcc_internal}"

            if 'oneapi' in comp or 'intel' in comp:
                static_runtime = f"{gcc_L} -static-intel"
            elif 'aocc' in comp:
                static_runtime = f"{gcc_L} -static-flang-libs -static-openmp"
            else:
                static_runtime = "-static-libgcc -static-libgfortran"
                
            # Add -ldl for HDF5 transitive dependencies in static mode
            makeinc.filter(r'^(OMPLIBS\s*=.*)', r'\1 ' + ld_flag + " -ldl " + static_runtime)

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
