#!/usr/bin/env bash
# make-signing-key.sh - create the GPG key that signs the Term apt repositories.
#
# Run it once on a trusted machine (the phone is fine). It writes:
#   keys/term-packages.gpg   public key, commit this file
#   private-key.asc          private key, store it as a GitHub secret and delete it

set -euo pipefail

die() {
    echo "make-signing-key: $*" >&2
    exit 1
}

command -v gpg >/dev/null 2>&1 || die "gpg was not found"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public_key="$root/keys/term-packages.gpg"
private_key="$root/private-key.asc"

if [ -e "$public_key" ] || [ -e "$private_key" ]; then
    die "$public_key or $private_key already exists; refusing to overwrite"
fi

gnupg_home="$(mktemp -d)"
chmod 700 "$gnupg_home"
export GNUPGHOME="$gnupg_home"
cleanup() {
    gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf "$gnupg_home"
}
trap cleanup EXIT

gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "Term Packages" rsa4096 sign never

fingerprint="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
[ -n "$fingerprint" ] || die "the key was not created"

mkdir -p "$root/keys"
gpg --export "$fingerprint" > "$public_key"
gpg --armor --export-secret-keys "$fingerprint" > "$private_key"
chmod 600 "$private_key"

cat <<EOF

Key created: $fingerprint

Next steps:
  1. Commit keys/term-packages.gpg.
  2. In the GitHub repository open Settings > Secrets and variables > Actions,
     create a secret named TERM_GPG_PRIVATE_KEY and paste the whole content of
     private-key.asc into it.
  3. Delete private-key.asc from this machine.
EOF
