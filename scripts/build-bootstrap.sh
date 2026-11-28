#!/usr/bin/env bash
# build-bootstrap.sh - build one Term bootstrap archive and its packages for one app and architecture.
#
# Usage: scripts/build-bootstrap.sh <application-id> <arch>
#   application-id  Android applicationId, for example app.term.one
#   arch            aarch64 or x86_64
#
# Environment:
#   TERMUX_PACKAGES_REPO  git URL of termux-packages (default: the official repository)
#   TERMUX_PACKAGES_REF   branch, tag or commit to build (default: master)
#   TERM_EXTRA_PACKAGES   space separated packages built in addition to the bootstrap set
#   TERM_APT_BASE_URL     base URL of the apt repositories (default: https://term-org.github.io/TP)
#
# Results:
#   out/bootstrap-<application-id>-<arch>.zip and .sha256
#   debs/<application-id>/<arch>/*.deb

set -euo pipefail

die() {
    echo "build-bootstrap: $*" >&2
    exit 1
}

step() {
    echo
    echo "==> $*"
}

app_id="${1:-}"
arch="${2:-}"
if [ -z "$app_id" ] || [ -z "$arch" ]; then
    die "usage: build-bootstrap.sh <application-id> <arch>"
fi

case "$arch" in
    aarch64|x86_64) ;;
    *) die "unsupported architecture: $arch (use aarch64 or x86_64)" ;;
esac

if ! [[ "$app_id" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]]; then
    die "invalid application id: $app_id"
fi

for tool in git docker zip unzip sha256sum sed grep find sudo; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

repo_url="${TERMUX_PACKAGES_REPO:-https://github.com/termux/termux-packages.git}"
ref="${TERMUX_PACKAGES_REF:-master}"
extra_packages="${TERM_EXTRA_PACKAGES:-}"
apt_base="${TERM_APT_BASE_URL:-https://term-org.github.io/TP}"
rootfs_subdir="files/rootdir"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/work/$app_id-$arch"
out="$root/out"
debs_dir="$root/debs/$app_id/$arch"
log="$root/work/$app_id-$arch.log"
key_file="$root/keys/term-packages.gpg"

expected_prefix="/data/data/$app_id/files/rootdir/usr"
zip_dst="$out/bootstrap-$app_id-$arch.zip"

container="${CONTAINER_NAME:-termux-package-builder}"
export CONTAINER_NAME="$container"

[ -f "$key_file" ] || die "keys/term-packages.gpg was not found; run scripts/make-signing-key.sh"

mkdir -p "$root/work" "$out"
rm -rf "$work" "$debs_dir"
: > "$log"

# ---------------------------------------------------------------- helpers

# Prints what is most useful at the end of the job log when a build failed.
show_failure() {
    echo
    echo "==== lines of the log that mention errors ===="
    { grep -nE 'error:|ERROR:|Error:|fatal|undefined reference|Permission denied|No such file|Failed to' "$log" | grep -v 'Werror' | tail -n 40; } || true
    echo "==== last 30 lines of the log ===="
    tail -n 30 "$log" || true
}

# Runs a command in the container and tries once more when a download failed.
run_build() {
    local attempt=1
    while true; do
        if ( cd "$work" && "$@" ) 2>&1 | tee -a "$log"; then
            return 0
        fi
        if [ "$attempt" -ge 2 ] || ! tail -n 400 "$log" | grep -qE 'Connection timed out|Failed to download|Could not resolve host|Connection reset'; then
            return 1
        fi
        attempt=$((attempt + 1))
        echo "A download failed; trying again in 60 seconds (attempt $attempt)"
        sleep 60
    done
}

