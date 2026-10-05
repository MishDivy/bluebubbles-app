# services/backend/ — Server Interaction

## Request Pattern
Each resource has an interface and a concrete action file → `interfaces/CLAUDE.md` + `actions/CLAUDE.md`
- `interfaces/chat_interface.dart` → `actions/chat_actions.dart`
- `interfaces/message_interface.dart` → `actions/message_actions.dart`
- (same for: app, attachment, contact_v2, handle, image, log, prefs, send_message, server, sync, test)

## Sync System (`sync/`) → `sync/CLAUDE.md`
- `sync_service.dart` — coordinator
- `full_sync_manager.dart` — initial full data sync
- `incremental_sync_manager.dart` — delta updates
- `handle_sync_manager.dart` — contact handle sync

## Outgoing Message Handler
- `outgoing_message_handler.dart` — `OutgoingMessageHandler` / `OutgoingMsgHandler` GetIt getter
- Owns the complete outbound send pipeline: serial queue, `_buildOutgoingMessages` / `_persistOutgoingMessages` / `prepAttachment`, HTTP + socket race via `_sendWithRace()`, send-progress trackers, GUID swap (`_matchMessageWithExisting()`), and error marking
- Existing attachment metadata preserves native sticker intent and original bytes through queue and isolate sends. Marked native stickers use a dedicated endpoint and reject generic retry because an unsuccessful response can have an unknown delivery outcome.
- Native rows prepare all selected originals, persist once, and send one multipart request. HTTP and socket confirmation reconcile exact indexed attachment GUID pairs; no filename or database-order matching is used for rows.
- Composer sends use the same row queue with optional immutable text and server identity. One reserved
  U+FFFC marker corresponds to each ordered asset. HTTP must confirm the entire attributed body,
  transfer order, ranges and actual native part indexes against its verified composition hint.
  Pending socket echoes cannot settle these attempts; confirmed echoes must retain the known asset
  identities, and reduced receipts retain the verified body. Composition attempts never retry.
  Failed preparation throws to the composer before dispatch so it can retain the draft.
- `OutgoingTargetedSticker` shares this queue and preparation path. Placement, add/replace tapback,
  and removal retain immutable target intent in existing metadata and require matching native
  event type, parent GUID and real part before releasing progress. Uploads reconcile one distinct
  asset GUID; removal may link old artwork but creates no asset. These operations never autoretry.

## Incoming Message Handler
- `incoming_message_handler.dart` — `IncomingMessageHandler` / `IncomingMsgHandler` GetIt getter
- Owns the inbound message pipeline: FIFO queue, configurable concurrency, per-GUID serialization, deduplication, chat hydration, DB write, notification dispatch, and UI reactivity

## Other Key Files
- `settings/` — `SettingsService` + `SharedPreferencesService` → `settings/CLAUDE.md`
- `notifications/notifications_service.dart` — local notification dispatch
- `java_dart_interop/` — Android method channel bridge → `java_dart_interop/CLAUDE.md`
- `lifecycle/` — foreground/background lifecycle → `lifecycle/CLAUDE.md`
- `filesystem/` — file I/O, attachment path resolution → `filesystem/CLAUDE.md`
- `setup/` — first-run server connection orchestration → `setup/CLAUDE.md`
- `web/listeners.dart` — web-platform socket listeners (exported from `services.dart`)
- `descriptors/attachment_query_descriptor.dart` — typed query descriptor for attachment lookups
