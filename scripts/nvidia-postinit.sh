#!/usr/bin/env bash
# TrueNAS POSTINIT script: reinstalls nvidia.raw sysext after OS updates.
# Stored on persistent pool; registered via midclt during install.
# Idempotent — safe to run on every boot.

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
cp "$NVIDIA_RAW_BACKUP" "$SYSEXT_TARGET"

if [ -n "$USR_DATASET" ]; then
    zfs set readonly=on "$USR_DATASET"
fi

log "Merging sysext..."
systemd-sysext merge

log "Reloading systemd..."
systemctl daemon-reload

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
