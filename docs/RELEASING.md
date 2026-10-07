# Releasing Claude Profiles

## Overview

A release is produced entirely by GitHub Actions (`.github/workflows/release.yml`) when a tag of the form `v<major>.<minor>.<patch>` is pushed. The workflow:

1. runs `swift test`,
2. builds a universal (arm64 + x86_64) `dist/Claude Profiles.app` and `dist/Claude.Profiles-<version>.zip` (`Scripts/build-app.sh`),
3. builds `dist/Claude.Profiles-<version>.dmg` (`Scripts/make-dmg.sh`),
4. generates and signs `dist/appcast.xml` (`Scripts/make-appcast.sh`, key from the `SPARKLE_PRIVATE_KEY` secret),
5. creates the GitHub Release `v<version>` with those three files as assets.

## Steps

1. Add a `## <version>` section to `CHANGELOG.md` and commit it.
2. Tag and push:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```
3. Wait for the **Release** workflow to finish, then check that the release has the DMG, the ZIP, and `appcast.xml`.

The version must be plain `x.y.z`. It is written into both `CFBundleShortVersionString` and `CFBundleVersion`; Sparkle compares `CFBundleVersion`, so every release must be numerically higher than the previous one.

## How the update feed works

The app's `SUFeedURL` is `https://github.com/un907/claude-profiles-app/releases/latest/download/appcast.xml`. GitHub redirects `releases/latest/download/<asset>` to the asset of the most recent non-prerelease, non-draft release, so the feed always resolves to the newest release's `appcast.xml`.

Because of this, each release's `appcast.xml` contains exactly one item: that release's ZIP. Older items are not needed, and `make-appcast.sh` deletes any previous `dist/appcast.xml` and uses a clean input folder so no history or delta updates are carried over. Only the ZIP is listed in the appcast; the DMG is for first-time installs by people.

Consequences:

- Marking a release as a pre-release or draft hides it from `latest`, so clients will not be offered it.
- Deleting the newest release makes the previous release's appcast live again.

## EdDSA signing key

Updates are verified with an Ed25519 key pair. The public key is embedded in the app as `SUPublicEDKey` in `Resources/Info.plist`.

The private key exists only in two places:

- the GitHub Actions secret `SPARKLE_PRIVATE_KEY`, used by the release workflow, and
- the maintainer's login Keychain, under the account `claude-profiles-app` (created with Sparkle's `generate_keys --account claude-profiles-app`). `Scripts/make-appcast.sh` uses it when `SPARKLE_PRIVATE_KEY` is not set.

Never print, commit, or log the private key. Do not add `set -x` to the release scripts.

**Do not lose the private key.** Sparkle only allows rotating the EdDSA key when the update is also signed with a Developer ID certificate, which this project does not use. If the key is lost, existing installations cannot receive further updates and users must reinstall manually from a DMG.

## Ad-hoc signing constraints

The app is signed ad-hoc (`codesign --sign -`), without a Developer ID and without notarization:

- First launch requires the user to approve the app in Gatekeeper once (see README). Updates installed by Sparkle do not need approval again.
- Hardened Runtime (`-o runtime`) is **not** enabled. With an ad-hoc signature, library validation would refuse to load the embedded `Sparkle.framework`.
- `--deep` is not used when signing. Only the outer app is signed; `Sparkle.framework` keeps the signature it was shipped with. `build-app.sh` falls back to re-signing the framework only if `codesign --verify --deep --strict` fails.
- Sparkle's installer XPC services and sandboxing are not enabled; they are only needed for sandboxed apps.
- Known issue: on recent macOS versions `hdiutil create` / `attach` print a deprecation warning that points to `diskutil image`. The commands still work, so `Scripts/make-dmg.sh` keeps using `hdiutil` for now.
- If a Developer ID is adopted later, signing, notarization, and Hardened Runtime can be added in `Scripts/build-app.sh` without changing the feed.
