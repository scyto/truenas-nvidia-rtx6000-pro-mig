#!/usr/bin/env bash
# Strips unnecessary packages from scale-build's build manifest.
# We only need the NVIDIA sysext, not a full TrueNAS ISO, so we can skip:
#   - Debug packages (kernel-dbg, openzfs-dbg, scst-dbg) — saves ~2-3h
#   - truenas_spdk, scst — fail to build on GitHub runners, not needed for GPU
#   - midcli, middlewared-docs — depend on middlewared which needs scst packages
#
# Usage: ./scripts/strip-debug-packages.sh <scale-build-dir>

set -euo pipefail

SCALE_BUILD_DIR="$1"
MANIFEST="${SCALE_BUILD_DIR}/conf/build.manifest"

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: build.manifest not found at ${MANIFEST}"
    exit 1
fi

python3 -c "
import yaml, sys

with open('${MANIFEST}') as f:
    manifest = yaml.safe_load(f)

# Source packages to skip building
skip_sources = {'kernel-dbg', 'openzfs-dbg', 'scst-dbg', 'truenas_spdk', 'scst', 'midcli', 'middlewared-docs'}

# Binary packages to skip installing in rootfs
skip_binaries = {
    'linux-headers-truenas-debug-amd64',
    'linux-image-truenas-debug-amd64',
    'scst-dbg',
    'openzfs-zfs-modules-dbg',
    'truenas-spdk',
    'iscsi-scst',
    'scst',
    'scstadmin',
    'midcli',
    'middlewared-docs',
}

# Remove skipped top-level sources
manifest['sources'] = [s for s in manifest.get('sources', []) if s['name'] not in skip_sources]

# Remove skipped subpackages and clean up deps
for source in manifest.get('sources', []):
    if 'subpackages' in source:
        source['subpackages'] = [
            sub for sub in source['subpackages']
            if sub['name'] not in skip_sources
        ]
    # Remove skipped packages from explicit_deps
    if 'explicit_deps' in source:
        source['explicit_deps'] = [
            dep for dep in source['explicit_deps']
            if dep not in skip_sources
        ]
    for sub in source.get('subpackages', []):
        if 'explicit_deps' in sub:
            sub['explicit_deps'] = [
                dep for dep in sub['explicit_deps']
                if dep not in skip_sources
            ]

# Remove skipped packages from base-packages and additional-packages
for key in ('base-packages', 'additional-packages'):
    if key in manifest:
        before = len(manifest[key])
        manifest[key] = [
            pkg for pkg in manifest[key]
            if pkg['name'] not in skip_binaries
        ]
        removed = before - len(manifest[key])
        if removed:
            print(f'Removed {removed} debug package(s) from {key}')

with open('${MANIFEST}', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False, width=200)

print('Unnecessary packages stripped from manifest')
"

echo "Done. Removed: kernel-dbg, openzfs-dbg, scst-dbg, scst, truenas_spdk, midcli, middlewared-docs"
