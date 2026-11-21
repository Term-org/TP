#!/usr/bin/env bash
# build-apt-repo.sh - turn built .deb files into signed apt repositories.
#
# Usage: scripts/build-apt-repo.sh <input-dir> <site-dir>
#
#   input-dir  contains one directory per build, named debs-<application-id>-<arch>
#   site-dir   receives one repository per application id:
#                <site-dir>/<application-id>/pool/main/*.deb
#                <site-dir>/<application-id>/dists/stable/...
#
# Environment:
#   TERM_GPG_KEY_ID  fingerprint of the key to sign with (default: the first secret key)

set -euo pipefail

die() {
    echo "build-apt-repo: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

input="${1:-}"
site="${2:-}"
if [ -z "$input" ] || [ -z "$site" ]; then
    die "usage: build-apt-repo.sh <input-dir> <site-dir>"
fi
[ -d "$input" ] || die "input directory not found: $input"

for tool in dpkg-scanpackages apt-ftparchive gpg gzip xz awk du; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public_key="${TERM_PUBLIC_KEY:-$root/keys/term-packages.gpg}"
[ -f "$public_key" ] || die "public key not found: $public_key"

fingerprint="${TERM_GPG_KEY_ID:-}"
if [ -z "$fingerprint" ]; then
    fingerprint="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
fi
[ -n "$fingerprint" ] || die "no signing key is available"

public_fingerprint="$(gpg --show-keys --with-colons "$public_key" | awk -F: '/^fpr:/ {print $10; exit}')"
if [ "$public_fingerprint" != "$fingerprint" ]; then
    die "the signing key ($fingerprint) does not match keys/term-packages.gpg ($public_fingerprint)"
fi

rm -rf "$site"
mkdir -p "$site"
declare -A app_arches=()

# ---------------------------------------------------------------- collect

step "Collecting packages"
shopt -s nullglob
for dir in "$input"/debs-*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    name="${name#debs-}"
    arch="${name##*-}"
    app="${name%-*}"
    if [ -z "$app" ] || [ "$app" = "$name" ]; then
        die "unexpected directory name: $dir"
    fi

    debs=("$dir"/*.deb)
    [ "${#debs[@]}" -gt 0 ] || die "no .deb files in $dir"

    mkdir -p "$site/$app/pool/main"
    cp -f "${debs[@]}" "$site/$app/pool/main/"

    case " ${app_arches[$app]:-} " in
        *" $arch "*) ;;
        *) app_arches[$app]="${app_arches[$app]:-} $arch" ;;
    esac
    echo "$app / $arch: ${#debs[@]} packages"
done
[ "${#app_arches[@]}" -gt 0 ] || die "no package directories were found in $input"

# ---------------------------------------------------------------- index and sign

for app in "${!app_arches[@]}"; do
    step "Indexing $app"
    repo="$site/$app"
    suite="$repo/dists/stable"
    read -r -a arch_list <<<"${app_arches[$app]}"

    for arch in "${arch_list[@]}"; do
        index="dists/stable/main/binary-$arch"
        mkdir -p "$repo/$index"
        ( cd "$repo" && dpkg-scanpackages --arch "$arch" pool/main /dev/null > "$index/Packages" ) \
            || die "dpkg-scanpackages failed for $app / $arch"
        [ -s "$repo/$index/Packages" ] || die "the package index for $app / $arch is empty"
        gzip -9 -k -f "$repo/$index/Packages"
        xz -9 -k -f "$repo/$index/Packages"
        echo "$app / $arch: $(grep -c '^Package: ' "$repo/$index/Packages") entries"
    done

    ( cd "$repo" && apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="${TERM_REPO_ORIGIN:-Term}" \
        -o APT::FTPArchive::Release::Label="Term Packages" \
        -o APT::FTPArchive::Release::Suite="stable" \
        -o APT::FTPArchive::Release::Codename="stable" \
        -o APT::FTPArchive::Release::Architectures="${arch_list[*]}" \
        -o APT::FTPArchive::Release::Components="main" \
        release dists/stable > Release.new ) || die "apt-ftparchive failed for $app"
    mv "$repo/Release.new" "$suite/Release"

    gpg --batch --yes --pinentry-mode loopback --local-user "$fingerprint" \
        --armor --detach-sign --output "$suite/Release.gpg" "$suite/Release"
    gpg --batch --yes --pinentry-mode loopback --local-user "$fingerprint" \
        --clearsign --output "$suite/InRelease" "$suite/Release"
done

cp "$public_key" "$site/${TERM_PUBLIC_KEY_NAME:-term-packages.gpg}"
touch "$site/.nojekyll"

# ---------------------------------------------------------------- size check

step "Checking the site size"
size_mb="$(du -sm "$site" | awk '{print $1}')"
echo "site size: ${size_mb} MB"
if [ "$size_mb" -gt 900 ]; then
    die "the site is ${size_mb} MB but GitHub Pages allows at most 1 GB; shorten packages.toml"
fi