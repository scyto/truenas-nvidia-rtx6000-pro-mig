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
curl -fsSL https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/releases/latest/download/install.sh | sudo bash
```

The script automatically detects your TrueNAS version and downloads the matching release.

To also set up MIG persistence (auto-recreates instances after reboot and survives TrueNAS updates):

```bash
curl -fsSL https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/releases/latest/download/install.sh \
  | sudo bash -s -- --mig-profiles=47,47,14,14 --pool=fast
```

See `sudo ./install.sh --help` for all options.

## Manual Install

1. Download `nvidia.raw` and `nvidia.raw.sha256` from [Releases](https://github.com/scyto/truenas-nvidia-rtx6000-pro-mig/releases)

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

### Step 1: Obtain displaymodeselector

The `displaymodeselector` tool is required to switch the GPU to compute display mode before MIG can be enabled. It is not included in the standard NVIDIA driver package.

1. Go to [developer.nvidia.com/displaymodeselector](https://developer.nvidia.com/displaymodeselector)
2. Log in with your NVIDIA Developer account (create one for free if needed)
3. Click **Join now** to request access — approval is typically immediate
4. Download the Linux package (`.tar.gz`)
5. Extract the binary: `tar xzf DisplayModeSelector-*.tar.gz`
6. SCP it to your TrueNAS server: `scp displaymodeselector truenas_admin@<your-server>:~/`

The install script will automatically detect it in your home directory and inject it into the sysext.

> **Warning**: NVIDIA notes that setting a non-default display mode on an unqualified system could cause issues. The RTX PRO 6000 Blackwell Workstation Edition is qualified for compute mode.

### Step 2: Switch to compute display mode

This disables physical display output on single-card systems. **Ensure SSH access is available before proceeding** — you will lose any connected display.

TrueNAS mounts `/home`, `/tmp`, and `/data` with `noexec`, so `displaymodeselector` must be run from `/usr/bin` (installed via the sysext) or via the dynamic linker.

```bash
sudo displaymodeselector --gpumode compute
# Reboot required for the change to take effect
sudo reboot
```

### Step 3: Enable MIG mode

After reboot, stop all GPU workloads and enable MIG:

```bash
# Stop Docker/apps using the GPU
sudo midclt call docker.update '{"nvidia": false}'

# Enable MIG mode
sudo nvidia-smi -i 0 -mig 1

# Verify (should show "Enabled")
nvidia-smi --query-gpu=mig.mode.current --format=csv
```

### Step 4: Create GPU instances

The RTX PRO 6000 Blackwell supports these MIG profiles:

| Profile | ID | Max Instances | Memory | Notes |
|---|---|---|---|---|
| 1g.24gb | 14 | 4 | 23.6 GB | Compute only |
| 1g.24gb+gfx | 47 | 4 | 23.6 GB | Compute + graphics APIs |
| 2g.48gb | 5 | 2 | 47.4 GB | Compute only |
| 2g.48gb+gfx | 35 | 2 | 47.4 GB | Compute + graphics APIs |
| 4g.96gb | 0 | 1 | 95.0 GB | Full GPU, compute only |
| 4g.96gb+gfx | 32 | 1 | 95.0 GB | Full GPU, compute + graphics |

The `+gfx` profiles are unique to the RTX PRO 6000 Blackwell — they support OpenGL, Vulkan, and DirectX within MIG instances. Standard (non-gfx) profiles support CUDA compute only. You can mix `+gfx` and standard profiles.

```bash
# List available profiles on your card
nvidia-smi mig -lgip

# Examples:
# 4x 24GB compute-only instances:
sudo nvidia-smi mig -cgi 14,14,14,14 -C

# 2x 48GB compute-only instances:
sudo nvidia-smi mig -cgi 5,5 -C

# 1x 96GB full GPU:
sudo nvidia-smi mig -cgi 0 -C

# Mixed: 2x gfx + 2x compute (all 24GB):
sudo nvidia-smi mig -cgi 47,47,14,14 -C

