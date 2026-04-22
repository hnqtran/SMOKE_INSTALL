#!/bin/bash
# SMOKE Portable Build Engine (Apptainer/Singularity Wrapper)
# Usage: ./portable_build.sh [COMPILER/SPEC] [INSTALL_PATH] [OS_IMAGE]

set -euo pipefail

preflight_check() {
    if ! command -v apptainer >/dev/null 2>&1; then
        echo "==> [ERROR] Apptainer is not installed or not in PATH. Please load or install Apptainer."
        exit 1
    fi
}
preflight_check

OS_VERSION="${3:-rockylinux8}"
IMAGE="smoke_foundation_${OS_VERSION}.sif"
DEF_FILE="smoke_foundation_${OS_VERSION}.def"
COMP_SPEC="${1:-smoke@5.2.1 %oneapi}"
INST_ROOT="${2:-install_portable}"

# Default to Static Linking for Portable builds
export BUILD_STATIC="${BUILD_STATIC:-1}"
export ENV_NAME="portable"

# Redirect Apptainer cache and temp to local directory to save home space
export APPTAINER_CACHEDIR="${PWD}/.apptainer_cache"
export APPTAINER_TMPDIR="${PWD}/.apptainer_tmp"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

log() { echo "==> [PORTABLE] $1"; }

if [ ! -f "$IMAGE" ]; then
    log "Golden Base Image ($IMAGE) not found."
    log "Generating Apptainer definition for spack/${OS_VERSION}..."
    sed "s|{{OS_VERSION}}|${OS_VERSION}|g" smoke_foundation.def.template > "$DEF_FILE"
    
    log "Initiating first-time automated build (this will take ~30 mins)..."
    apptainer build "$IMAGE" "$DEF_FILE"
else
    log "Golden Base Image ($IMAGE) detected. Bypassing foundation compile."
fi

log "Starting Portable Build on $IMAGE..."
log "Target Spec: $COMP_SPEC"

# Ensure the install root exists
mkdir -p "$INST_ROOT"

# Launch Apptainer using a piped command stream to avoid heredoc expansion issues
printf '
set -euo pipefail
cd /build
export PATH=/usr/bin:/usr/local/bin:$PATH

SPEC="$1"
ROOT="$2"

echo "==> [DISPATCH] Evaluating Target Spec: $SPEC"
if [[ "$SPEC" == *"%%oneapi"* || "$SPEC" == *"%%intel"* ]]; then
    echo "==> [DISPATCH] Switching to Intel Track..."
    ./install_intel.sh "$SPEC" "$ROOT"
elif [[ "$SPEC" == *"%%aocc"* ]]; then
    echo "==> [DISPATCH] Switching to AOCC Track..."
    ./install_aocc.sh "$SPEC" "$ROOT"
else
    echo "==> [DISPATCH] Switching to GCC Track..."
    ./install_gcc.sh "$SPEC" "$ROOT"
fi

# --- Automated Portability Audit ---
echo "==> [AUDIT] Starting Portability Verification for SMOKE and IOAPI..."

# Discovery: smkinven (SMOKE) and airs2m3 (IOAPI)
TARGETS=("smkinven" "airs2m3")
for TARGET in "${TARGETS[@]}"; do
    echo "--> Auditing: $TARGET"
    BIN_PATH=$(find /build/spack/opt/spack/linux-x86_64 -name "$TARGET" -type f | head -n 1)
    
    if [[ -z "$BIN_PATH" ]]; then
        echo "!! [AUDIT] ERROR: Binary '\''$TARGET'\'' not found. Build may have failed or moved."
        continue
    fi

    echo "    Path: $BIN_PATH"
    LDD_OUT=$(ldd "$BIN_PATH")
    
    # Check for dynamic dependencies pointing into the Spack build root
    VULNERABLE=$(echo "$LDD_OUT" | grep "/build/spack" || true)
    
    if [[ -n "$VULNERABLE" ]]; then
        echo "    ----------------------------------------------------------------"
        echo "    !! WARNING: $TARGET is NOT fully portable !!"
        echo "    Detected Spack-tree dependencies:"
        echo "$VULNERABLE" | sed '\''s/^/      /'\''
        echo "    ----------------------------------------------------------------"
    else
        echo "    [✔] SUCCESS: $TARGET is PORTABLE (Self-contained Archive)"
    fi
done
echo "==> [AUDIT] Audit Complete."
' | apptainer exec --bind "$PWD":/build --bind /tmp:/tmp --home "$PWD" "$IMAGE" /bin/bash -s "$COMP_SPEC" "$INST_ROOT"

log "Process Complete."
