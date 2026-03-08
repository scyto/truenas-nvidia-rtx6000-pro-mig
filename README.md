# TrueNAS NVIDIA Blackwell Sysext

Builds a systemd-sysext package containing **NVIDIA 580.x drivers** for TrueNAS SCALE, targeting the **RTX PRO 6000 Blackwell Workstation Edition** with **MIG (Multi-Instance GPU) support**.

All driver compilation happens on GitHub Actions. The resulting `nvidia.raw` is a drop-in replacement for TrueNAS's built-in NVIDIA sysext.

## Why This Exists

TrueNAS 25.10 "Goldeye" ships with NVIDIA driver **570.172.08**. However, MIG on the RTX PRO 6000 Blackwell requires driver **R575 (>=575.51.03)** per [NVIDIA's deployment docs](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/deployment-considerations.html). This repo builds a sysext with driver **580.126.18** (or newer) to enable MIG.

| | TrueNAS Stock | This Repo |
|---|---|---|
| Driver | 570.172.08 | 580.126.18 |
| Kernel Modules | Open | Open (required for Blackwell) |
| MIG on RTX PRO 6000 | Not supported | Supported |

### Difference from [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers)

That repo removes `--kernel-module-type=open` to support **legacy GPUs** (Maxwell, Pascal, Volta). This repo keeps open kernel modules (mandatory for Blackwell) and instead changes the **driver version**.

## Quick Install

```bash
curl -fsSL https://github.com/scyto/truenas-nvidia-blackwell/releases/latest/download/install.sh | sudo bash
```

The script automatically detects your TrueNAS version and downloads the matching release.

## Manual Install

1. Download `nvidia.raw` and `nvidia.raw.sha256` from [Releases](https://github.com/scyto/truenas-nvidia-blackwell/releases)

2. Verify checksum:
   ```bash
   sha256sum -c nvidia.raw.sha256
   ```

3. Install:
   ```bash
   # Disable NVIDIA temporarily
   midclt call docker.update '{"nvidia": false}'
   systemd-sysext unmerge

   # Make /usr writable
   zfs set readonly=off "$(zfs list -H -o name /usr)"

   # Backup and replace
   cp /usr/share/truenas/sysext-extensions/nvidia.raw /usr/share/truenas/sysext-extensions/nvidia.raw.bak
   cp nvidia.raw /usr/share/truenas/sysext-extensions/nvidia.raw

   # Restore read-only and re-enable
   zfs set readonly=on "$(zfs list -H -o name /usr)"
   systemd-sysext merge
   midclt call docker.update '{"nvidia": true}'
   ```

4. Verify:
   ```bash
   nvidia-smi
   ```

## Included Utilities

The sysext includes all standard NVIDIA driver userspace tools:

- **nvidia-smi** — GPU management, monitoring, MIG configuration
- **nvidia-persistenced** — Persistent daemon for GPU state
- **nvidia-cuda-mps-control / nvidia-cuda-mps-server** — Multi-Process Service
- All standard driver libraries and kernel modules

- **displaymodeselector** — Required for Workstation Edition MIG setup (see below). Download separately from [developer.nvidia.com/displaymodeselector](https://developer.nvidia.com/displaymodeselector) (requires NVIDIA developer account). The install script will automatically pick it up from your home directory, or it can be included in the sysext by providing its download URL when triggering the build workflow.

## MIG Setup Guide (RTX PRO 6000 Blackwell)

Reference: [NVIDIA Getting Started with MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/getting-started-with-mig.html)

### Prerequisites

#### 1. Obtain displaymodeselector

The `displaymodeselector` tool is required to switch the GPU to compute display mode before MIG can be enabled. It is not included in the standard NVIDIA driver package.

1. Go to [developer.nvidia.com/displaymodeselector](https://developer.nvidia.com/displaymodeselector)
2. Log in with your NVIDIA Developer account (create one for free if needed)
3. Click **Join now** to request access — approval is typically immediate
4. Download the Linux package (`.tar.gz`)
5. Extract the binary: `tar xzf DisplayModeSelector-*.tar.gz`
6. SCP it to your TrueNAS server: `scp displaymodeselector truenas_admin@<your-server>:~/`

The install script will automatically detect it in your home directory and inject it into the sysext.

> **Warning**: NVIDIA notes that setting a non-default display mode on an unqualified system could cause issues. The RTX PRO 6000 Blackwell Workstation Edition is qualified for compute mode.

#### 2. Switch to compute display mode

This disables physical display output on single-card systems. Ensure SSH access is available before proceeding.

```bash
# Use displaymodeselector v1.72.0+
sudo displaymodeselector --gpumode compute
# Reboot required after this step
sudo reboot
```

#### 3. Verify vBIOS meets minimum requirements for your card

### Enable MIG

```bash
# Enable MIG mode
sudo nvidia-smi -i 0 -mig 1

# Verify
nvidia-smi --query-gpu=mig.mode.current --format=csv
```

### Create GPU Instances

```bash
# List available profiles
nvidia-smi mig -lgip

# Create instances (examples):
# 4x 24GB instances (profile 14):
sudo nvidia-smi mig -cgi 14,14,14,14 -C

# 2x 48GB instances (profile 5):
sudo nvidia-smi mig -cgi 5,5 -C

# 1x 96GB full GPU (profile 0):
sudo nvidia-smi mig -cgi 0 -C

# With graphics API support (unique to RTX PRO 6000 Blackwell):
# 4x 24GB +gfx (profile 47):
sudo nvidia-smi mig -cgi 47,47,47,47 -C

# Verify
nvidia-smi mig -lgi
nvidia-smi
```

### Important Notes

- MIG devices are **not persistent across reboots**. Use [nvidia-mig-parted](https://github.com/NVIDIA/mig-parted) for automation.
- Stop all driver-holding daemons (nvsm, dcgm, Docker) before enabling/disabling MIG mode.
- RTX PRO 6000 Blackwell uniquely supports **graphics APIs in MIG mode**.
- On Hopper+ GPUs, MIG mode is non-persistent without driver modules loaded.

## Building from Source

### Manual Trigger

Go to **Actions** > **Build NVIDIA Sysext** > **Run workflow** with:

| Input | Default | Description |
|---|---|---|
| `truenas_version` | 25.10.2.1 | TrueNAS release version |
| `nvidia_driver_version` | 580.126.18 | NVIDIA driver version |
| `train_name` | Goldeye | TrueNAS train name |
| `display_mode_selector_url` | *(empty)* | Optional URL to [DisplayModeSelector](https://developer.nvidia.com/displaymodeselector) package |

The build takes 1-3 hours. It uses TrueNAS's [scale-build](https://github.com/truenas/scale-build) system to compile the driver against the exact kernel shipped in the target TrueNAS version.

### How It Works

1. Checks out `truenas/scale-build` at the target release branch
2. Patches `conf/build.manifest` to change the NVIDIA driver version
3. Builds the full TrueNAS package set (this compiles the driver against the correct kernel)
4. Extracts `nvidia.raw` from the built rootfs
5. Publishes as a GitHub release

## Automated Checks

| Workflow | Schedule | Action |
|---|---|---|
| **Check TrueNAS Releases** | Weekly (Monday) | Auto-triggers a build if a new stable 25.10.x release is detected |
| **Check NVIDIA Drivers** | Weekly (Wednesday) | Creates a GitHub issue if a newer 580.x driver is found (manual build required) |

TrueNAS releases auto-trigger builds because kernel modules must match the exact kernel version. NVIDIA driver updates only create issues since new drivers should be manually vetted.

## Rollback

```bash
sudo ./restore.sh
```

This restores the backup created during installation.

## Credits

- [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) — Foundation and reference implementation
- [Homelab Project Guide](https://www.homelabproject.cc/posts/truenas/truenas-build-nvidia-vgpu-driver-extensions-systemd-sysext/) — Detailed sysext build walkthrough
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — MIG documentation
