#!/usr/bin/env bash
# Installs the pre-built nvidia.raw sysext on a running TrueNAS system.
# All driver compilation happens on GitHub Actions — this script only
# downloads and places the pre-built nvidia.raw file.
#
# Usage: curl -fsSL <release-url>/install.sh | sudo bash
#    or: sudo ./install.sh [path-to-nvidia.raw]
#    or: sudo ./install.sh --mig-profiles=47,47,14,14 --pool=fast

set -euo pipefail

REPO="scyto/truenas-nvidia-rtx6000-pro-mig"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
NVIDIA_RAW="${SYSEXT_DIR}/nvidia.raw"

# --- Parse CLI arguments ---
LOCAL_RAW=""
MIG_PROFILES=""
POOL_NAME=""
PERSIST_PATH=""

for arg in "$@"; do
    case "$arg" in
        --mig-profiles=*|--mig=*) MIG_PROFILES="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-nvidia.raw]"
            echo ""
            echo "Options:"
            echo "  --mig=PROFILES           MIG profile IDs (e.g., 47,47,14,14)"
            echo "  --mig-profiles=PROFILES  (alias for --mig)"
            echo "  --pool=NAME              ZFS pool for persistent config (e.g., fast)"
            echo "  --persist-path=PATH      Exact path for persistent config"
            echo "  --help                   Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo ./install.sh --mig-profiles=47,47,14,14 --pool=fast"
            echo "  sudo ./install.sh --mig-profiles=14,14,14,14"
            echo "  curl -fsSL <url>/install.sh | sudo bash"
            exit 0
            ;;
        *)
            if [ -f "$arg" ]; then
                LOCAL_RAW="$arg"
            fi
            ;;
    esac
done

cleanup() {
    rm -f /tmp/nvidia.raw /tmp/nvidia.raw.sha256
    rm -rf /tmp/nvidia-sysext-unpack
}
trap cleanup EXIT

# If a local path is provided, use it; otherwise download from GitHub releases
if [ -n "$LOCAL_RAW" ]; then
    echo "Using local nvidia.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" /tmp/nvidia.raw
else
    # Detect TrueNAS version
    VERSION=$(midclt call system.info | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")
    echo "Detected TrueNAS version: ${VERSION}"

    # Find matching release
    echo "Searching for matching release..."
    RELEASE_TAG=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
        | python3 -c "
import sys, json
releases = json.load(sys.stdin)
version = '${VERSION}'
matches = [r for r in releases if version in r['tag_name']]
if not matches:
    print('', end='')
else:
    print(matches[0]['tag_name'], end='')
")

    if [ -z "$RELEASE_TAG" ]; then
        echo "ERROR: No release found for TrueNAS version ${VERSION}"
        echo "Available releases:"
        curl -sf "https://api.github.com/repos/${REPO}/releases" \
            | python3 -c "import sys,json; [print(f'  {r[\"tag_name\"]}') for r in json.load(sys.stdin)]"
        exit 1
    fi

    echo "Found release: ${RELEASE_TAG}"

    # Download nvidia.raw and checksum
    BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
    echo "Downloading nvidia.raw..."
    curl -fSL "${BASE_URL}/nvidia.raw" -o /tmp/nvidia.raw
    curl -fSL "${BASE_URL}/nvidia.raw.sha256" -o /tmp/nvidia.raw.sha256

    # Verify checksum
    echo "Verifying checksum..."
    if ! (cd /tmp && sha256sum -c nvidia.raw.sha256); then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi
    echo "Checksum OK"
fi

# Inject displaymodeselector into nvidia.raw if found in user's home directory
CALLER_HOME=$(eval echo "~${SUDO_USER:-root}")
DMS_SRC=""
for candidate in "${CALLER_HOME}/displaymodeselector" "${CALLER_HOME}/DisplayModeSelector"; do
    if [ -f "$candidate" ]; then
        DMS_SRC="$candidate"
        break
    fi
done

if [ -n "$DMS_SRC" ]; then
    if command -v unsquashfs &>/dev/null && command -v mksquashfs &>/dev/null; then
        echo "Found displaymodeselector at ${DMS_SRC}, injecting into nvidia.raw..."
        unsquashfs -d /tmp/nvidia-sysext-unpack /tmp/nvidia.raw
        cp "$DMS_SRC" /tmp/nvidia-sysext-unpack/usr/bin/displaymodeselector
        chmod +x /tmp/nvidia-sysext-unpack/usr/bin/displaymodeselector
        mksquashfs /tmp/nvidia-sysext-unpack /tmp/nvidia.raw -noappend -comp zstd
        rm -rf /tmp/nvidia-sysext-unpack
        echo "displaymodeselector injected into nvidia.raw"
    else
        echo "WARNING: squashfs-tools not found, cannot inject displaymodeselector into sysext"
        echo "  Install squashfs-tools or include displaymodeselector via the build workflow"
    fi
else
    echo ""
    echo "NOTE: displaymodeselector not found in ${CALLER_HOME}/"
    echo "  MIG requires displaymodeselector to switch to compute display mode."
    echo "  Download it from https://developer.nvidia.com/displaymodeselector"
    echo "  Place it in your home directory and re-run this script to include it."
fi

echo ""
echo "=== Installing nvidia.raw ==="
echo ""
echo "WARNING: This will temporarily stop Docker and all TrueNAS apps"
echo "while the NVIDIA sysext is being replaced."
echo ""
if [ -e /dev/tty ]; then
    printf "Continue? [Y/n] " >&2
    read -r confirm </dev/tty || confirm="y"
    case "$confirm" in
        [nN]*) echo "Aborted."; exit 0 ;;
    esac
