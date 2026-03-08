# MIG Persistence: Surviving Reboots and TrueNAS Updates

## Problem

MIG instances on the RTX PRO 6000 Blackwell are volatile — they don't survive reboots. Additionally, TrueNAS updates recreate `/usr` from scratch, wiping the custom `nvidia.raw` sysext. MIG device UUIDs change each time instances are recreated, breaking app GPU assignments.

## What persists where

| Location | Survives reboot | Survives update |
| --- | --- | --- |
| `/usr/` (sysext, systemd units) | Yes | **No** (recreated) |
| `/mnt/<pool>/` (ZFS datasets) | Yes | Yes |
| TrueNAS DB (PREINIT scripts) | Yes | Yes |
| GPU firmware (MIG mode, display mode) | Yes | Yes |
| MIG instances | **No** | **No** |

## Solution overview

### 1. MIG auto-recreation on boot

A systemd service (`nvidia-mig-setup.service`) is baked into the `nvidia.raw` sysext. It runs after `nvidia-persistenced.service` but before `docker.service`, ensuring MIG instances exist before any containers start.

The service reads MIG profile configuration from `/mnt/<pool>/.config/nvidia-gpu/mig.conf`:

```bash
# Profiles passed to: nvidia-smi mig -cgi <PROFILES> -C
MIG_PROFILES=47,47,14,14
```

After creating instances, the service automatically remaps app GPU UUIDs:

1. Finds the first compute-only MIG UUID (non-gfx profile)
2. Queries all TrueNAS apps via `midclt call app.query`
3. Updates any app with an existing MIG UUID assignment to the new UUID
4. Never exits non-zero — boot is never blocked

### 2. Pre-service reinstall via PREINIT

A TrueNAS PREINIT script (`nvidia-postinit.sh`) runs on every boot before services start:

1. Compares checksums of the backup `nvidia.raw` vs the installed one
2. If identical (normal boot): exits immediately
3. If different or missing (TrueNAS update detected):
   - Unmerges sysext, makes `/usr` writable
   - Copies backup `nvidia.raw` to sysext directory
   - Restores readonly, merges sysext
   - Starts `nvidia-mig-setup.service` to recreate MIG instances
   - Re-enables NVIDIA in Docker via `midclt`

## Persistent storage layout

```
/mnt/<pool>/.config/nvidia-gpu/
    nvidia.raw              # Backup copy (survives TrueNAS updates)
    nvidia-postinit.sh      # PREINIT script (registered in TrueNAS DB)
    mig.conf                # MIG profile configuration
```

## File locations in sysext

These files are baked into `nvidia.raw` during the GitHub Actions build:

```
/usr/bin/nvidia-mig-setup                                           # MIG setup script
/usr/lib/systemd/system/nvidia-mig-setup.service                    # systemd unit
/usr/lib/systemd/system/multi-user.target.wants/nvidia-mig-setup.service  # enable symlink
```

## Pool/path selection

The install script supports three ways to specify persistent storage:

- `--persist-path=/mnt/fast/.config/nvidia-gpu` — exact path (highest priority)
- `--pool=fast` — pool name, config goes to `/mnt/fast/.config/nvidia-gpu/`
- Auto-detect: first pool from `zpool list` excluding `boot-pool`

At runtime, both `nvidia-mig-setup` and `nvidia-postinit.sh` use glob patterns (`/mnt/*/.config/nvidia-gpu/`) to find config regardless of pool name.

## Boot sequence

### Normal reboot

1. System boots, sysext merges `nvidia.raw`
2. `nvidia-mig-setup.service` starts (after nvidia-persistenced, before docker)
3. Reads `/mnt/<pool>/.config/nvidia-gpu/mig.conf`
4. Destroys any stale MIG instances, creates new ones
5. Remaps app GPU UUIDs to the new compute-only MIG UUID
6. Docker starts with NVIDIA and correctly assigned MIG devices

### After TrueNAS update

1. System boots with stock `nvidia.raw`
2. PREINIT script runs before services, detects checksum mismatch
3. Reinstalls custom `nvidia.raw`, merges sysext
4. Starts `nvidia-persistenced` and `nvidia-mig-setup.service`
5. Services start normally — Docker gets NVIDIA with correct MIG devices

## Rollback

Running `scripts/restore.sh` reverses everything:

- Restores original `nvidia.raw` from `.bak`
- Deregisters the PREINIT script from TrueNAS
- Removes persistent config from `/mnt/<pool>/.config/nvidia-gpu/`
- Disables `nvidia-mig-setup.service`
