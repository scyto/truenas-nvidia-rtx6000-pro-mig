#!/usr/bin/env bash
# Restores the original nvidia.raw from backup and cleans up MIG + persistence.
# Looks for the original nvidia.raw in persistent storage first, then /usr.

set -euo pipefail

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
NVIDIA_RAW="${SYSEXT_DIR}/nvidia.raw"
NVIDIA_BAK="${SYSEXT_DIR}/nvidia.raw.bak"

# --- Find original nvidia.raw backup ---
# Prefer persistent copy in .config (survives TrueNAS updates and repeated restores)
ORIGINAL_BAK=""
for f in /mnt/*/.config/nvidia-gpu/nvidia-original.raw; do
    [ -f "$f" ] && ORIGINAL_BAK="$f" && break
done
# Fallback to .bak in /usr (created during install, but fragile)
if [ -z "$ORIGINAL_BAK" ] && [ -f "$NVIDIA_BAK" ]; then
    ORIGINAL_BAK="$NVIDIA_BAK"
fi

RESTORE_SYSEXT=true
if [ -z "$ORIGINAL_BAK" ]; then
    echo "NOTE: No original nvidia.raw backup found. Will clean up MIG and persistence only."
    RESTORE_SYSEXT=false
fi

echo "=== Restore / Cleanup ==="

# --- Step 1: Stop Docker/apps so GPU is released ---
echo "Stopping Docker and apps (releasing GPU)..."
midclt call docker.update '{"nvidia": false}'

echo "Waiting for GPU processes to stop..."
for attempt in $(seq 1 24); do
    GPU_PROCS=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
    if [ "${GPU_PROCS:-0}" -eq 0 ]; then
        echo "GPU released (no processes running)"
        break
    fi
    if [ "$attempt" -lt 24 ]; then
        printf "\r  Waiting for %d GPU process(es) to stop... %ds / 120s" "$GPU_PROCS" "$((attempt * 5))"
        sleep 5
    else
        echo ""
        echo "WARNING: GPU processes still running after 120s, proceeding anyway"
    fi
done

# --- Step 2: Clean up MIG (while GPU is free) ---
echo ""
echo "=== Cleaning up MIG ==="

echo "Destroying MIG instances..."
/usr/bin/nvidia-smi mig -dci 2>/dev/null || true
/usr/bin/nvidia-smi mig -dgi 2>/dev/null || true

MIG_CUR=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
if [ "$MIG_CUR" = "Enabled" ]; then
    echo "Disabling MIG mode..."
    /usr/bin/nvidia-smi -mig 0 2>/dev/null || true
    MIG_CUR_AFTER=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CUR_AFTER" = "Enabled" ]; then
        echo "MIG mode disabled (pending). Will take effect after reboot."
    else
        echo "MIG mode disabled"
    fi
fi

systemctl disable nvidia-mig-setup.service 2>/dev/null || true

# --- Step 3: Replace nvidia.raw (if we have the original) ---
if [ "$RESTORE_SYSEXT" = "true" ]; then
    echo ""
    echo "=== Restoring original nvidia.raw ==="
    echo "Using backup: ${ORIGINAL_BAK}"

    systemd-sysext unmerge

    USR_DATASET=$(zfs list -H -o name /usr)
    zfs set readonly=off "${USR_DATASET}"

    cp "$ORIGINAL_BAK" "${NVIDIA_RAW}"
    # Clean up the .bak in /usr if it exists (must be while writable)
    [ -f "${NVIDIA_BAK}" ] && rm -f "${NVIDIA_BAK}" 2>/dev/null || true

    zfs set readonly=on "${USR_DATASET}"

    echo "Ensuring nvidia symlink in /etc/extensions/..."
    ln -sf "${NVIDIA_RAW}" /etc/extensions/nvidia.raw

    echo "Merging sysext and re-enabling NVIDIA..."
    systemd-sysext merge
    systemctl daemon-reload
fi

midclt call docker.update '{"nvidia": true}'

echo ""
if command -v /usr/bin/nvidia-smi &>/dev/null; then
    echo "Driver version: $(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'unknown')"
fi

# --- Step 4: Clean up persistence ---
echo ""
echo "=== Cleaning up persistence ==="

# Deregister PREINIT script
PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
    | python3 -c "
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        if 'nvidia-postinit' in s.get('script', '') or 'nvidia-postinit' in s.get('command', '') or 'nvidia-gpu' in s.get('script', '') or 'nvidia-gpu' in s.get('command', ''):
            print(s['id'], end='')
            break
except Exception:
    pass
" 2>/dev/null)

if [ -n "$PREINIT_ID" ]; then
    midclt call initshutdownscript.delete "$PREINIT_ID" 2>/dev/null \
        && echo "PREINIT script deregistered (id: ${PREINIT_ID})" \
        || echo "WARNING: Failed to deregister PREINIT script"
else
    echo "No PREINIT script found to deregister"
fi

# Remove persistent config (including nvidia-original.raw and custom nvidia.raw)
for d in /mnt/*/.config/nvidia-gpu; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"

# --- Step 5: Wait for Docker to settle ---
echo ""
echo "Waiting for Docker to settle..."
for attempt in $(seq 1 18); do
    APP_COUNT=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)
" 2>/dev/null)
    if [ "${APP_COUNT:-0}" -gt 0 ]; then
        echo "Docker is ready (${APP_COUNT} apps). Safe to re-run install."
        break
    fi
    if [ "$attempt" -lt 18 ]; then
        printf "\r  Waiting... %ds / 90s" "$((attempt * 5))"
        sleep 5
    else
        echo ""
        echo "Docker still settling. Wait a few more seconds before running install."
    fi
done
