#!/usr/bin/env bash
# Creates dummy .deb packages for packages that fail to build on GitHub runners
# but are needed as dependencies (e.g., middlewared depends on scst packages).
# These are empty stubs — just enough to satisfy apt dependency resolution.
#
# Usage: ./scripts/create-dummy-packages.sh <scale-build-dir>

set -euo pipefail

SCALE_BUILD_DIR="$1"
PKG_DIR="${SCALE_BUILD_DIR}/tmp/pkgdir"

if [ ! -d "$PKG_DIR" ]; then
    echo "ERROR: pkgdir not found at ${PKG_DIR}"
    exit 1
fi

DUMMY_PACKAGES=(
    "scst"
    "iscsi-scst"
    "scstadmin"
    "middlewared-docs"
    "midcli"
)

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for pkg in "${DUMMY_PACKAGES[@]}"; do
    # Skip if a real package already exists
    if ls "${PKG_DIR}/${pkg}_"*.deb &>/dev/null; then
        echo "Skipping ${pkg} — real package already exists"
        continue
    fi

    echo "Creating dummy package: ${pkg}"
    PKG_BUILD="${TMPDIR}/${pkg}"
    mkdir -p "${PKG_BUILD}/DEBIAN"
    cat > "${PKG_BUILD}/DEBIAN/control" <<CTRL
Package: ${pkg}
Version: 0.0.0-dummy
Architecture: all
Maintainer: dummy
Description: Dummy package for ${pkg} (not needed for NVIDIA sysext)
CTRL

    dpkg-deb --build "${PKG_BUILD}" "${PKG_DIR}/${pkg}_0.0.0-dummy_all.deb"
done

# Regenerate Packages.gz so apt can find the new dummy packages
cd "${PKG_DIR}"
dpkg-scanpackages --multiversion . /dev/null | gzip -9c > Packages.gz

echo "Done. Dummy packages created in ${PKG_DIR}"
