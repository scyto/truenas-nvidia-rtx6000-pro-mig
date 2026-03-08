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
        --mig-profiles=*) MIG_PROFILES="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --help)
            echo "Usage: sudo ./install.sh [OPTIONS] [path-to-nvidia.raw]"
            echo ""
            echo "Options:"
            echo "  --mig-profiles=PROFILES  MIG profile IDs (e.g., 47,47,14,14)"
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

# Disable NVIDIA support temporarily
echo "Disabling NVIDIA support..."
midclt call docker.update '{"nvidia": false}'
systemd-sysext unmerge

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr)
echo "Setting ${USR_DATASET} to writable..."
zfs set readonly=off "${USR_DATASET}"

# Backup existing nvidia.raw
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
echo "Merging sysext and re-enabling NVIDIA..."
systemd-sysext merge
systemctl daemon-reload
midclt call docker.update '{"nvidia": true}'

# Enable GPU persistence mode
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
    echo "Starting nvidia-persistenced..."
    systemctl start nvidia-persistenced.service 2>/dev/null \
        && echo "nvidia-persistenced started" \
        || echo "WARNING: Could not start nvidia-persistenced"
else
    echo "Enabling persistence mode via nvidia-smi..."
    nvidia-smi -pm 1 2>/dev/null \
        && echo "Persistence mode enabled" \
        || echo "WARNING: Could not enable persistence mode"
fi

echo ""
echo "=== Installation complete ==="
echo ""

# Verify
if command -v nvidia-smi &>/dev/null; then
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
    PERSIST=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null || echo "unknown")
    MIG_CUR=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "unknown")
    echo "Driver: ${DRIVER_VER}  |  Persistence: ${PERSIST}  |  MIG: ${MIG_CUR}"
else
    echo "nvidia-smi not found — you may need to restart Docker services"
fi

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
echo "Backing up nvidia.raw to persistent storage..."
cp /tmp/nvidia.raw "${PERSIST_DIR}/nvidia.raw"

# --- Write PREINIT script to persistent storage ---
# NOTE: This is an inline copy of scripts/nvidia-postinit.sh.
# Keep both copies in sync when making changes.
echo "Writing PREINIT script..."
cat > "${PERSIST_DIR}/nvidia-postinit.sh" <<'POSTINIT_EOF'
#!/usr/bin/env bash
# TrueNAS PREINIT script: reinstalls nvidia.raw sysext after OS updates.
# Stored on persistent pool; registered via midclt during install.
# Runs before services start, ensuring GPU drivers are available for Docker.

set -uo pipefail

log() { echo "[nvidia-postinit] $*"; }

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

# --- Compare checksums ---
if [ -f "$SYSEXT_TARGET" ]; then
    INSTALLED_SUM=$(sha256sum "$SYSEXT_TARGET" | awk '{print $1}')
    BACKUP_SUM=$(sha256sum "$NVIDIA_RAW_BACKUP" | awk '{print $1}')
    if [ "$INSTALLED_SUM" = "$BACKUP_SUM" ]; then
        log "nvidia.raw already matches backup, skipping"
        exit 0
    fi
    log "nvidia.raw differs from backup (update detected), reinstalling..."
else
    log "nvidia.raw missing, installing from backup..."
fi

# --- Reinstall nvidia.raw ---
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
    # Restore readonly before exiting
    [ -n "$USR_DATASET" ] && zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
    exit 0
fi

if [ -n "$USR_DATASET" ]; then
    zfs set readonly=on "$USR_DATASET"
fi

log "Merging sysext..."
systemd-sysext merge

log "Reloading systemd..."
systemctl daemon-reload

# --- Enable GPU persistence mode ---
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
    log "Starting nvidia-persistenced..."
    systemctl start nvidia-persistenced.service 2>/dev/null || log "WARNING: nvidia-persistenced failed"
else
    log "Enabling persistence mode via nvidia-smi..."
    nvidia-smi -pm 1 2>/dev/null || log "WARNING: Could not enable persistence mode"
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
POSTINIT_EOF
chmod +x "${PERSIST_DIR}/nvidia-postinit.sh"

# --- Register PREINIT script via midclt ---
PREINIT_SCRIPT="${PERSIST_DIR}/nvidia-postinit.sh"
echo "Registering PREINIT script..."