fi

# Disable NVIDIA support temporarily
echo "Disabling NVIDIA support..."
midclt call docker.update '{"nvidia": false}'
echo "[diag] After docker.update false — sysext status:"
systemd-sysext status 2>&1 | head -5 || true
systemd-sysext unmerge

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr)
echo "Setting ${USR_DATASET} to writable..."
zfs set readonly=off "${USR_DATASET}"

# Backup existing nvidia.raw (original will be saved to persistent storage later)
if [ -f "${NVIDIA_RAW}" ]; then
    echo "Backing up existing nvidia.raw..."
    cp "${NVIDIA_RAW}" "${NVIDIA_RAW}.bak"
fi

# Install new nvidia.raw
echo "Installing new nvidia.raw..."
cp /tmp/nvidia.raw "${NVIDIA_RAW}"

# Restore read-only
zfs set readonly=on "${USR_DATASET}"

# Re-enable NVIDIA support
# TrueNAS uses symlinks in /etc/extensions/ to control which sysext extensions load.
# docker.update '{"nvidia": false}' removes the nvidia symlink — we must recreate it.
echo "[diag] /etc/extensions/ before symlink: $(ls /etc/extensions/ 2>&1)"
mkdir -p /etc/extensions
ln -sf "${NVIDIA_RAW}" /etc/extensions/nvidia.raw
echo "[diag] /etc/extensions/ after symlink: $(ls /etc/extensions/ 2>&1)"
echo "Merging sysext and re-enabling NVIDIA..."
systemd-sysext merge

# Verify nvidia was picked up by sysext
if ! [ -x /usr/bin/nvidia-smi ]; then
    echo ""
    echo "ERROR: nvidia-smi not found after sysext merge."
    echo "  The nvidia.raw sysext was not loaded correctly."
    echo "  Check: ls -la ${NVIDIA_RAW}"
    echo "  Check: systemd-sysext status"
    echo ""
    echo "Aborting — cannot continue without NVIDIA drivers."
    # Try to re-enable Docker without NVIDIA so apps aren't stuck
    midclt call docker.update '{"nvidia": false}' 2>/dev/null
    exit 1
fi

systemctl daemon-reload

# NOTE: Docker re-enable is deferred until after ALL nvidia-smi usage.
# midclt call docker.update '{"nvidia": true}' triggers the middleware to
# asynchronously unmerge+remerge sysext ~60-90s later, which removes nvidia.
echo "[diag] After sysext merge: nvidia-smi exists=$(ls /usr/bin/nvidia-smi 2>&1)"

# Enable GPU persistence mode
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
    echo "Starting nvidia-persistenced..."
    systemctl start nvidia-persistenced.service 2>/dev/null \
        && echo "nvidia-persistenced started" \
        || echo "WARNING: Could not start nvidia-persistenced"
else
    echo "Enabling persistence mode via nvidia-smi..."
    /usr/bin/nvidia-smi -pm 1 2>/dev/null \
        && echo "Persistence mode enabled" \
        || echo "WARNING: Could not enable persistence mode"
fi

echo ""
echo "=== Installation complete ==="
echo ""

# Verify
DRIVER_VER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
PERSIST=$(/usr/bin/nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null || echo "unknown")
MIG_CUR=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "unknown")
echo "Driver: ${DRIVER_VER}  |  Persistence: ${PERSIST}  |  MIG: ${MIG_CUR}"

