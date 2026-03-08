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
midclt call docker.update '{"nvidia": true}'

echo ""
echo "=== Restore complete ==="
if command -v nvidia-smi &>/dev/null; then
    echo "Driver version:"
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true
fi

# --- Clean up persistence ---
echo ""
echo "=== Cleaning up persistence ==="

# Disable MIG setup service
systemctl disable nvidia-mig-setup.service 2>/dev/null || true

# Deregister POSTINIT script
POSTINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null \
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

if [ -n "$POSTINIT_ID" ]; then
    midclt call initshutdownscript.delete "$POSTINIT_ID" 2>/dev/null \
        && echo "POSTINIT script deregistered (id: ${POSTINIT_ID})" \
        || echo "WARNING: Failed to deregister POSTINIT script"
else
    echo "No POSTINIT script found to deregister"
fi

# Remove persistent config
for d in /mnt/*/.config/nvidia-gpu; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"
