#!/bin/bash
# Generates the GPG key pair that signs the Nexus apt (hosted) repository.
#   config/nexus/apt-signing.pub.asc  -> committed, baked into the image as the trusted apt key
#   config/nexus/apt-signing.key.asc  -> PRIVATE, git-ignored, pasted into the Nexus repo settings
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIR="$ROOT/config/nexus"
mkdir -p "$DIR"
if [ -f "$DIR/apt-signing.pub.asc" ]; then
	echo "key already exists: $DIR/apt-signing.pub.asc (delete both files to regenerate)"; exit 0
fi
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --gen-key <<GEN
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: ubuntu-lite apt signing
Name-Email: ubuntu-lite@nexus.local
Expire-Date: 0
%commit
GEN
gpg --batch --quiet --armor --export ubuntu-lite@nexus.local > "$DIR/apt-signing.pub.asc"
gpg --batch --quiet --armor --export-secret-keys ubuntu-lite@nexus.local > "$DIR/apt-signing.key.asc"
chmod 600 "$DIR/apt-signing.key.asc"
cat <<MSG
Generated:
  $DIR/apt-signing.pub.asc   (commit this; the image trusts it)
  $DIR/apt-signing.key.asc   (KEEP PRIVATE; paste into Nexus > apt-lite > Signing Key, no passphrase)
MSG
