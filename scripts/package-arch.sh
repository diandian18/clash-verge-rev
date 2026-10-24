#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo 'Usage: bash scripts/package-arch.sh <amd64.deb> <output-directory>' >&2
    exit 1
fi

deb=$(realpath "$1")
output=$(realpath -m "$2")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $(dpkg-deb -f "$deb" Architecture) != amd64 ]]; then
    echo 'Only x86_64 Debian packages are supported.' >&2
    exit 1
fi

version=$(dpkg-deb -f "$deb" Version)
pkgver=${version//-/_}
if [[ ! $pkgver =~ ^[0-9][A-Za-z0-9._+]*$ ]]; then
    echo "Unsupported package version: $version" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$deb" "$work/clash-verge.deb"
cp "$root/src-tauri/packages/arch/clash-verge.install" "$work/"
sha256=$(sha256sum "$work/clash-verge.deb" | cut -d ' ' -f 1)
sed -e "s/@PKGVER@/$pkgver/" -e "s/@SHA256@/$sha256/" \
    "$root/src-tauri/packages/arch/PKGBUILD" > "$work/PKGBUILD"

docker run --rm -v "$work:/work" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    archlinux:base-devel bash -euo pipefail -c '
        trap "chown -R $HOST_UID:$HOST_GID /work" EXIT
        pacman -Syu --noconfirm
        useradd -m builder
        chown -R builder:builder /work
        su builder -c "cd /work && makepkg --nodeps --noconfirm"
        package=(/work/*.pkg.tar.zst)
        pacman -U --noconfirm "${package[@]}"
        pacman -Qk clash-verge-rev
        mapfile -t installed_files < <(pacman -Qlq clash-verge-rev | grep -v "/$")
        for binary in clash-verge clash-verge-service clash-verge-service-install clash-verge-service-uninstall verge-mihomo verge-mihomo-alpha; do
            dependencies=$(ldd "/usr/bin/$binary" 2>&1 || true)
            if grep -q "not found" <<< "$dependencies"; then
                echo "Unresolved runtime dependencies: $binary" >&2
                printf "%s\n" "$dependencies" >&2
                exit 1
            fi
        done
        pacman -R --noconfirm clash-verge-rev
        if pacman -Q clash-verge-rev >/dev/null 2>&1; then
            echo "Package is still registered after removal." >&2
            exit 1
        fi
        for file in "${installed_files[@]}"; do
            if [[ -e "$file" || -L "$file" ]]; then
                echo "Package file remains after removal: $file" >&2
                exit 1
            fi
        done
    '

mkdir -p "$output"
cp "$work"/*.pkg.tar.zst "$output/"
printf 'Arch Linux package: %s/clash-verge-rev-%s-1-x86_64.pkg.tar.zst\n' "$output" "$pkgver"
