# android/ — Android Native (Kotlin)

Source: `app/src/main/kotlin/com/bluebubbles/messaging/`

## Key Modules
| Directory | Purpose |
|-----------|---------|
| `services/foreground/` | Foreground service to keep socket alive |
| `services/firebase/` | FCM push notifications and Firebase auth |
| `services/notifications/` | Notification channels, message/FaceTime builders |
| `services/intents/` | Intent receivers (deep links, auto-start) |
| `services/system/` | Calendar, contacts, browser, Chrome OS integrations |
| `services/network/` | Native HTTP service |
| `services/backend_ui_interop/` | DartWorkManager / DartWorker for background Dart |
| `services/filesystem/` | File path resolution |

## Dart ↔ Android Bridge
Flutter side: `lib/services/backend/java_dart_interop/`
- `method_channel_service.dart` — channel setup
- `intents_service.dart` — Android intent handling
- `background_isolate.dart` — background Dart execution

`services/filesystem/StickerFolderAccess.kt` handles the separate
`com.bluebubbles.messaging/sticker-folder` channel through `MainActivity` and `BubbleActivity`.
It persists only a SAF read grant, validates descendant document URIs, lists bounded pages,
and checks the 500 KiB / 618 × 618 limits before reading thumbnails or staging one original.
Cancelled folder selection keeps the previous grant. Revoked grants require choosing again.
Selected staging files live in an owned cache directory and are removed after outgoing preparation;
stale owned files older than a day are cleaned with lazy iteration and at most 100 deletions.
Thumbnail jobs use a bounded executor separate from folder/staging work. Disposed visible tiles
cancel their read requests; activity teardown cancels all pending requests and removes the channel.

## Build Config
- Target SDK: 35 | NDK: 27.0 | Java/Kotlin compat: version 21
- Gradle with Kotlin plugin

## Personal preview flavor

`divy` uses `com.bluebubbles.messaging.divy` and a separate file-provider authority.
Release builds require the release signing configuration unless the caller sets
the divy-only `divyUnsignedCandidate=true` Gradle property. CI uploads an unsigned
release candidate for local signing. See `docs/preview-releases.md` for versioning, signing,
update-source isolation and migration back to the official app. Keep these
personal packaging changes out of upstream reaction patches.
