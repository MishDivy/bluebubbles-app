# BlueBubbles preview releases

The `divy` Android flavor is an isolated candidate for testing custom reactions.
It does not replace the official app. No signed release, signing key, download
website, or phone installation has been created by this implementation.

## Package and build identity

- Application ID: `com.bluebubbles.messaging.divy`.
- Display name: `BlueBubbles Preview (Divy)`.
- Minimum Android API: 26, inherited from the upstream app.
- `versionCode`: the full `--build-number` value, independent of upstream's offset.
  Allocate a strictly increasing positive integer for each published candidate.
- Tag format: `v<upstream version>+<preview build number>-divy`, for example
  `v2.1.1+1-divy`. The example is not a published release or an allocated build.
- Keep personal packaging changes separate from reaction commits when preparing
  upstream contributions. Preserve upstream licenses and authorship.

CI compiles a debug-signed ARM64 APK only to detect build errors. It does not
upload, publish, or install that APK. Do not use a debug build as the everyday app.

## Before the first release

1. Complete the app/server/helper acceptance matrix in `CUSTOM_REACTIONS.md`.
   Record exact commits and capability results; synthetic tests are not evidence
   of native delivery. Keep existing official client and Mac rollback material.
2. Create a dedicated release signing key through an approved local procedure.
   Keep it and `android/key.properties` outside Git, with an encrypted backup and
   a documented owner. Never use the upstream key, a debug key, or a new key for
   every version. If CI signing is later introduced, restrict it to approved
   release jobs; pull requests must never receive signing credentials.
3. Verify Firebase registration and background delivery for the new package ID.
   Also test file-provider authorities, share targets, links, and notification
   permissions. Do not assume success because another flavor uses the same server.
4. Back up/export supported local preferences and verify their restore path.
   A fresh preview install can sync Messages history from the server, but that
   does not establish preservation of local drafts, preferences, or cached media.
5. Build with pinned Flutter 3.44.6, Java 21 and the checked-in dependency lockfile.
   Supply the approved signing configuration locally, then use `flutter build apk
   --release --flavor divy --build-name <version> --build-number <allocated number>`.
   Verify the APK application ID, version, release certificate and SHA-256 before
   distributing it. Release builds must fail if the release key is unavailable.

## Downloads and updates

The preview's existing update checker reads only non-draft, non-prerelease
releases in `MishDivy/bluebubbles-app` whose tags match the preview format above.
No matching release means no update prompt. It compares the complete build
number, not the upstream app's truncated counter. The official package keeps
its upstream update source. Checking does not install anything.

After explicit publication approval, publish only verified, release-signed APKs
with immutable versioned filenames, SHA-256, certificate fingerprint, source
commit, compatible server/helper commits, limitations and release notes. Keep
previous releases. The fork's GitHub Releases page is the initial browser
download location; no GitHub login is required for a public release. Do not
publish signing files, Firebase credentials, Messages data, or sticker artwork.

Before daily use, test an update from an earlier release: settings, permissions,
history and favorites must survive. Test a cancelled or interrupted download.
Android's package installer remains the installation authority and verifies the
signing identity. A SHA-256 checksum alone does not authenticate the publisher.

A private `health.home`-style download page/feed remains a separate deployment
gate. If requested, follow `divy-mac-utils/docs/releases.md` and inspect the
existing home release process before implementing it. Do not create a daemon,
new public port, or an unmaintained auto-updater to serve an APK.

## Returning to official releases

Once official releases contain equivalent fixes, rerun the same compatibility
tests and retire the corresponding fork patches. Switch back to the official
app deliberately: different package IDs and signing keys do not support an
in-place cross-signed update. Verify history resync and supported settings export
before removing the preview. Keep only the chosen daily client's notifications
enabled to avoid duplicates.

Do not promise an ordinary downgrade to an older preview APK. Android normally
rejects lower version codes; prefer a forward-fix release signed with the same
key, or a reviewed data-preserving recovery procedure. Installation and Mac
service activation require their own approval and rollback checks.
