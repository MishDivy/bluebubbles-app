# BlueBubbles preview releases

The `divy` Android flavor is an isolated candidate for testing custom reactions.
It uses its own package ID and data directory. Candidate CI builds produce an
unsigned release APK; local signing and device acceptance precede publication.

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

CI builds an unsigned ARM64 release APK and uploads it with `candidate.json` and
`SHA256SUMS`. It runs on the feature branch and records the source commit and CI
run. Its default build number is the workflow run number; manual dispatch can
supply a positive override. Reserve published version codes so later candidates
stay above the installed version. Pull request jobs build and verify but do not
upload candidates. The workflow has no signing credentials and does not publish
releases or install apps. GitHub manual dispatch requires the workflow file on
the repository's default branch; feature-branch pushes work independently.

The `ORG_GRADLE_PROJECT_divyUnsignedCandidate=true` environment variable enables
unsigned builds only for the `divy` release flavor. Normal `divy` release builds
still require the release signing configuration. The artifact verifier rejects
the wrong package or build number, debuggable builds, other ABIs, valid existing
signatures and v1 signing material. It aligns the APK with 16 KiB native-library
pages before recording the checksum. Local signing must preserve this alignment.

## Local signing of a CI candidate

Download the artifact from the reviewed run. Match its `sourceCommit`, run ID,
run attempt and package/version to that run, then check `SHA256SUMS` before
signing. A checksum from the same artifact detects corruption; the reviewed CI
run and source commit establish where the build came from.

Only Android build-tools 36.0.0 and Java are needed locally. Google's Linux
archive is about 61 MiB; extract it into the dedicated build cache and verify
its checksum against Google's repository metadata. A full Android SDK or NDK
is unnecessary for signing. Keep the signing key and passwords outside the repo
and CI. The owner must keep an encrypted key backup and its public certificate
fingerprint so future preview updates use the same signing identity.

Use `apksigner sign --ks <approved-keystore> --ks-key-alias <approved-alias>
--out <signed-apk> <verified-unsigned-apk>` and enter passwords through the
local prompt. Do not put passwords in command arguments or commit signing
properties. Then run `apksigner verify --verbose --print-certs <signed-apk>` and
`zipalign -c -P 16 -v 4 <signed-apk>`. Compare the certificate fingerprint to
the owner's recorded identity and check package, version, non-debuggable state
and SHA-256 again. Any APK modification after signing invalidates its signature.

The prepare script's tests double the Android tool boundary. CI verification and
successful local signature verification are still required for the actual APK.

## Firebase setup for the preview package

The app gets Firebase configuration from the existing server during the normal
server URL/password setup. Android initializes Firebase with those runtime
options; the manifest removes automatic `FirebaseInitProvider` initialization.
The candidate embeds no `google-services.json` or account credentials. Its
separate package starts with separate preferences and registers its own token
with the same server after setup.

This code path supports the preview flavor, but it does not prove that the
project's API-key restrictions or App Check permit the new package and signing
certificate. Device acceptance must verify Firebase initialization, token
registration and background notification delivery. If registration fails,
inspect the existing project's restrictions with the owner before changing
them. Keep normal account setup and the official installation available.

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
