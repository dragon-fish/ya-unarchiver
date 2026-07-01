#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 7-Zip macOS universal (arm64+x86_64) binary.
# PRIMARY: latest stable. FALLBACK: older confirmed-working release.
PRIMARY_VERSION="2501"
FALLBACK_VERSION="2301"

fetch() {
    local version="$1"
    local url="https://www.7-zip.org/a/7z${version}-mac.tar.xz"
    local tmp
    tmp="$(mktemp -d)"
    echo "Downloading $url"
    if ! curl -fL "$url" -o "$tmp/7z-mac.tar.xz"; then
        echo "Download failed for version $version"
        return 1
    fi
    tar -xf "$tmp/7z-mac.tar.xz" -C "$tmp"
    # The macOS tarball extracts to a flat layout with `7zz` at its root.
    if [[ ! -f "$tmp/7zz" ]]; then
        echo "7zz not found at expected root path in tarball $version"
        return 1
    fi
    cp "$tmp/7zz" Resources/7zz
    chmod +x Resources/7zz
    return 0
}

if fetch "$PRIMARY_VERSION"; then
    echo "Fetched version $PRIMARY_VERSION"
else
    echo "Primary version $PRIMARY_VERSION failed; trying fallback $FALLBACK_VERSION"
    fetch "$FALLBACK_VERSION"
    echo "Fetched fallback version $FALLBACK_VERSION"
fi

echo "Verifying binary:"
Resources/7zz | head -3
echo "Placed Resources/7zz"