# ==========================================================================
# Persistence setup — survives reboots and TrueNAS updates
# ==========================================================================

echo ""
echo "=== Setting up persistence ==="

# --- Detect persistent storage pool ---
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_DIR="$PERSIST_PATH"
elif [ -n "$POOL_NAME" ]; then
    PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
else
    # Auto-detect: first pool that isn't boot-pool
    POOL_NAME=$(zpool list -H -o name 2>/dev/null | grep -v '^boot-pool$' | head -1)
    if [ -n "$POOL_NAME" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
        echo "Auto-detected pool: ${POOL_NAME}"
    else
        echo "WARNING: No ZFS pool found (excluding boot-pool). Skipping persistence setup."
        echo "  Re-run with --pool=<name> or --persist-path=<path> to enable persistence."
        exit 0
    fi
fi

echo "Persistent config directory: ${PERSIST_DIR}"
mkdir -p "$PERSIST_DIR"

# --- Backup nvidia.raw to persistent storage ---
# Save the original (stock TrueNAS) nvidia.raw if we haven't already
if [ -f "${NVIDIA_RAW}.bak" ] && [ ! -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
    echo "Saving original nvidia.raw to persistent storage..."
    cp "${NVIDIA_RAW}.bak" "${PERSIST_DIR}/nvidia-original.raw"
fi
echo "Backing up custom nvidia.raw to persistent storage..."
cp /tmp/nvidia.raw "${PERSIST_DIR}/nvidia.raw"

# --- Write PREINIT script to persistent storage ---
# NOTE: This is an inline copy of scripts/nvidia-preinit.sh.
# Keep both copies in sync when making changes.
echo "Writing PREINIT script..."
cat > "${PERSIST_DIR}/nvidia-preinit.sh" <<'PREINIT_EOF'
#!/usr/bin/env bash
# TrueNAS PREINIT script: reinstalls nvidia.raw sysext after OS updates.
# Stored on persistent pool; registered via midclt during install.
# Runs before services start, ensuring GPU drivers are available for Docker.

set -uo pipefail

log() { echo "[nvidia-preinit] $*"; }

# --- Find persistent config via glob ---
PERSIST_DIR=""
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] && PERSIST_DIR="$d" && break
done

if [ -z "$PERSIST_DIR" ]; then
    log "No persistent config found at /mnt/*/.config/nvidia-gpu/, nothing to do"
    exit 0
fi

NVIDIA_RAW_BACKUP="${PERSIST_DIR}/nvidia.raw"
SYSEXT_TARGET="/usr/share/truenas/sysext-extensions/nvidia.raw"

if [ ! -f "$NVIDIA_RAW_BACKUP" ]; then
    log "No nvidia.raw backup at ${NVIDIA_RAW_BACKUP}, nothing to do"
    exit 0
fi

# --- Compare checksums — only skip the file copy if matching ---
NEED_COPY=true
if [ -f "$SYSEXT_TARGET" ]; then
    INSTALLED_SUM=$(sha256sum "$SYSEXT_TARGET" | awk '{print $1}')
    BACKUP_SUM=$(sha256sum "$NVIDIA_RAW_BACKUP" | awk '{print $1}')
    if [ "$INSTALLED_SUM" = "$BACKUP_SUM" ]; then
        log "nvidia.raw already matches backup, skipping copy"
        NEED_COPY=false
    else
        log "nvidia.raw differs from backup (update detected), reinstalling..."
    fi
else
    log "nvidia.raw missing, installing from backup..."
fi

# --- Copy nvidia.raw if needed ---
if [ "$NEED_COPY" = "true" ]; then
    log "Unmerging sysext..."
    systemd-sysext unmerge 2>/dev/null || true

    log "Making /usr writable..."
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=off "$USR_DATASET"
    fi

    log "Copying nvidia.raw from backup..."
    if ! cp "$NVIDIA_RAW_BACKUP" "$SYSEXT_TARGET"; then
        log "ERROR: Failed to copy nvidia.raw from backup"
        [ -n "$USR_DATASET" ] && zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        exit 0
    fi

    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET"
    fi
fi

# --- Ensure nvidia symlink exists (always, even if copy was skipped) ---
if [ ! -L /etc/extensions/nvidia.raw ] || [ "$(readlink /etc/extensions/nvidia.raw)" != "$SYSEXT_TARGET" ]; then
    log "Creating nvidia symlink in /etc/extensions/..."
    mkdir -p /etc/extensions
    ln -sf "$SYSEXT_TARGET" /etc/extensions/nvidia.raw
    NEED_MERGE=true
else
    log "nvidia symlink already correct"
    NEED_MERGE=false
fi

# --- Merge sysext if we copied or fixed the symlink ---
if [ "$NEED_COPY" = "true" ] || [ "$NEED_MERGE" = "true" ]; then
    log "Merging sysext..."
    systemd-sysext unmerge 2>/dev/null || true
    systemd-sysext merge
    log "Reloading systemd..."
    systemctl daemon-reload
fi

# --- Enable GPU persistence mode ---
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
    log "Starting nvidia-persistenced..."
    systemctl start nvidia-persistenced.service 2>/dev/null || log "WARNING: nvidia-persistenced failed"
else
    log "Enabling persistence mode via nvidia-smi..."
    /usr/bin/nvidia-smi -pm 1 2>/dev/null || log "WARNING: Could not enable persistence mode"
fi

# --- Start MIG setup service (recreates instances + remaps UUIDs) ---
if systemctl list-unit-files nvidia-mig-setup.service &>/dev/null; then
    log "Starting nvidia-mig-setup.service..."
    systemctl start nvidia-mig-setup.service 2>/dev/null || log "WARNING: nvidia-mig-setup failed"
fi

# --- Restart Docker with NVIDIA support ---
log "Re-enabling NVIDIA in Docker..."
midclt call docker.update '{"nvidia": true}' 2>/dev/null \
    || log "WARNING: Failed to re-enable NVIDIA in Docker"

log "nvidia.raw reinstalled successfully"
exit 0
PREINIT_EOF
chmod +x "${PERSIST_DIR}/nvidia-preinit.sh"

# --- Register PREINIT script via midclt ---
PREINIT_SCRIPT="${PERSIST_DIR}/nvidia-preinit.sh"
echo "Registering PREINIT script..."

EXISTING_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get('command', '') or s.get('script', '')
        if 'nvidia-preinit' in cmd or 'nvidia-postinit' in cmd or 'nvidia-gpu' in cmd:
            print(s['id'], end='')
            break
except Exception:
    pass
" 2>/dev/null)

if [ -n "$EXISTING_ID" ]; then
    echo "PREINIT script already registered (id: ${EXISTING_ID}), updating..."
    midclt call initshutdownscript.update "$EXISTING_ID" "{\"type\": \"COMMAND\", \"command\": \"${PREINIT_SCRIPT}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 30, \"comment\": \"Reinstall custom NVIDIA sysext before services start\"}" 2>/dev/null \
        || echo "WARNING: Failed to update PREINIT script"
else
    midclt call initshutdownscript.create "{\"type\": \"COMMAND\", \"command\": \"${PREINIT_SCRIPT}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": 30, \"comment\": \"Reinstall custom NVIDIA sysext before services start\"}" 2>/dev/null \
        || echo "WARNING: Failed to register PREINIT script"
    echo "PREINIT script registered"
fi

# --- MIG configuration ---
if [ -n "$MIG_PROFILES" ]; then
    echo ""
    echo "=== MIG Configuration ==="
    cat > "${PERSIST_DIR}/mig.conf" <<MIGEOF
# MIG profile IDs passed to: nvidia-smi mig -cgi <PROFILES> -C
# See available profiles: nvidia-smi mig -lgip
MIG_PROFILES=${MIG_PROFILES}
MIGEOF
    echo "MIG config written to ${PERSIST_DIR}/mig.conf"
    echo "  Profiles: ${MIG_PROFILES}"

    # Enable the MIG setup service (daemon-reload already done after sysext merge)
    systemctl enable nvidia-mig-setup.service 2>/dev/null \
        && echo "nvidia-mig-setup.service enabled" \
        || echo "WARNING: Could not enable nvidia-mig-setup.service"

    # Ensure sysext overlay is still intact before MIG operations
    # (middleware async sysext remount from docker.update can remove nvidia symlink)
    if ! [ -x /usr/bin/nvidia-smi ]; then
        echo "[diag] nvidia-smi disappeared before MIG enable"
        echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"
        echo "[diag] /etc/extensions/: $(ls /etc/extensions/ 2>&1)"
        echo "[diag] Recreating nvidia symlink and re-merging..."
        mkdir -p /etc/extensions
        ln -sf "${NVIDIA_RAW}" /etc/extensions/nvidia.raw
        systemd-sysext unmerge 2>/dev/null || true
        systemd-sysext merge
        systemctl daemon-reload
        echo "[diag] After re-merge: nvidia-smi exists=$(ls /usr/bin/nvidia-smi 2>&1)"
        echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"
        if ! [ -x /usr/bin/nvidia-smi ]; then
            echo "[diag] ERROR: nvidia-smi still missing after re-merge!"
            echo "[diag] Extensions dir: $(ls /usr/share/truenas/sysext-extensions/ 2>&1)"
        fi
    fi

    # Enable MIG mode on the GPU
    MIG_CURRENT=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CURRENT" != "Enabled" ]; then
        echo "Enabling MIG mode..."
        /usr/bin/nvidia-smi -mig 1 2>/dev/null \
            || { echo "WARNING: Could not enable MIG mode"; }

        # Check if MIG activated immediately or needs reboot
        MIG_CURRENT=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
        MIG_PENDING=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.pending --format=csv,noheader 2>/dev/null || echo "N/A")
        if [ "$MIG_CURRENT" = "Enabled" ]; then
            echo "MIG mode activated immediately"
        elif [ "$MIG_PENDING" = "Enabled" ]; then
            echo "MIG mode enabled (pending). Reboot required to activate."
            NEEDS_REBOOT=true
        fi
    else
        echo "MIG mode already enabled"
    fi

    # Create MIG instances now if MIG is active
    MIG_CURRENT=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CURRENT" = "Enabled" ]; then
        echo "Creating MIG instances: ${MIG_PROFILES}"
        /usr/bin/nvidia-smi mig -dci 2>/dev/null || true
        /usr/bin/nvidia-smi mig -dgi 2>/dev/null || true
        if /usr/bin/nvidia-smi mig -cgi "$MIG_PROFILES" -C; then
            echo "MIG instances created successfully"
            echo "[diag] Right after MIG creation: nvidia-smi exists=$(ls /usr/bin/nvidia-smi 2>&1)"
            echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"
            echo ""

            # Build MIG device list with types
            # Use MIG_PROFILES order (matches creation order = UUID order)
            echo "[diag] Before MIG enumeration: nvidia-smi exists=$(ls /usr/bin/nvidia-smi 2>&1)"
            echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"

            # Ensure sysext overlay is still intact (middleware async remount removes nvidia symlink)
            if ! [ -x /usr/bin/nvidia-smi ]; then
                echo "[diag] nvidia-smi disappeared before enumeration"
                echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"
                echo "[diag] /etc/extensions/: $(ls /etc/extensions/ 2>&1)"
                echo "[diag] Recreating nvidia symlink and re-merging..."
                mkdir -p /etc/extensions
                ln -sf "${NVIDIA_RAW}" /etc/extensions/nvidia.raw
                systemd-sysext unmerge 2>/dev/null || true
                systemd-sysext merge
                systemctl daemon-reload
                echo "[diag] After re-merge: nvidia-smi exists=$(ls /usr/bin/nvidia-smi 2>&1)"
                echo "[diag] sysext status: $(systemd-sysext status 2>&1 | head -3)"
                if ! [ -x /usr/bin/nvidia-smi ]; then
                    echo "[diag] ERROR: nvidia-smi still missing after re-merge!"
                    echo "[diag] Extensions dir: $(ls /usr/share/truenas/sysext-extensions/ 2>&1)"
                fi
            fi

            mapfile -t MIG_UUIDS < <(/usr/bin/nvidia-smi -L 2>/dev/null | grep 'MIG' | sed -n 's/.*UUID: \(MIG-[^)]*\)).*/\1/p')
            mapfile -t MIG_NAMES < <(/usr/bin/nvidia-smi -L 2>/dev/null | grep 'MIG' | sed 's/.*MIG /MIG /' | sed 's/[[:space:]]*Device.*//')

            echo "[diag] MIG enumeration result: ${#MIG_UUIDS[@]} UUIDs found"
            if [ "${#MIG_UUIDS[@]}" -eq 0 ]; then
                echo "WARNING: Could not enumerate MIG devices"
                echo "[diag] nvidia-smi -L full output:"
                /usr/bin/nvidia-smi -L 2>&1 || echo "[diag] nvidia-smi -L failed with exit code $?"
                echo "[diag] nvidia-smi mig -lgi:"
                /usr/bin/nvidia-smi mig -lgi 2>&1 || true
            fi
            IFS=',' read -ra PROFILE_ARRAY <<< "$MIG_PROFILES"

            echo "=== MIG Devices ==="
            for i in "${!MIG_UUIDS[@]}"; do
                pid="${PROFILE_ARRAY[$i]:-unknown}"
                case "$pid" in
                    47) dtype="gfx + compute (1g.24gb)" ;;
                    35) dtype="gfx + compute (2g.48gb)" ;;
                    32) dtype="gfx + compute (4g.96gb)" ;;
                    14) dtype="compute only (1g.24gb)" ;;
                    5)  dtype="compute only (2g.48gb)" ;;
                    0)  dtype="compute only (4g.96gb)" ;;
                    64) dtype="compute + all media engines (2g.48gb)" ;;
                    21) dtype="compute + all media engines (1g.24gb)" ;;
                    65) dtype="compute + all media engines (1g.24gb)" ;;
                    67) dtype="compute, no media (1g.24gb)" ;;
                    66) dtype="compute, no media (2g.48gb)" ;;
                    *)  dtype="profile $pid" ;;
                esac
                echo "  [$((i+1))] ${MIG_NAMES[$i]:-MIG}  —  ${dtype}"
                echo "        ${MIG_UUIDS[$i]}"
            done

            # Get PCI slot for GPU assignments
            PCI_SLOT=$(midclt call app.gpu_choices 2>/dev/null \
                | python3 -c "
import sys, json
try:
    choices = json.load(sys.stdin)
    for slot, info in choices.items():
        if isinstance(info, dict):
            vendor = (info.get('vendor') or '').upper()
            desc = (info.get('description') or '').upper()
            if 'NVIDIA' in vendor or 'NVIDIA' in desc:
                print(slot, end='')
                break
        elif isinstance(info, str) and 'NVIDIA' in info.upper():
            print(slot, end='')
            break
except Exception:
    pass
" 2>/dev/null)

            # Now re-enable Docker — all nvidia-smi usage is done
            echo ""
            echo "Re-enabling NVIDIA in Docker..."
            midclt call docker.update '{"nvidia": true}'

            # Wait for Docker and app service to be ready
            echo "Waiting for Docker and app service to come up (this can take 60-90s)..."
            MAX_WAIT=18  # 18 × 5s = 90s
            APP_COUNT=0
            for attempt in $(seq 1 $MAX_WAIT); do
                APP_COUNT=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)
