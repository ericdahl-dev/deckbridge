# Developing the Mac app

Building, testing and the smoke check are in the README's **Development** section. This page covers shipping.

## Releasing to TestFlight

Tag a version on `main` and push the tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The **Release** workflow (`.github/workflows/release.yml`) runs for tags pushed to this repository only, never for pull requests or forks. It refuses a tag that isn't on `main`. Then it:

1. Sets the marketing version from the tag (`v0.1.0` becomes `0.1.0`), and the build number to the run number plus the attempt (for example `57.1`), so re-running a tag uploads a new, higher build instead of failing as a duplicate.
2. Imports the **Apple Distribution** and **Mac Installer Distribution** certificates into a temporary keychain. A Mac upload is a signed installer package, so it needs both. Nothing is created per run, so Apple's certificate limit is never reached.
3. Gets the Mac App Store profile `ControllerBridge CI Mac App Store` through the App Store Connect API (`scripts/ci_profile.py`). It reuses the profile while it's valid for the certificate, and replaces it when it isn't.
4. Archives the app and signs it manually with that profile.
5. Runs `scripts/preflight.sh` on the archive: version and build numbers, export compliance, the category, no Dock icon, the privacy manifest, the icon, and the sandbox and network entitlements.
6. Uploads to App Store Connect. The build shows under TestFlight once Apple has processed it, usually after 5 to 15 minutes.

At the end, it always removes the key, the keychain and the profiles. When a step fails, the archive and upload logs are kept as the run's `release-logs` artifact.

After the upload, the **Distribute** job sets **What to Test** from `docs/TESTFLIGHT.md` and adds the build to the Internal group. It goes to external testers and Beta App Review only when the tag's message says `[external]`, or when the workflow is run by hand with **external** on (#244). See `docs/TESTFLIGHT.md`.

### Secrets

These are **organization secrets on `ericdahl-dev`**, shared with ShowRecorder (same Apple team), and kept in Infisical project `showrecorder`, `prod`. Never print them.

| Secret | What it is |
|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | The App Store Connect API key's id and issuer. The key's role must be able to create profiles (Admin). |
| `ASC_KEY_P8` | The key's `.p8` contents. |
| `DEVELOPMENT_TEAM` | The Apple team id. |
| `DIST_CERT_P12_BASE64`, `DIST_CERT_PASSWORD` | The Apple Distribution certificate with its private key, exported as `.p12` and run through `base64`, and the `.p12` password. |
| `MAC_INSTALLER_CERT_P12_BASE64`, `MAC_INSTALLER_CERT_PASSWORD` | The Mac Installer Distribution certificate, exported the same way. |

If any of these is missing, the workflow's first step says so and stops.

Both certificates last a year, and the workflow prints their expiry dates. Renewing one renews it for both apps: make the new certificate, export it as `.p12`, and update the two org secrets once. Keep an encrypted copy of each `.p12` and its password off the Mac.

### One-time setup (humans)

These steps are tracked on #28:

1. The macOS App ID `dev.ericdahl.ControllerBridge` is registered in the developer account (done). `ci_profile.py` never registers one.
2. Create the app record in App Store Connect (platform macOS, bundle id `dev.ericdahl.ControllerBridge`) once the name is picked (#29).
3. Make the secrets above available to this repository as org secrets.
4. Create an internal TestFlight group and add yourself.
5. Tag `v0.1.0`. Then install the TestFlight build on a Mac with the controller (or the smoke script's virtual source) and check that Play bridges end to end in the real App Store sandbox.

### Checking the release scripts

The workflow can't run without the secrets, so its scripts are tested on every pull request (`ci.yml`: the Kit tests
job, and the release docs in the Site check job, which a docs-only change also runs):

```sh
scripts/test-preflight.sh            # fake app bundles: a good one passes, each fault fails with its own line
scripts/test-tag-external.sh         # only [external] in an annotated tag's message sends a release out (#244)
python3 -I scripts/test_ci_profile.py  # ci_profile.py against a fake App Store Connect API
python3 -I scripts/test_testflight_distribute.py  # What to Test, groups and Beta App Review, against a fake API
python3 -I scripts/test_release_docs.py  # the release checklist and What to Test (Site check job)
scripts/preflight.sh build/Build/Products/Release/ControllerBridge.app   # a real Release build
```

### When an upload fails

Open the run's **Archive**, **Check the archive** or **Upload to TestFlight** step, or the `release-logs` artifact.

| Message | Cause and fix |
|---|---|
| Preflight `FAIL:` line | Something App Store Connect would refuse. Run `scripts/preflight.sh` on a local Release build and fix it. |
| `Missing release secrets` | An org secret isn't set or isn't shared with this repository. |
| `Authentication failed` or `401` | The key, issuer or `.p8` is wrong, or the key was revoked. Make a new key and update the secrets. |
| `security import` fails | A `.p12` secret is empty, or its password is wrong. Re-export it and update both of its secrets. |
| `serial mismatch` from `ci_profile.py` | The certificate in the secret was revoked or isn't in this team. Make and store a new one. |
| `No bundle ID dev.ericdahl.ControllerBridge` | The macOS App ID isn't registered. Register it in the developer account. |
| `bundle version must be higher` | A build with that number already exists. Re-run the workflow; the attempt number raises it. |
| `Tag ... is not on main` | Merge first, then tag the merged commit. |