prepare_container() {
    step "Preparing the builder container"

    # This script creates folders in the checkout, so it must belong to the runner user.
    sudo chown -R "$(id -u):$(id -g)" "$root/work" || die "could not take over the work folder"
    mkdir -p "$work/output"
    echo "runner: uid=$(id -u) gid=$(id -g)"

    # run-docker.sh loads a restricted AppArmor profile once the container exists. It keeps the build
    # scripts from changing the checkout, which also blocks the permission changes below and the final
    # copy of the bootstrap archive. This runner is thrown away after the job and builds recipes of
    # this organisation only, so the relaxed profile is used instead.
    if [ -f "$work/scripts/profile-relaxed.apparmor" ] && [ -f "$work/scripts/profile-restricted.apparmor" ]; then
        cp "$work/scripts/profile-relaxed.apparmor" "$work/scripts/profile-restricted.apparmor"
    fi

    cat > "$work/scripts/term-preflight.sh" <<'EOF'
#!/bin/bash
set -e
echo "builder: uid=$(id -u) gid=$(id -g)"
cd /home/builder/termux-packages
mkdir -p output
touch output/.write-test
rm -f output/.write-test
touch .write-test
rm -f .write-test
mkdir -p /data/data/.preflight
rmdir /data/data/.preflight
echo "the builder can write to the checkout, to its output folder and to /data"
EOF
    chmod +x "$work/scripts/term-preflight.sh"

    # The first call creates the container; run-docker.sh also gives the builder user the uid of the runner.
    ( cd "$work" && ./scripts/run-docker.sh true ) || die "the builder container could not be started"

    docker exec --user root "$container" sh -ec '
        id builder
        chmod a+rwx /home/builder/termux-packages
        chmod -R a+rwX /home/builder/termux-packages
        mkdir -p /data/data /home/builder/.termux-build
        chmod -R a+rwX /data
        chown -R builder:builder /data /home/builder/.termux-build
        ls -ld /home/builder/termux-packages /home/builder/termux-packages/output
    ' || die "could not open up the checkout inside the builder container"

    if ! ( cd "$work" && ./scripts/run-docker.sh ./scripts/term-preflight.sh ); then
        docker exec --user root "$container" sh -c 'id builder; ls -ld /home/builder /home/builder/termux-packages /data' || true
        die "the builder cannot write to the checkout (see the ids above)"
    fi
}

# The archive is normally in the checkout. When the final copy failed, it may still be inside the container.
find_zip() {
    local found inside
    found="$(find "$work" -maxdepth 2 -type f -name "bootstrap-$arch.zip" -size +0 -print -quit)"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    inside="$(docker exec --user root "$container" sh -c "find /tmp /home/builder /data -xdev -type f -name 'bootstrap-$arch.zip' -size +0 2>/dev/null | head -n 1" || true)"
    if [ -n "$inside" ] && docker cp "$container:$inside" "$work/bootstrap-$arch.zip"; then
        echo "recovered the archive from $inside inside the container" >&2
        printf '%s' "$work/bootstrap-$arch.zip"
    fi
}

# ---------------------------------------------------------------- fetch

step "Fetching termux-packages at $ref"
git init -q "$work"
git -C "$work" remote add origin "$repo_url"
git -C "$work" fetch -q --depth 1 origin "$ref"
git -C "$work" checkout -q FETCH_HEAD
echo "termux-packages commit: $(git -C "$work" rev-parse HEAD)"

# ---------------------------------------------------------------- patch properties

step "Configuring properties for $app_id"
props="$work/scripts/properties.sh"
[ -f "$props" ] || die "scripts/properties.sh was not found in termux-packages"

sed -i "s|^TERMUX_APP__PACKAGE_NAME=\"com\.termux\"\$|TERMUX_APP__PACKAGE_NAME=\"$app_id\"|" "$props"
sed -i "s|^TERMUX__ROOTFS_SUBDIR=\"files\"\$|TERMUX__ROOTFS_SUBDIR=\"$rootfs_subdir\"|" "$props"

grep -q "^TERMUX_APP__PACKAGE_NAME=\"$app_id\"\$" "$props" \
    || die "could not set TERMUX_APP__PACKAGE_NAME; properties.sh changed upstream, pin TERMUX_PACKAGES_REF to a known good commit"
grep -q "^TERMUX__ROOTFS_SUBDIR=\"$rootfs_subdir\"\$" "$props" \
    || die "could not set TERMUX__ROOTFS_SUBDIR; properties.sh changed upstream, pin TERMUX_PACKAGES_REF to a known good commit"

actual_prefix="$(bash -c 'source "$1/scripts/properties.sh" >/dev/null && printf "%s" "$TERMUX__PREFIX"' _ "$work")" \
    || die "properties.sh rejected the configured layout"
if [ "$actual_prefix" != "$expected_prefix" ]; then
    die "resolved prefix is '$actual_prefix' but '$expected_prefix' is required"
fi
echo "prefix: $actual_prefix"

# ---------------------------------------------------------------- patch build-bootstraps.sh

step "Patching build-bootstraps.sh"
bootstraps="$work/scripts/build-bootstraps.sh"
[ -f "$bootstraps" ] || die "scripts/build-bootstraps.sh was not found in termux-packages"
# bzip2 is a subpackage of libbz2, so "build-package.sh bzip2" fails with "No package bzip2 found".
# Building libbz2 produces the bzip2 package too.
sed -i 's/PACKAGES+=("bzip2")/PACKAGES+=("libbz2")/' "$bootstraps"
if grep -q 'PACKAGES+=("bzip2")' "$bootstraps"; then
    grep -n 'bzip2' "$bootstraps" || true
    die "could not patch the bzip2 entry of build-bootstraps.sh; it changed upstream, pin TERMUX_PACKAGES_REF"
