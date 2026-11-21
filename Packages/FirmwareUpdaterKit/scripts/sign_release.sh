#!/bin/sh
# The maintainer's one release step (ADR 0012, #689): sign a draft firmware release CI built, then publish it.
# Run on the maintainer's Mac only, never in CI: the key and its passphrase stay here.
#
#   Packages/FirmwareUpdaterKit/scripts/sign_release.sh <tag> --key <key file> --lowest <version>
#
# 1. Checks <tag> is still a draft release.
# 2. Downloads its files (catalog.json and the files it names) to a fresh temporary folder.
# 3. firmware-release sign: shows the manifest (versions, sizes, SHA-256), asks for the passphrase, signs.
# 4. Uploads manifest.json and manifest.sig to the release, then publishes it.
# Any failure stops it before the release is published. See docs/firmware-release-signing.md.
set -eu

tag="${1:?usage: sign_release.sh <tag> --key <key file> --lowest <version>}"
shift
key="" lowest=""
while [ $# -gt 0 ]; do
    case "$1" in
        --key) key="$2"; shift 2 ;;
        --lowest) lowest="$2"; shift 2 ;;
        *) echo "sign_release.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
[ -n "$key" ] && [ -n "$lowest" ] || { echo "sign_release.sh: --key and --lowest are required" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
tool="${FIRMWARE_RELEASE:-swift run --quiet --package-path $here/.. firmware-release}"

if [ "$(gh release view "$tag" --json isDraft --jq .isDraft)" != "true" ]; then
    echo "sign_release.sh: $tag is not a draft release; refusing to sign it" >&2
    exit 1
fi

folder="$(mktemp -d)"
trap 'rm -rf "$folder"' EXIT
gh release download "$tag" --dir "$folder"
# A run that uploaded but didn't publish left the old manifest in the draft: it is re-made, never re-used.
rm -f "$folder/manifest.json" "$folder/manifest.sig"
$tool sign --key "$key" --folder "$folder" --lowest "$lowest"
gh release upload "$tag" "$folder/manifest.json" "$folder/manifest.sig" --clobber
gh release edit "$tag" --draft=false
echo "published $tag"
