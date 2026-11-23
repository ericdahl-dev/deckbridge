# Signing firmware releases (owner guide)

The firmware updater (#684) fetches a firmware release newer than the one built into it only if the release's
manifest is signed by a key the app trusts. ADR 0012 records why. This guide is the owner's: agents never make, hold or
use a release key.

## The key file

- One file per key, written by `firmware-release new-key`, readable only by you (mode 600).
- **Format** (`deckbridge-release-key-1`): JSON holding the key's id, its public key, and the 32-byte Ed25519 seed
  sealed with AES-256-GCM. The AES key comes from your passphrase with PBKDF2-SHA256, 600,000 rounds and a 16-byte
  random salt. The id and public key are bound to the seal, so a relabeled file doesn't open.
- **The passphrase is typed by you at signing**, with echo off. It is never taken from an argument, an environment
  variable or a file, and never goes near CI or the repo.
- **A forgotten passphrase is a lost key.** Nothing can open the file without it. Sign with the backup key instead
  (see "A lost key" below).

## Once: make the two keys (when the first signed release is cut)

On your Mac, outside the repo:

```sh
cd Packages/FirmwareUpdaterKit
swift run firmware-release new-key --id primary --out ~/.deckbridge-keys/primary.key
swift run firmware-release new-key --id backup --out /Volumes/<USB stick>/backup.key
```

- Use a different passphrase for each, at least 12 characters, kept in your password manager.
- Keep the backup key **off this Mac**: a USB stick in a drawer, or printed. It is only for when the primary is lost.
- **Then the one step that adds them to the app.** Until it's done the app trusts no key, so it refuses every fetched
  release and uses its built-in firmware. That is the safe default. Run `swift run firmware-release public-key <file>`
  for each key. Each prints `<id> <64 hex characters>`. Put both in `listed` in
  `Sources/FirmwareRelease/ReleaseKeys.swift`, as `("primary", "<hex>"), ("backup", "<hex>")`, in a pull request.
  Public keys aren't secret. A test fails on a mistyped key.
  Done 2026-11-23: the owner's primary and backup public keys are in `ReleaseKeys.swift`, and the deck panel's
  `release_keys.h` (#690) must hold the same pair.

## Each release: one command

1. Bump `tools/deck-panel/VERSION` in the release pull request and merge it.
2. Tag that commit `deck-panel-v<VERSION>` and push the tag. The Deck panel release workflow
   (`.github/workflows/deck-panel-release.yml`, #703) builds the panel image and leaves it, with the catalog, in an
   **unsigned draft** release. The draft holds `catalog.json` and the files it names, with flat names, and nothing
   else. It refuses a tag that doesn't match `VERSION`, and a dirty build. It uses no key and no secrets.

   The same draft also carries:
   - the panel build's bootloader and partition table, so the app can make a blank board a deck panel (#687);
   - the drawn jog display's own code, `block-a.bin` and `block-b.bin`, with their `build.json` (#707).

   The workflow builds the blocks from this commit's source with Ubuntu's Arm toolchain. It refuses a dirty, unknown or
   unproven build, then builds them again from scratch and checks the draft's copies match byte for byte. Nothing of
   Denon's is built, attached or downloaded.

   **A block change ships only with a deck panel release.** The app takes the newest release only when its panel
   version is newer, so to ship new blocks, bump `tools/deck-panel/VERSION` too. One release stream keeps the app's
   "latest" release honest.

   **Every published release carries the current `manifest.json` and `manifest.sig`.** The updater reads GitHub's
   newest published release (`/releases/latest/download/manifest.json`), whatever kind it is. A release without a
   manifest published after a firmware release hides that firmware: the updater says no signed firmware release is
   published. So don't publish an app-only GitHub release. If one is ever needed, attach the current firmware
   release's files to it, or create it with `gh release create --latest=false` so the firmware release stays
   "latest". Today only this workflow creates releases (`release.yml` ships the app through TestFlight, not GitHub).
3. On your Mac:

```sh
Packages/FirmwareUpdaterKit/scripts/sign_release.sh <tag> --key ~/.deckbridge-keys/primary.key --lowest <version>
```

- `--lowest` is the lowest panel version a panel may go back to over Wi-Fi. Raise it only for a security fix.
- The script checks the release is still a draft, downloads it, and shows the manifest (each file's device, version,
  size and SHA-256: `deck-panel`, `deck-panel-bootloader`, `deck-panel-partitions`, `lc6000-wd` and `lc6000-tp`,
  and `lc6000-blocks-record` for `build.json`). It asks for your passphrase only after that. Then it uploads `manifest.json` and
  `manifest.sig` and publishes the release.
- If anything fails before publishing, the release stays a draft.
- After publishing, it opens a small pull request that records the build in
  `Packages/FirmwareUpdaterKit/Sources/FirmwareCatalog/Catalog/catalog.json`. **Merge it.** The next release must
  still list every build shipped, or an app carrying this one refuses it. If the pull request isn't made, add the
  `record:` line the draft job printed in its log by hand.

## A lost key

- **Primary lost or passphrase forgotten:** sign the next release with the backup key (`--key` the backup file). The
  app already trusts it. In that release, put a new backup key in `ReleaseKeys.swift`, and keep the new backup offline.
- **Both lost:** no fetched release can be trusted. Re-release the updater from the site with new keys; panels then
  need one cable flash through it. ADR 0012 has the details.
- **A key stolen:** drop it from `ReleaseKeys.swift` in the next app and firmware release.
