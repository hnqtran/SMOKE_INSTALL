#!/bin/bash
# SMOKE Standalone Local Build Engine (Host-Native)
# Usage: ./local_build.sh [COMPILER/SPEC] [INSTALL_PATH]

set -euo pipefail

# --- 1. Detection & Setup ---
export BUILD_STATIC=0  # Shared linking for local performance
export ENV_NAME="local"
SPACK_ROOT="${PWD}/spack"

COMP_SPEC="${1:-smoke@5.2.1 %gcc}"
INST_ROOT="${2:-install_local}"

log() { echo "==> [LOCAL] $1"; }

if [ -d "$SPACK_ROOT/share/spack" ]; then
    source "$SPACK_ROOT/share/spack/setup-env.sh"
    export SPACK_TARGET=$(spack arch -t 2>/dev/null || echo "native")
else
    log "ERROR: Spack not found at $SPACK_ROOT"
    exit 1
fi

log "Detected Local Architecture: $SPACK_TARGET"
log "Optimization Strategy: Maximum (Shared Linking, Host-Native)"
log "Target Spec: $COMP_SPEC"

# --- 2. Dispatcher ---
echo "==> [DISPATCH] Evaluating Local Target Spec: $COMP_SPEC"

if [[ "$COMP_SPEC" == *"%oneapi"* || "$COMP_SPEC" == *"%intel"* ]]; then
    log "Switching to Intel Track (Local)..."
    ./install_intel.sh "$COMP_SPEC" "$INST_ROOT"
elif [[ "$COMP_SPEC" == *"%aocc"* ]]; then
    log "Switching to AOCC Track (Local)..."
    ./install_aocc.sh "$COMP_SPEC" "$INST_ROOT"
else
    log "Switching to GCC Track (Local)..."
    ./install_gcc.sh "$COMP_SPEC" "$INST_ROOT"
fi

log "Local Build Process Complete."

