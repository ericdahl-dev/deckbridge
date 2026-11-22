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
# 5. Opens a pull request that records the build just shipped in the repo's catalog (#703): merge it, so the next
#    release still lists it. Made in a temporary worktree off origin/main; your checkout isn't touched.
# Any failure before step 4 leaves the release a draft. See docs/FIRMWARE-RELEASE-SIGNING.md.
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
repo="$(git -C "$here" rev-parse --show-toplevel)"
record="$folder/record"
cleanup() {
    if [ -d "$record" ]; then git -C "$repo" worktree remove --force "$record" >/dev/null 2>&1 || true; fi
    rm -rf "$folder"
}
trap cleanup EXIT
gh release download "$tag" --dir "$folder"
# A run that uploaded but didn't publish left the old manifest in the draft: it is re-made, never re-used.
rm -f "$folder/manifest.json" "$folder/manifest.sig"
$tool sign --key "$key" --folder "$folder" --lowest "$lowest"
gh release upload "$tag" "$folder/manifest.json" "$folder/manifest.sig" --clobber
gh release edit "$tag" --draft=false
echo "published $tag"

# Record what shipped. The release is out whatever happens here; on failure, add the entry release_draft.py printed.
catalog="Packages/FirmwareUpdaterKit/Sources/FirmwareCatalog/Catalog/catalog.json"
branch="record-$tag"
git -C "$repo" fetch --quiet origin main
git -C "$repo" worktree add --quiet -b "$branch" "$record" origin/main
status=0
python3 -I "$here/record_shipped_build.py" --draft "$folder/catalog.json" --catalog "$record/$catalog" || status=$?
if [ "$status" -eq 3 ]; then
    git -C "$repo" worktree remove --force "$record"
    git -C "$repo" branch --quiet -D "$branch"
    exit 0
fi
[ "$status" -eq 0 ] || exit "$status"
git -C "$record" commit --quiet -m "Record the shipped deck panel build $tag in the updater's catalog" -- "$catalog"
git -C "$record" push --quiet -u origin "$branch"
(cd "$record" && gh pr create --base main --head "$branch" --title "Record the shipped deck panel build ($tag)" \
    --body "Adds the build $tag shipped to the updater's catalog, so the next release still lists it (#703). Made by sign_release.sh.")