EXISTING_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get('command', '') or s.get('script', '')
        if 'nvidia-postinit' in cmd or 'nvidia-gpu' in cmd:
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

    # Enable MIG mode on the GPU
    MIG_CURRENT=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CURRENT" != "Enabled" ]; then
        echo "Enabling MIG mode..."
        nvidia-smi -mig 1 2>/dev/null \
            || { echo "WARNING: Could not enable MIG mode"; }

        # Check if MIG activated immediately or needs reboot
        MIG_CURRENT=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
        MIG_PENDING=$(nvidia-smi --query-gpu=mig.mode.pending --format=csv,noheader 2>/dev/null || echo "N/A")
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
    MIG_CURRENT=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CURRENT" = "Enabled" ]; then
        echo "Creating MIG instances: ${MIG_PROFILES}"
        nvidia-smi mig -dci 2>/dev/null || true
        nvidia-smi mig -dgi 2>/dev/null || true
        if nvidia-smi mig -cgi "$MIG_PROFILES" -C; then
            echo "MIG instances created successfully"
            echo ""

            # Build MIG device list with types
            # Correlate -lgi (profile IDs + GI IDs) with -L (UUIDs) by position
            mapfile -t MIG_UUIDS < <(nvidia-smi -L 2>/dev/null | grep -oP 'MIG.*UUID:\s+\K[^)]+')
            mapfile -t MIG_NAMES < <(nvidia-smi -L 2>/dev/null | grep 'MIG' | sed 's/.*MIG /MIG /' | sed 's/Device.*//')
            mapfile -t MIG_PROFILE_IDS < <(nvidia-smi mig -lgi 2>/dev/null | grep -oP 'Profile ID\s+:\s+\K[0-9]+')

            echo "=== MIG Devices ==="
            for i in "${!MIG_UUIDS[@]}"; do
                pid="${MIG_PROFILE_IDS[$i]:-unknown}"
                case "$pid" in
                    47|35|32) dtype="gfx+compute" ;;
                    14|5|0)   dtype="compute-only" ;;
                    64|21|65) dtype="compute+media" ;;
                    67|66)    dtype="compute (no media)" ;;
                    *)        dtype="unknown" ;;
                esac
                echo "  [$((i+1))] ${MIG_NAMES[$i]:-MIG}  (${dtype})  ${MIG_UUIDS[$i]}"
            done

            # Get PCI slot for GPU assignments
            PCI_SLOT=$(midclt call app.gpu_choices 2>/dev/null \
                | python3 -c "
import sys, json
try:
    choices = json.load(sys.stdin)
    for slot, desc in choices.items():
        if 'nvidia' in desc.lower() or 'NVIDIA' in desc:
            print(slot, end='')
            break
except Exception:
    pass
" 2>/dev/null)

            # Get list of TrueNAS apps
            mapfile -t APP_NAMES < <(midclt call app.query 2>/dev/null \
                | python3 -c "
import sys, json
try:
    apps = json.load(sys.stdin)
    for app in apps:
        print(app.get('name', ''))
except Exception:
    pass
" 2>/dev/null)

            # Show current app GPU assignments
            echo ""
            echo "Current app GPU assignments:"
            midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    apps = json.load(sys.stdin)
    found = False
    for app in apps:
        name = app.get('name', '')
        config = app.get('config', {}) or {}
        resources = config.get('resources', {}) or {}
        gpus = resources.get('gpus', {}) or {}
        gpu_sel = gpus.get('nvidia_gpu_selection', {}) or {}
        for slot, slot_cfg in gpu_sel.items():
            if isinstance(slot_cfg, dict) and slot_cfg.get('use_gpu'):
                uuid = slot_cfg.get('uuid', 'none')
                print(f'  {name}: {uuid}')
                found = True
    if not found:
        print('  (no apps with GPU assignments)')
except Exception:
    print('  (could not query apps)')
" 2>/dev/null || echo "  (could not query apps)"

            # Interactive assignment (only if we have apps, a PCI slot, and a tty)
            if [ "${#APP_NAMES[@]}" -gt 0 ] && [ -n "$PCI_SLOT" ] && [ -t 0 ] || [ -e /dev/tty ]; then
                echo ""
                echo "=== Assign MIG devices to apps ==="
                echo "Available apps:"
                for i in "${!APP_NAMES[@]}"; do
                    echo "  [$((i+1))] ${APP_NAMES[$i]}"
                done

                echo ""
                echo "Enter assignments as DEVICE_NUM=APP_NUM (e.g., 1=3), one per line."
                echo "Press Enter on a blank line when done."
                echo ""
                while true; do
                    printf "Assign: " >&2
                    if [ -t 0 ]; then
                        read -r assignment
                    else
                        read -r assignment </dev/tty || break
                    fi
                    [ -z "$assignment" ] && break

                    dev_num="${assignment%%=*}"
                    app_num="${assignment##*=}"

                    # Validate
                    if ! [[ "$dev_num" =~ ^[0-9]+$ ]] || ! [[ "$app_num" =~ ^[0-9]+$ ]]; then
                        echo "  Invalid format. Use DEVICE_NUM=APP_NUM (e.g., 1=3)"
                        continue
                    fi

                    dev_idx=$((dev_num - 1))
                    app_idx=$((app_num - 1))

                    if [ "$dev_idx" -lt 0 ] || [ "$dev_idx" -ge "${#MIG_UUIDS[@]}" ]; then
                        echo "  Invalid device number: $dev_num"
                        continue
                    fi
                    if [ "$app_idx" -lt 0 ] || [ "$app_idx" -ge "${#APP_NAMES[@]}" ]; then
                        echo "  Invalid app number: $app_num"
                        continue
                    fi

                    sel_uuid="${MIG_UUIDS[$dev_idx]}"
                    sel_app="${APP_NAMES[$app_idx]}"

                    echo "  Assigning ${sel_uuid} to ${sel_app}..."
                    if midclt call app.update "$sel_app" "{\"values\":{\"resources\":{\"gpus\":{\"use_all_gpus\":false,\"nvidia_gpu_selection\":{\"$PCI_SLOT\":{\"use_gpu\":true,\"uuid\":\"$sel_uuid\"}}}}}}" 2>/dev/null; then
                        echo "  Assigned MIG device $dev_num to ${sel_app}"
                    else
                        echo "  WARNING: Failed to assign MIG device to ${sel_app}"
                    fi
                done
            fi
        else
            echo "WARNING: Failed to create MIG instances"
        fi
    fi
fi

echo ""
echo "=== Persistence setup complete ==="
echo ""
echo "Persistent config: ${PERSIST_DIR}/"
echo "  nvidia.raw      — backup for post-update reinstall"
echo "  nvidia-postinit.sh — runs on every boot (registered as PREINIT)"
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
