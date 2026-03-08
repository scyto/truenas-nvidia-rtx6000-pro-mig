#!/usr/bin/env bash
# Restores the original nvidia.raw from backup.
# Run this if you need to roll back to the TrueNAS-shipped driver.

set -euo pipefail

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
NVIDIA_RAW="${SYSEXT_DIR}/nvidia.raw"
NVIDIA_BAK="${SYSEXT_DIR}/nvidia.raw.bak"

if [ ! -f "${NVIDIA_BAK}" ]; then
    echo "ERROR: No backup found at ${NVIDIA_BAK}"
    echo "Cannot restore — the original nvidia.raw was not backed up during install."
    exit 1
fi

echo "=== Restoring original nvidia.raw ==="

# Disable NVIDIA support temporarily
echo "Disabling NVIDIA support..."
midclt call docker.update '{"nvidia": false}'
systemd-sysext unmerge

# Make /usr writable
USR_DATASET=$(zfs list -H -o name /usr)
zfs set readonly=off "${USR_DATASET}"

# Restore backup
echo "Restoring backup..."
rm -f "${NVIDIA_RAW}"
mv "${NVIDIA_BAK}" "${NVIDIA_RAW}"

# Restore read-only
zfs set readonly=on "${USR_DATASET}"

# Re-enable NVIDIA support
echo "Merging sysext and re-enabling NVIDIA..."
systemd-sysext merge
systemctl daemon-reload
midclt call docker.update '{"nvidia": true}'

echo ""
echo "=== Restore complete ==="
if command -v nvidia-smi &>/dev/null; then
    echo "Driver version:"
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true
fi

# --- Clean up MIG ---
echo ""
echo "=== Cleaning up MIG ==="

# Destroy MIG instances
echo "Destroying MIG instances..."
nvidia-smi mig -dci 2>/dev/null || true
nvidia-smi mig -dgi 2>/dev/null || true

# Disable MIG mode
MIG_CUR=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
if [ "$MIG_CUR" = "Enabled" ]; then
    echo "Disabling MIG mode..."
    nvidia-smi -mig 0 2>/dev/null || true
    MIG_CUR_AFTER=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null || echo "N/A")
    if [ "$MIG_CUR_AFTER" = "Enabled" ]; then
        echo "MIG mode disabled (pending). Will take effect after reboot."
    else
        echo "MIG mode disabled"
    fi
fi

# --- Clean up persistence ---
echo ""
echo "=== Cleaning up persistence ==="

# Disable MIG setup service
systemctl disable nvidia-mig-setup.service 2>/dev/null || true

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

# Remove persistent config
for d in /mnt/*/.config/nvidia-gpu; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"

# --- Wait for Docker to settle before returning ---
echo ""
echo "Waiting for Docker to settle..."
for attempt in $(seq 1 12); do
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
    if [ "$attempt" -lt 12 ]; then
        printf "\r  Waiting... %ds / 60s" "$((attempt * 5))"
        sleep 5
    else
        echo ""
        echo "Docker still settling. Wait a few more seconds before running install."
    fi
done
