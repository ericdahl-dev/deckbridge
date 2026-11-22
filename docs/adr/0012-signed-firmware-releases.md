# Firmware releases are signed by the maintainer, and the updater and the panel check the signature

2026-11-21. **Decided by the owner: option 1, an Ed25519 key on the maintainer's Mac** (#689, spec #684). The firmware updater (#684) can fetch a firmware release newer than the one it was built with, and the deck panel can take an update over Wi-Fi (#690). Both must accept only files that this project's maintainer released. The key that signs them is the maintainer's. It is never in the repo, and never printed in CI logs.

## What is signed

Each release has one small **manifest**, and only the manifest is signed. It names, for each file in the release:

- the device it is for (`deck-panel` board, or `lc6000` with the stock firmware versions the patch set fits);
- the firmware version;
- the file's size and SHA-256.

It also holds the lowest version a device may go back to (see below). The files themselves are hashed, not signed: the deck panel image and the LC6000 patch set. The patch set holds patch descriptions only: addresses and our own bytes, never Denon's (#684). A file whose size or hash differs from the manifest is refused, so the manifest's signature covers it.

## Who checks what

| Where | Checks | When |
|---|---|---|
| Updater on the Mac | The manifest's signature against the keys built into the app, then each file's size and SHA-256, then the version rules (newer than the built-in one, fits this device) | Before a fetched release is shown as an offer. Built-in firmware ships inside the notarized app, so Apple's signature on the app covers it |
| Deck panel, Wi-Fi update (#690) | The same manifest signature against the keys built into its running firmware, the image's SHA-256 as it arrives in the spare slot, the device name, and the version rule | Before it switches slots. Anything else leaves the old firmware running |
| Deck panel, cable flash | Nothing. The ESP32's ROM serial bootloader writes any image unless Secure Boot is burned into its eFuses (out of scope, below) | The updater's check on the Mac is the only one |
| LC6000 | Nothing. ST's ROM DFU writes anything | The updater's check, then its read-back-and-compare (#693) |

**Going back.** The updater offers only a version newer than the device's. A signed manifest can set a lowest allowed version, so a release with a security fix can stop a panel taking the older, still validly signed image over Wi-Fi. Restoring the owner's own LC6000 backup is never refused: the backup is their file, not a release.

## Options considered

### 1. Ed25519, key kept offline on the maintainer's Mac, signed by a local release step (chosen)

- **Scheme:** Ed25519 over the manifest. CryptoKit has it on the Mac (`Curve25519.Signing`). On the panel: see "The panel's side".
- **The key:** made once on the maintainer's Mac, stored encrypted with a passphrase: PBKDF2-SHA256, 600,000 rounds, 16-byte random salt, deriving an AES-256-GCM key that seals the 32-byte Ed25519 seed (Apple's CommonCrypto and CryptoKit, no extra tool). The owner types the passphrase at signing; it is never read from an environment variable or a file. A forgotten passphrase is a lost key: sign with the backup key. The key file is kept off GitHub. A second key, the **backup key**, is made at the same time and kept offline somewhere else (printed or on a USB stick in a drawer). The updater and the panel trust both public keys from day one.
- **Release step:**
  1. CI builds the release files on a tag as today and uploads them unsigned to a draft GitHub release.
  2. The maintainer runs one script locally. It downloads the draft's files, writes the manifest, shows the versions and hashes, signs after the passphrase, and uploads the manifest and its signature.
  3. The script publishes the release.
- The key never reaches CI, so it can't appear in a CI log. The cost is one manual step per release.

### 2. ECDSA P-256 on a hardware key (YubiKey PIV, or the Mac's Secure Enclave): rejected

- **Scheme:** ECDSA P-256 over the manifest. CryptoKit has it on the Mac (`P256.Signing`).
- **The key:** made on the device itself, and it can't be copied out. Nothing can steal it except the device, and signing needs a touch or Touch ID.
- **Release step:** as in option 1.
- **Losing the device loses the key for good.** A second hardware key, enrolled as the backup key from day one, is required. A Secure Enclave key dies with its Mac.

### 3. Ed25519, key in a protected GitHub Actions secret, CI signs on tag: rejected

- **The key:** a repository environment secret. The environment has a required reviewer, so a signing run waits for the maintainer's approval.
- **Release step:** fully automatic after the approval click. It's the "one step" of #684 story 25 in its most literal form.
- **Costs:**
  - The key lives on GitHub's servers.
  - Any workflow change merged to main that reaches the environment can use the key, or print it. GitHub masks printed secrets, but an encoded value gets past the mask.
  - #689 says the key is "never in CI logs". This option keeps that rule by review, not by construction.

## Why option 1

The key never leaves the maintainer's control, nothing in CI can use it, and the backup key makes a lost key recoverable. One local command per release fits a project with one maintainer and a few releases a year. **Option 2 rejected:** stronger against a stolen laptop, but needs two hardware keys bought and kept, and a lost device loses its key for good. **Option 3 rejected:** the most convenient, but the key lives on GitHub, where a merged workflow change could use or leak it.

## Key rotation and a lost key

- The updater and the panel each trust a short list of public keys, built in. A new app or firmware release can add or drop a key; nothing changes a running panel's list except a new firmware image.
- **Routine rotation:** release once signed by the old key, carrying the new key in the list. From then on, sign with the new key. Drop the old key a release later.
- **Primary key lost:** sign the next release with the backup key, and put a new backup key in that release's list. Devices already trust the backup key, so nothing is stranded.
- **Both keys lost:** no new release can be fetched or sent over Wi-Fi to an existing panel.
  - The updater recovers by being re-released from the site with new keys. Apple's notarization is the trust for the app itself.
  - Panels then need one cable flash through the new updater to trust the new keys.
  - The LC6000 is unaffected: it checks nothing, and its patch sets come with the app.
- **A key stolen:** treat it like a lost key and drop it from the next app and firmware.
  - Until a panel takes that firmware, it still accepts images signed by the stolen key, from anyone on its network.
  - The updater refuses the stolen key as soon as the owner installs the new app.
  - The ADR accepts this window: there is no revocation list for a display that isn't online.

## The panel's side (#690)

This section is an Embedded Firmware Engineer agent's reading of the installed toolchain:
- Arduino-ESP32 3.3.9 on ESP-IDF v5.5.4;
- mbedTLS 3.6.5;
- the shipped sdkconfig.

Nothing was flashed. **V** means read in a file or in command output. **I** means inferred, to be measured in #690.

- **Two slots already.** `partitions.csv` has had `otadata` and two 6.25 MB app slots since #615, and a full flash writes `otadata` (V). Today's image is 1.76 MB (V).
  - Panels flashed with this layout need no layout change for #690 (I: which panels were flashed that way isn't recorded).
- **Each option on the S3:**

  | | Ed25519 (options 1, 3) | ECDSA P-256 (option 2) |
  |---|---|---|
  | Library | Not in mbedTLS 3.6. libsodium 1.0.22 ships precompiled with the framework (V) | mbedTLS, already linked, with the hardware big-number unit (V) |
  | Hardware help | None (I) | The S3 has no ECDSA unit (V) |
  | Verify time | About 10-30 ms, software (I) | About 30-80 ms (I) |
  | Extra flash | About 10-30 KB, to link libsodium (I) | About 0 (I) |
  | Public key | 32 bytes | 65 bytes |

  - Either way it's one call, run once per update. Done on core 0 at low priority, it should leave the 30 Hz screen alone (I). The screen loop and the panel interrupts run on core 1; Wi-Fi runs on core 0 (V).
  - RSA-3072, what the S3's Secure Boot uses, would verify in a few ms with the hardware RSA unit. It buys nothing without Secure Boot (I).
- **Hashing during the transfer.** The hardware SHA-256 is on (V). The panel hashes each chunk as it writes it to the spare slot, then checks the manifest's signature once.
- **The real cost of an update is the flash write, not the crypto.** A flash erase or write turns the cache off on both cores, and PSRAM is reached through the cache. The RGB interrupt isn't built IRAM-safe (V), so the screen will tear or shift while an update writes (I, near certain).
  - #690 shows a still "Updating" screen, or turns the backlight off, for the length of the transfer.
  - It gives `esp_ota_begin` the image's real size, so only that much of the slot is erased, not all 6.25 MB (V: `esp_ota_ops.h`).
  - Normal running is unaffected, which #690's perf-line criterion checks.
- **Switch and fall-back.** Rollback is on in the shipped bootloader config (V).
  - Arduino marks a new image good as soon as it boots, unless the firmware overrides the weak `verifyRollbackLater()` (V: `esp32-hal-misc.c`).
  - #690 overrides it. The new image is marked good only once Wi-Fi and the feed work; otherwise the next reset goes back to the old slot.
  - Use `esp_ota_*` directly, not Arduino's `Update`.
- **The lowest allowed version** is kept in the panel's NVS and only ever raised, not in eFuses (I: eFuse secure versions are one-way and few).
- **Trusted keys** are a built-in array, primary and backup. The manifest names which key signed it. A key costs 32 bytes with Ed25519.
- **One check before code:** CryptoKit makes randomized Ed25519 signatures that are still valid under RFC 8032 (I). The first test signs with CryptoKit and verifies with libsodium's `crypto_sign_verify_detached`.

**The agent's finding:** Ed25519 has no blocker on the panel. ECDSA P-256 would have worked as well, with no code added to the panel.

## Out of scope

- **Secure Boot v2 and flash encryption on the panel.** Both are one-way eFuse burns. A mistake bricks the board, and a burned board accepts only images signed by that one key, over the cable too. They would close the cable gap, but at a cost the owner of a hobby display shouldn't carry.
- **Signing the Mac app itself.** Apple's Developer ID signing and notarization cover it, as for DeckBridge.
- **Apple's signature on the firmware files.** Apple doesn't offer it. The firmware files are ours, so the trust in them comes from our key.
