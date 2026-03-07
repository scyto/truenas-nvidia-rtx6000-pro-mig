# Build Architecture

This document describes the build pipeline, scripts, caching strategy, and runtime patches used to produce an NVIDIA sysext package for TrueNAS SCALE using GitHub Actions free runners.

## Goal

Build a `nvidia.raw` [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) image containing NVIDIA drivers (open kernel modules + userspace) for TrueNAS SCALE. The sysext is published as a GitHub release and can be installed on a running TrueNAS system to upgrade or replace the stock NVIDIA driver.

The target GPU is the RTX PRO 6000 Blackwell Workstation Edition, which requires driver 580+ with open kernel modules and supports MIG (Multi-Instance GPU).

## Why We Use scale-build

TrueNAS SCALE ships a read-only root filesystem with a specific kernel. NVIDIA kernel modules must be compiled against the exact kernel headers and packaged into the sysext format that TrueNAS expects. iXsystems' [scale-build](https://github.com/truenas/scale-build) system handles all of this: it bootstraps a Debian chroot matching the TrueNAS release, builds all packages (including NVIDIA extensions), assembles the rootfs image, and produces the sysext as part of the update image.

We include scale-build as a git submodule, checked out to the release branch matching the target TrueNAS version.

## Repository Layout

```
.github/workflows/build.yml    # GitHub Actions workflow (2-job pipeline)
scale-build/                    # Git submodule: truenas/scale-build
scripts/
  patch-driver-version.sh       # Patches NVIDIA driver version in build manifest
  strip-debug-packages.sh       # Removes debug/unnecessary packages from manifest
  create-dummy-packages.sh      # Creates stub .deb files for dependency resolution
  install.sh                    # End-user install script (runs on TrueNAS)
  restore.sh                    # End-user rollback script (runs on TrueNAS)
docs/
  architecture.md               # This file
```

## Pipeline Overview

The workflow is triggered manually (`workflow_dispatch`) with parameters for TrueNAS version, NVIDIA driver version, and train name. It runs in two sequential jobs on free GitHub Actions runners (ubuntu-22.04, 2 vCPU, 7GB RAM, ~30GB disk).

```
workflow_dispatch
        |
        v
  +-----------+     artifact      +-------------+     release
  |   Job 1   | ───(tar.zst)───> |    Job 2    | ──> nvidia.raw
  |  packages |                   | update+sysext|
  +-----------+                   +-------------+
   ~13min (cached)                 ~35min
   ~5-6h (first run)
```

### Why Two Jobs?

1. **Disk space**: Free runners have ~30GB usable. Job 1 builds ~126 .deb packages and Job 2 assembles the rootfs + extensions. Neither fits alongside the other's intermediate files.

2. **Memory**: Job 2 needs a 25GB tmpfs for rootfs assembly (scale-build mounts this internally). The runner only has 7GB RAM + 4GB swap by default, so Job 2 creates a 20GB swapfile. Job 1 doesn't need this extra swap.

3. **Timeout resilience**: Job 1 has a 5.5h step timeout with `continue-on-error: true`. If it times out, caches are still saved. The next run resumes from where the previous one stopped (incremental build). Job 2 is independent and doesn't need this pattern.

4. **Separation of concerns**: Building packages is purely CPU-bound compilation. Building the update image is I/O and memory intensive (chroot operations, squashfs, extensions). Different resource profiles benefit from separate environments.

## Job 1: build-packages

### Steps

1. **Free disk space** -- Removes pre-installed runner bloat (~15GB recovered): .NET SDK, Android SDK, Haskell, PowerShell, Swift, Azure CLI, JVMs, Docker images. Runs removals in parallel for speed.

2. **Checkout** -- Checks out this repo with submodules, then fetches the target scale-build release branch.

