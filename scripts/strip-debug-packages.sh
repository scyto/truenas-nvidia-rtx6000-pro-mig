#!/usr/bin/env bash
# Removes debug packages from scale-build's build manifest.
# Debug packages (kernel-dbg, openzfs-dbg, scst-dbg) are not needed for the
# NVIDIA sysext and their compilation (especially kernel-dbg) adds ~2-3h.
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

# Debug source packages to skip building
debug_sources = {'kernel-dbg', 'openzfs-dbg', 'scst-dbg'}

# Debug binary packages to skip installing in rootfs
debug_binaries = {
    'linux-headers-truenas-debug-amd64',
    'linux-image-truenas-debug-amd64',
    'scst-dbg',
    'openzfs-zfs-modules-dbg',
}

# Remove debug subpackages from sources
for source in manifest.get('sources', []):
    if 'subpackages' in source:
        source['subpackages'] = [
            sub for sub in source['subpackages']
            if sub['name'] not in debug_sources
        ]
    # Remove kernel-dbg from explicit_deps
    if 'explicit_deps' in source:
        source['explicit_deps'] = [
            dep for dep in source['explicit_deps']
            if dep not in debug_sources
        ]
    for sub in source.get('subpackages', []):
        if 'explicit_deps' in sub:
            sub['explicit_deps'] = [
                dep for dep in sub['explicit_deps']
                if dep not in debug_sources
            ]

# Remove debug packages from base-packages and additional-packages
for key in ('base-packages', 'additional-packages'):
    if key in manifest:
        before = len(manifest[key])
        manifest[key] = [
            pkg for pkg in manifest[key]
            if pkg['name'] not in debug_binaries
        ]
        removed = before - len(manifest[key])
        if removed:
            print(f'Removed {removed} debug package(s) from {key}')

with open('${MANIFEST}', 'w') as f:
    yaml.dump(manifest, f, default_flow_style=False, sort_keys=False, width=200)

print('Debug packages stripped from manifest')
"

echo "Done. Removed debug packages: kernel-dbg, openzfs-dbg, scst-dbg"