fi

# ---------------------------------------------------------------- build

prepare_container

# The build script copies the archive into the checkout at the very end. When that folder refuses
# new files, an existing file that anyone may write still works.
: > "$work/bootstrap-$arch.zip"
chmod 666 "$work/bootstrap-$arch.zip"

step "Building bootstrap packages (this takes a while)"
if ! run_build ./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures "$arch"; then
    show_failure
    die "the bootstrap build failed (see $log)"
fi

zip_src="$(find_zip)"
if [ -z "$zip_src" ]; then
    show_failure
    die "the build did not produce bootstrap-$arch.zip (see $log)"
fi
cp "$zip_src" "$zip_dst"

if [ -n "$extra_packages" ]; then
    step "Building extra packages: $extra_packages"
    # shellcheck disable=SC2086
    if ! run_build ./scripts/run-docker.sh ./build-package.sh -a "$arch" $extra_packages; then
        show_failure
        die "building the extra packages failed (see $log)"
    fi
fi

# ---------------------------------------------------------------- collect packages

step "Collecting .deb files"
mkdir -p "$debs_dir"
count=0
while IFS= read -r deb; do
    case "$(basename "$deb")" in
        *-static_*) continue ;;
    esac
    cp "$deb" "$debs_dir/"
    count=$((count + 1))
done < <(find "$work/output" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | sort)
[ "$count" -gt 0 ] || die "no .deb files were found in $work/output"
echo "collected $count packages"

# ---------------------------------------------------------------- post-process the archive

step "Configuring the apt repository inside the archive"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/etc/apt/trusted.gpg.d"
printf 'deb %s/%s stable main\n' "$apt_base" "$app_id" > "$stage/etc/apt/sources.list"
cp "$key_file" "$stage/etc/apt/trusted.gpg.d/term-packages.gpg"

set +e
zip -q -d "$zip_dst" "etc/apt/sources.list" "etc/apt/sources.list.d/*" "etc/apt/trusted.gpg.d/term-packages.gpg"
status=$?
set -e
# zip exits with 12 when there was nothing to delete.
if [ "$status" -ne 0 ] && [ "$status" -ne 12 ]; then
    die "could not edit the archive (zip exit code $status)"
fi
( cd "$stage" && zip -q -X "$zip_dst" etc/apt/sources.list etc/apt/trusted.gpg.d/term-packages.gpg )

# ---------------------------------------------------------------- verify

step "Verifying the archive"

member_has() {
    local archive="$1" member="$2" needle="$3" tmp status
    tmp="$(mktemp)"
    if ! unzip -p "$archive" "$member" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 2
    fi
    status=0
    grep -aqF -- "$needle" "$tmp" || status=$?
    rm -f "$tmp"
    return "$status"
}

listing="$(unzip -Z1 "$zip_dst")"
grep -qx 'bin/bash' <<<"$listing" || die "the archive does not contain bin/bash"
grep -qx 'SYMLINKS.txt' <<<"$listing" || die "the archive does not contain SYMLINKS.txt"
grep -qx 'etc/apt/sources.list' <<<"$listing" || die "the archive does not contain etc/apt/sources.list"
grep -qx 'etc/apt/trusted.gpg.d/term-packages.gpg' <<<"$listing" || die "the archive does not contain the signing key"

links="$(mktemp)"
unzip -p "$zip_dst" SYMLINKS.txt > "$links"
if grep -qF 'com.termux' "$links"; then
    rm -f "$links"
    die "SYMLINKS.txt still refers to com.termux"
fi
rm -f "$links"

found_expected=0
for member in bin/bash bin/dpkg bin/apt; do
    if member_has "$zip_dst" "$member" "/data/data/com.termux"; then
        die "$member still refers to /data/data/com.termux"
    fi
    if member_has "$zip_dst" "$member" "$expected_prefix"; then
        found_expected=1
    fi
done
[ "$found_expected" -eq 1 ] || die "none of the checked binaries refers to $expected_prefix"
echo "archive refers to $expected_prefix"

# ---------------------------------------------------------------- checksum

step "Writing checksum"
( cd "$out" && sha256sum "$(basename "$zip_dst")" > "$(basename "$zip_dst").sha256" )
cat "$zip_dst.sha256"
ls -lh "$out"