# Verify
nvidia-smi mig -lgi
nvidia-smi
```

### Step 5: Assign MIG devices to TrueNAS apps

TrueNAS apps require a GPU UUID to be assigned via `midclt`. With MIG enabled, each instance gets its own UUID.

```bash
# List MIG device UUIDs
nvidia-smi -L
```

This outputs something like:

```text
GPU 0: NVIDIA RTX PRO 6000 Blackwell Workstation Edition (UUID: GPU-...)
  MIG 1g.24gb     Device  0: (UUID: MIG-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
  MIG 1g.24gb     Device  1: (UUID: MIG-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy)
  ...
```

To identify compute-only vs gfx instances, cross-reference with the GPU instance list:

```bash
nvidia-smi mig -lgi
```

Instances with profile ID 14 are compute-only; profile ID 47 are +gfx.

To assign a MIG device to a TrueNAS app:

```bash
# First, find your GPU's PCI slot
midclt call app.gpu_choices | python3 -m json.tool

# Then update the app to use a specific MIG UUID
midclt call app.update "APP_NAME" '{"values": {"resources": {"gpus": {"use_all_gpus": false, "nvidia_gpu_selection": {"PCI_SLOT": {"use_gpu": true, "uuid": "MIG-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}}}}}}'
```

Replace `APP_NAME` with your app name (e.g., `plex`, `frigate`), `PCI_SLOT` with the PCI address from `app.gpu_choices` (e.g., `0000:0f:00.0`), and the UUID with the MIG device UUID from `nvidia-smi -L`.

### Step 6: Enable persistence across reboots

MIG instances are volatile and don't survive reboots. The install script can configure automatic recreation:

```bash
# During install (or re-run later):
sudo ./install.sh --mig-profiles=47,47,14,14 --pool=fast
```

This sets up:
- **`nvidia-mig-setup.service`** — systemd service (baked into sysext) that recreates MIG instances on boot before Docker starts
- **`mig.conf`** — stored on your persistent pool at `/mnt/<pool>/.config/nvidia-gpu/mig.conf`
- **Automatic UUID remapping** — after recreating instances, the service finds all TrueNAS apps with MIG GPU assignments and updates them to the new compute-only MIG UUID

You can also write the config manually:

```bash
mkdir -p /mnt/fast/.config/nvidia-gpu
cat > /mnt/fast/.config/nvidia-gpu/mig.conf <<EOF
MIG_PROFILES=47,47,14,14
EOF
```

### Step 7: Survive TrueNAS updates

TrueNAS updates recreate `/usr` from scratch, wiping the custom nvidia.raw. The install script registers a PREINIT script that automatically reinstalls it:

- Stores a backup of `nvidia.raw` on your persistent pool
- Registers a TrueNAS PREINIT script (runs before services start, persists in DB across updates)
- On each boot, compares checksums — only reinstalls if nvidia.raw has changed or is missing
- After reinstalling: merges sysext, starts nvidia-persistenced, recreates MIG instances, remaps UUIDs

This is set up automatically by `install.sh`. No manual steps required.

To check the PREINIT registration:

```bash
midclt call initshutdownscript.query | python3 -m json.tool
```

### Important Notes

- **Stop all GPU workloads** (Docker apps, containers) before enabling/disabling MIG mode or creating/destroying instances.
- `+gfx` instances can run both CUDA and graphics workloads. Standard instances are CUDA-only. For most TrueNAS container workloads (Plex, Jellyfin, Frigate), standard compute profiles are sufficient.
- MIG instance UUIDs change each time instances are recreated, but the persistence service handles remapping automatically.

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

This restores the backup created during installation. It also:
- Deregisters the PREINIT script from TrueNAS
- Removes persistent config from `/mnt/<pool>/.config/nvidia-gpu/`
- Disables the `nvidia-mig-setup.service`

## Credits

- [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) — Foundation and reference implementation
- [Homelab Project Guide](https://www.homelabproject.cc/posts/truenas/truenas-build-nvidia-vgpu-driver-extensions-systemd-sysext/) — Detailed sysext build walkthrough
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) — MIG documentation
