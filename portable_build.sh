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
    
    CACHE_DIR="$PWD/.foundation_cache"
    
    if [ ! -d "$CACHE_DIR/spack" ]; then
        log "Step 1: Hydrating foundation toolchain into external root ($CACHE_DIR)..."
        mkdir -p "$CACHE_DIR"
        
        # We use apptainer exec (without --writable) to bypass cluster mount restrictions.
        # This compiles the toolchain inside Rocky 8 but stores the result on the RHEL 9 host.
        apptainer exec --bind .:/build --bind "$CACHE_DIR:/opt/smoke_foundation" docker://spack/${OS_VERSION} /bin/bash -c "
            set -e
            export LC_ALL=C
            export PATH=/usr/bin:/usr/local/bin:\$PATH
            cd /build
            
            echo '==> [CONTAINER] Initiating GCC Foundation Cache...'
            cp install_gcc.sh /tmp/install_gcc_foundation.sh
            sed -i '/# Re-resolve paths if already installed/,\$d' /tmp/install_gcc_foundation.sh
            
            /tmp/install_gcc_foundation.sh \"\" \"/opt/smoke_foundation\"
            
            echo '==> [CONTAINER] Caching Heavy Build Tools...'
            # Ensure the newly built Spack is in PATH
            export PATH=\"/opt/smoke_foundation/spack/bin:\$PATH\"
            spack install cmake autoconf automake m4 pkgconf %gcc@14 target=${SPACK_TARGET:-x86_64}
        "
    else
        log "Step 1 (Skipped): Existing foundation cache detected."
    fi
    
    log "Step 2: Packaging Golden Image ($IMAGE)..."
    cat <<EOF > "$DEF_FILE"
Bootstrap: docker
From: spack/${OS_VERSION}

%files
    $CACHE_DIR /opt/smoke_foundation

%environment
    export SPACK_ROOT=/opt/smoke_foundation/spack
    export PACKAGES_ROOT=/opt/smoke_foundation/spack-packages
EOF

    # Standard build will safely ingest the compiled host directory
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
if [[ "$SPEC" == *"%oneapi"* || "$SPEC" == *"%intel"* ]]; then
    echo "==> [DISPATCH] Switching to Intel Track..."
    ./install_intel.sh "$SPEC" "$ROOT"
elif [[ "$SPEC" == *"%aocc"* ]]; then
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
' | apptainer exec --bind .:/build "$IMAGE" /bin/bash -s "$COMP_SPEC" "$INST_ROOT"

log "Process Complete."
