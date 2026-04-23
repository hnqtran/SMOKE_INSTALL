#!/bin/bash
# SMOKE Foundation Container Payload
# Executes natively inside the container bind-mounts to bypass string escaping issues.

set -e
export LC_ALL=C
export PATH=/usr/bin:/usr/local/bin:$PATH

cd /build

echo "==> [CONTAINER] Initiating GCC Foundation Cache..."
cp install_gcc.sh /tmp/install_gcc_foundation.sh
sed -i '/# Environment Initialization/,$d' /tmp/install_gcc_foundation.sh

/tmp/install_gcc_foundation.sh "" "/opt/smoke_foundation"

echo "==> [CONTAINER] Configuring Spack build stage isolation..."
export PATH="/opt/smoke_foundation/spack/bin:$PATH"
spack config --scope site add "config:build_stage:[/opt/smoke_foundation/spack_stage]"

echo "==> [CONTAINER] Caching Heavy Build Tools..."
spack compiler find --scope site
SYS_COMP=$(spack compilers | grep "gcc@" | grep -v "14.3.0" | head -n 1 | awk '{print $1}')
[[ -z "$SYS_COMP" ]] && SYS_COMP="gcc"

echo "==> Using System Compiler: $SYS_COMP"
spack install cmake autoconf automake m4 pkgconf %$SYS_COMP target=x86_64