3. **Install dependencies** -- Installs build tools and Python 3.11 via the deadsnakes PPA (see [Python Version](#python-version) below).

4. **Verify NVIDIA driver URL** -- Fails fast if the NVIDIA download URL returns a non-200 status, before spending hours building.

5. **Restore caches** -- Three granular caches are restored independently (see [Caching Strategy](#caching-strategy)).

6. **Patch Makefile** -- Replaces `python3 setup.py install` with `pip install .` (see [Runtime Patches](#runtime-patches)).

7. **Checkout sources** -- Runs `make checkout` to clone all package source repositories defined in the build manifest.

8. **Patch driver version** -- Updates the NVIDIA driver version in `conf/build.manifest`.

9. **Strip debug packages** -- Removes debug and unnecessary packages from the manifest to save build time.

10. **Create dummy packages** -- Creates empty .deb stubs for packages that can't build on runners but are needed as dependencies.

11. **Build packages** -- Runs `make packages` with a 5.5h timeout. Uses `continue-on-error` so cache saves still happen on timeout.

12. **Save caches** -- All three caches are saved with `if: always()` so partial progress is preserved.

13. **Compress and upload** -- Packages + bootstrap cache are compressed with zstd and uploaded as an artifact for Job 2.

### Incremental Builds

The first run takes 5-6h to build all packages. Subsequent runs detect cached packages via `tmp/pkghashes/` and skip unchanged ones. A typical cached run completes in ~13 minutes (only the handful of NVIDIA-specific packages need rebuilding).

If a run times out partway through, the caches are saved and the next run resumes from where it left off. For example, if 80/126 packages are built before timeout, the next run starts from package 81.

## Job 2: build-update

### Steps

1. **Free disk space** -- Same cleanup as Job 1.

2. **Add swap** -- Replaces the default 4GB swapfile with a 20GB one. scale-build mounts a 25GB tmpfs for rootfs assembly and creates up to 3 copies of the rootfs during extension building. The 7GB RAM + 20GB swap = 27GB backing is sufficient.

3. **Checkout + install deps** -- Same as Job 1.

4. **Download + restore packages** -- Downloads the zstd-compressed artifact from Job 1 and extracts it into `scale-build/tmp/`.

5. **Patch Makefile** -- Same setuptools fix as Job 1.

6. **Patch extensions.py** -- Removes `os.makedirs()` calls that conflict with `unsquashfs` (see [Runtime Patches](#runtime-patches)).

7. **Build update image** -- Runs `make update`, which:
   - Installs all .deb packages into a chroot (`install_rootfs_packages`)
   - Runs post-install customization (`custom_rootfs_setup`, `clean_rootfs`)
   - Builds sysext extensions including nvidia.raw (`build_extensions`)
   - Assembles the final rootfs squashfs image (`build_rootfs_image`)

8. **Extract nvidia.raw** -- Mounts the rootfs squashfs and copies out `nvidia.raw` from `/usr/share/truenas/sysext-extensions/`.

9. **DisplayModeSelector injection** (optional) -- If a URL is provided, the nvidia.raw is unpacked, the DisplayModeSelector binary is added, and it's repacked. This is for Blackwell Workstation GPUs that need display mode switching.

10. **Create release** -- Publishes a GitHub release with nvidia.raw, checksums, and install/restore scripts.

## Scripts

### patch-driver-version.sh

Reads the current NVIDIA driver version from `scale-build/conf/build.manifest` (YAML path: `extensions.nvidia.current`) and replaces it with the target version. Verifies the patch succeeded by re-reading the manifest.

### strip-debug-packages.sh

Removes packages from the build manifest that are unnecessary for the NVIDIA sysext:

**Skipped source packages** (not built at all):
- `kernel-dbg`, `openzfs-dbg`, `scst-dbg` -- Debug symbol packages; saves 2-3h build time
- `truenas_spdk` -- SPDK storage stack; fails on runners and isn't needed for GPU
- `scst` -- iSCSI target framework; fails on runners and isn't needed for GPU

**Skipped binary packages** (not installed in rootfs):
- `linux-headers-truenas-debug-amd64`, `linux-image-truenas-debug-amd64`
- `scst-dbg`, `openzfs-zfs-modules-dbg`, `truenas-spdk`

Also cleans up `explicit_deps` references to removed packages so dependency resolution doesn't fail.

### create-dummy-packages.sh

Creates empty .deb stub packages for `scst`, `iscsi-scst`, and `scstadmin`. These are needed because `middlewared` (and transitively the `truenas` metapackage) depends on scst packages. Since we stripped scst from the build (it fails on GitHub runners), we provide empty stubs so apt dependency resolution succeeds.

Each dummy package contains only a `DEBIAN/control` file with version `0.0.0-dummy`. After creating them, the script regenerates `Packages.gz` so apt can find them.

**Why dummy packages instead of stripping dependents?** We initially tried removing all packages that depend on scst (midcli, middlewared-docs, truenas). This caused cascading failures: missing systemd service directories, missing `/etc/ssh`, and other issues because the truenas metapackage sets up essential system structure. The dummy approach keeps the build much closer to a standard TrueNAS build -- everything installs normally, the scst packages just happen to be empty.

### install.sh

End-user script for installing nvidia.raw on a running TrueNAS system. Accepts a local file path or auto-detects the TrueNAS version and downloads the matching release from GitHub. Verifies the SHA256 checksum, temporarily makes `/usr` writable (ZFS dataset), backs up the existing nvidia.raw, installs the new one, and re-enables the NVIDIA sysext.

### restore.sh

Rolls back to the previously installed nvidia.raw from the backup created by install.sh.

## Caching Strategy

GitHub Actions provides 10GB of cache storage per repository (shared across all workflows and branches). We use three granular caches with a restore/save split pattern:

| Cache | Key Pattern | Contents | Size | Purpose |
|-------|------------|----------|------|---------|
| Bootstrap | `bootstrap-{version}-{run_id}` | `tmp/cache/` | ~1GB | Debian chroot base; avoids re-running debootstrap (~15 min) |
| Packages | `pkgs-{version}-{run_id}` | `tmp/pkgdir/` + `tmp/pkghashes/` | ~5GB | Built .deb files + content hashes for skip detection |
| ccache | `ccache-{version}-{run_id}` | `tmp/ccache/` | ~2GB | Compiler cache; saves 2-3h on kernel rebuilds |

**Why restore/save split?** Standard `actions/cache` only saves on job success. Since Job 1 may timeout or fail, we use `actions/cache/restore` to restore and `actions/cache/save` with `if: always()` to save. This ensures partial progress is preserved.

**Rolling keys**: Each run saves with a unique key (includes `run_id`). The `restore-keys` prefix match picks up the most recent entry. Old entries are evicted by GitHub when the 10GB limit is reached.

**APT cache**: Build dependencies are cached separately (`~/apt-cache`) to avoid re-downloading ~500MB of .deb files each run.

**Permission fix**: `make packages` runs as root (sudo), so cached files are root-owned. A `chown` step fixes permissions before cache save, since the GitHub Actions cache action runs as the `runner` user.

## Runtime Patches

Several patches are applied at build time on the runner to work around incompatibilities between scale-build and the GitHub Actions environment.

### Makefile: setup.py install -> pip install .

**Problem**: scale-build's Makefile uses `python3 setup.py install` to install itself into a virtualenv. We use Python 3.11 from deadsnakes, which ships a recent pip that installs setuptools >= 72. Setuptools 72+ removed support for `setup.py install`.

**Fix**: `sed -i 's/python3 setup.py install/pip install ./' scale-build/Makefile`

### extensions.py: Remove os.makedirs before unsquashfs

**Problem**: scale-build's `extensions.py` calls `os.makedirs()` to create a directory, then immediately calls `unsquashfs -dest <that directory>`. The `unsquashfs -dest` flag creates the destination directory itself and fails with "File exists" if the directory already exists.

**Fix**: Remove the `os.makedirs` lines that precede `unsquashfs -dest` calls. This is done with a Python script that filters out lines containing `os.makedirs(chroot` and `os.makedirs(self.chroot)`.

### Python Version

**Problem**: scale-build uses `hashlib.file_digest()` (added in Python 3.11) in several files (`mtree.py`, `manifest.py`, `iso.py`). Ubuntu 22.04 ships Python 3.10 by default. Ubuntu 24.04 ships Python 3.12, but 3.12's setuptools removes `setup.py install` support.

**Solution**: Use Ubuntu 22.04 with Python 3.11 from the deadsnakes PPA. This is the sweet spot: `hashlib.file_digest()` is available AND `setup.py install` still works (after the Makefile patch above). Python 3.11 is set as the default via `update-alternatives`.

## Disk and Memory Budget

### Free runner resources (ubuntu-22.04)
- **CPU**: 2 vCPU
- **RAM**: 7GB
- **Disk**: ~30GB usable (after cleanup: ~45GB)
- **Swap**: 4GB default (expanded to 20GB in Job 2)

### Job 1 disk usage
- Source checkouts: ~5GB
- Build intermediates: ~15GB peak
- Final .deb packages: ~5GB
- Headroom needed for debootstrap, ccache: ~10GB

### Job 2 memory usage
- tmpfs for rootfs: 25GB (mounted by scale-build)
- During extension building: up to 3 copies of rootfs in tmpfs
- Required backing: 7GB RAM + 20GB swap = 27GB

## Known Limitations

### Packages that fail on GitHub runners

`scst` and `truenas_spdk` fail to build on GitHub free runners. These are storage-stack packages (iSCSI target, SPDK) unrelated to GPU drivers. They are handled via dummy packages for now. A future improvement would be to investigate and fix the actual build failures to reduce divergence from the standard TrueNAS build process.

### Build parallelism

scale-build calculates parallel build threads as `max(cpu_count(), 8) / 4`. On the 2-vCPU free runner, this gives 2 parallel threads. Builds are significantly slower than on iXsystems' internal CI infrastructure.

### Cache size constraints

The 10GB GitHub Actions cache limit is shared across all workflows and branches. The three caches total ~8GB, leaving limited room for APT caches or additional workflows. If cache pressure becomes an issue, consider self-hosted runners or reducing the ccache size.

## Workflow Permissions

The workflow requires `contents: write` permission on the `GITHUB_TOKEN` to create GitHub releases and upload release assets. This is declared at the workflow level.