" 2>/dev/null)
                if [ "${APP_COUNT:-0}" -gt 0 ]; then
                    echo ""
                    echo "App service ready (${APP_COUNT} apps found)"
                    break
                fi

                if [ "$attempt" -lt "$MAX_WAIT" ]; then
                    printf "\r  Waiting... %ds / %ds" "$((attempt * 5))" "$((MAX_WAIT * 5))"
                    sleep 5
                else
                    echo ""
                    echo "WARNING: Timed out waiting for apps after $((MAX_WAIT * 5))s."
                    echo "  You can assign MIG devices to apps later via TrueNAS UI or:"
                    echo "  midclt call app.update APP_NAME '{\"values\":{\"resources\":{\"gpus\":{...}}}}'"
                fi
            done

            # Get list of TrueNAS app names
            mapfile -t APP_NAMES < <(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    apps = json.load(sys.stdin)
    for app in apps:
        name = app.get('name', '')
        if name:
            print(name)
except Exception:
    pass
" 2>/dev/null)

            # --- Interactive MIG-to-app assignment loop ---
            if [ "${#APP_NAMES[@]}" -gt 0 ] && [ -n "$PCI_SLOT" ] && [ -e /dev/tty ]; then
                echo ""
                echo "=== Assign MIG devices to TrueNAS apps ==="
                echo "Create mappings one at a time. Enter 0 at any prompt to finish."
                echo ""

                # Track staged assignments: parallel arrays
                STAGED_APP=()    # app name per assignment
                STAGED_UUID=()   # MIG UUID per assignment
                STAGED_DEV=()    # device display number per assignment
                STAGED_DTYPE=()  # device type string per assignment

                while true; do
                    # Show MIG devices with current staged assignments
                    echo "--- MIG Devices ---"
                    for i in "${!MIG_UUIDS[@]}"; do
                        pid="${PROFILE_ARRAY[$i]:-unknown}"
                        case "$pid" in
                            47) dtype="gfx + compute (1g.24gb)" ;;
                            35) dtype="gfx + compute (2g.48gb)" ;;
                            32) dtype="gfx + compute (4g.96gb)" ;;
                            14) dtype="compute only (1g.24gb)" ;;
                            5)  dtype="compute only (2g.48gb)" ;;
                            0)  dtype="compute only (4g.96gb)" ;;
                            64) dtype="compute + all media engines (2g.48gb)" ;;
                            21) dtype="compute + all media engines (1g.24gb)" ;;
                            65) dtype="compute + all media engines (1g.24gb)" ;;
                            67) dtype="compute, no media (1g.24gb)" ;;
                            66) dtype="compute, no media (2g.48gb)" ;;
                            *)  dtype="profile $pid" ;;
                        esac
                        # Collect all apps staged for this UUID
                        assigned_to=""
                        for j in "${!STAGED_UUID[@]}"; do
                            if [ "${STAGED_UUID[$j]}" = "${MIG_UUIDS[$i]}" ]; then
                                if [ -n "$assigned_to" ]; then
                                    assigned_to="${assigned_to}, ${STAGED_APP[$j]}"
                                else
                                    assigned_to="${STAGED_APP[$j]}"
                                fi
                            fi
                        done
                        if [ -n "$assigned_to" ]; then
                            echo "  [$((i+1))] ${dtype}  -->  ${assigned_to}"
                        else
                            echo "  [$((i+1))] ${dtype}"
                        fi
                        echo "        ${MIG_UUIDS[$i]}"
                    done

                    echo ""
                    printf "Select MIG device number (0 to finish): "
                    read -r dev_num </dev/tty || break
                    [ "$dev_num" = "0" ] && break

                    if ! [[ "$dev_num" =~ ^[0-9]+$ ]]; then
                        echo "  Invalid input. Enter a device number."
                        echo ""
                        continue
                    fi
                    dev_idx=$((dev_num - 1))
                    if [ "$dev_idx" -lt 0 ] || [ "$dev_idx" -ge "${#MIG_UUIDS[@]}" ]; then
                        echo "  Invalid device number: $dev_num"
                        echo ""
                        continue
                    fi

                    sel_uuid="${MIG_UUIDS[$dev_idx]}"
                    sel_pid="${PROFILE_ARRAY[$dev_idx]:-unknown}"
                    case "$sel_pid" in
                        47) sel_dtype="gfx + compute (1g.24gb)" ;;
                        35) sel_dtype="gfx + compute (2g.48gb)" ;;
                        32) sel_dtype="gfx + compute (4g.96gb)" ;;
                        14) sel_dtype="compute only (1g.24gb)" ;;
                        5)  sel_dtype="compute only (2g.48gb)" ;;
                        0)  sel_dtype="compute only (4g.96gb)" ;;
                        64) sel_dtype="compute + all media engines (2g.48gb)" ;;
                        21) sel_dtype="compute + all media engines (1g.24gb)" ;;
                        65) sel_dtype="compute + all media engines (1g.24gb)" ;;
                        67) sel_dtype="compute, no media (1g.24gb)" ;;
                        66) sel_dtype="compute, no media (2g.48gb)" ;;
                        *)  sel_dtype="profile $sel_pid" ;;
                    esac

                    # Show apps list with any existing staged assignments
                    echo ""
                    echo "--- Apps ---"
                    for i in "${!APP_NAMES[@]}"; do
                        # Check if this app already has a staged assignment
                        app_assigned=""
                        for j in "${!STAGED_APP[@]}"; do
                            if [ "${STAGED_APP[$j]}" = "${APP_NAMES[$i]}" ]; then
                                app_assigned="${STAGED_DTYPE[$j]}"
                            fi
                        done
                        if [ -n "$app_assigned" ]; then
                            echo "  [$((i+1))] ${APP_NAMES[$i]}  <--  ${app_assigned}"
                        else
                            echo "  [$((i+1))] ${APP_NAMES[$i]}"
                        fi
                    done

                    echo ""
                    printf "Assign device %d (%s) to app number (0 to cancel): " "$dev_num" "$sel_dtype"
                    read -r app_num </dev/tty || break
                    [ "$app_num" = "0" ] && echo "" && continue

                    if ! [[ "$app_num" =~ ^[0-9]+$ ]]; then
                        echo "  Invalid input. Enter an app number."
                        echo ""
                        continue
                    fi
                    app_idx=$((app_num - 1))
                    if [ "$app_idx" -lt 0 ] || [ "$app_idx" -ge "${#APP_NAMES[@]}" ]; then
                        echo "  Invalid app number: $app_num"
                        echo ""
                        continue
                    fi

                    sel_app="${APP_NAMES[$app_idx]}"

                    # Remove any previous staging for this app (override)
                    NEW_STAGED_APP=()
                    NEW_STAGED_UUID=()
                    NEW_STAGED_DEV=()
                    NEW_STAGED_DTYPE=()
                    for j in "${!STAGED_APP[@]}"; do
                        if [ "${STAGED_APP[$j]}" != "$sel_app" ]; then
                            NEW_STAGED_APP+=("${STAGED_APP[$j]}")
                            NEW_STAGED_UUID+=("${STAGED_UUID[$j]}")
                            NEW_STAGED_DEV+=("${STAGED_DEV[$j]}")
                            NEW_STAGED_DTYPE+=("${STAGED_DTYPE[$j]}")
                        fi
                    done
                    STAGED_APP=("${NEW_STAGED_APP[@]+"${NEW_STAGED_APP[@]}"}")
                    STAGED_UUID=("${NEW_STAGED_UUID[@]+"${NEW_STAGED_UUID[@]}"}")
                    STAGED_DEV=("${NEW_STAGED_DEV[@]+"${NEW_STAGED_DEV[@]}"}")
                    STAGED_DTYPE=("${NEW_STAGED_DTYPE[@]+"${NEW_STAGED_DTYPE[@]}"}")

                    # Stage the assignment
                    STAGED_APP+=("$sel_app")
                    STAGED_UUID+=("$sel_uuid")
                    STAGED_DEV+=("$dev_num")
                    STAGED_DTYPE+=("$sel_dtype")

                    echo "  Staged: device $dev_num ($sel_dtype) --> $sel_app"
                    echo ""
                done

                # --- Confirmation and apply ---
                if [ "${#STAGED_APP[@]}" -gt 0 ]; then
                    echo ""
                    echo "=== Assignment Summary ==="
                    for i in "${!STAGED_APP[@]}"; do
                        echo "  Device ${STAGED_DEV[$i]} (${STAGED_DTYPE[$i]})  -->  ${STAGED_APP[$i]}"
                        echo "    ${STAGED_UUID[$i]}"
                    done
                    echo ""
                    printf "Apply these assignments? [Y/n] "
                    read -r confirm </dev/tty || confirm="y"
                    case "$confirm" in
                        [nN]*)
                            echo "Assignments discarded."
                            ;;
                        *)
                            ASSIGNED_APPS=()
                            for i in "${!STAGED_APP[@]}"; do
                                echo "  Assigning device ${STAGED_DEV[$i]} to ${STAGED_APP[$i]}..."
                                if midclt call app.update "${STAGED_APP[$i]}" "{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"$PCI_SLOT\":{\"use_gpu\":true,\"uuid\":\"${STAGED_UUID[$i]}\"}}}}}}" 2>/dev/null; then
                                    echo "    OK"
                                    ASSIGNED_APPS+=("${STAGED_APP[$i]}")
                                else
                                    echo "    WARNING: Failed to update ${STAGED_APP[$i]}"
                                fi
                            done
                            echo "All assignments applied."

                            # Restart assigned apps so they pick up the new GPU config
                            if [ "${#ASSIGNED_APPS[@]}" -gt 0 ]; then
                                echo ""
                                echo "Restarting assigned apps..."
                                for app_name in "${ASSIGNED_APPS[@]}"; do
                                    printf "  Restarting %s..." "$app_name"
                                    if midclt call app.redeploy "$app_name" 2>/dev/null; then
                                        echo " OK"
                                    else
                                        echo " WARNING: Failed to restart $app_name"
                                    fi
                                done
                            fi
                            ;;
                    esac
                else
                    echo "No assignments made."
                fi
            fi
        else
            echo "WARNING: Failed to create MIG instances"
        fi
    fi
fi

# Ensure Docker is re-enabled (safety net — MIG path does this above,
# but non-MIG path or early exits may not have)
midclt call docker.update '{"nvidia": true}' 2>/dev/null || true

echo ""
echo "=== Persistence setup complete ==="
echo ""
echo "Persistent config: ${PERSIST_DIR}/"
echo "  nvidia.raw      — backup for post-update reinstall"
echo "  nvidia-preinit.sh — runs on every boot (registered as PREINIT)"
[ -n "$MIG_PROFILES" ] && echo "  mig.conf         — MIG profiles: ${MIG_PROFILES}"
echo ""
if [ "${NEEDS_REBOOT:-false}" = "true" ]; then
    echo "*** REBOOT REQUIRED ***"
    echo "MIG mode has been enabled but requires a reboot to activate."
    echo "After reboot, MIG instances will be automatically created"
    echo "and app GPU UUIDs will be remapped."
else
    echo "After reboot, MIG instances will be automatically recreated"
    echo "and app GPU UUIDs will be remapped."
fi
