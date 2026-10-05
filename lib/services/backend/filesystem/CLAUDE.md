# services/backend/filesystem/ — File System Service

## File
`filesystem_service.dart` — `FilesystemService` (registered with GetIt via `FileSystemSvc` shorthand)

`sticker_folder_service.dart` is a stateless Android SAF channel facade. It lists bounded pages,
reads visible sticker thumbnails, and stages only the explicitly selected original file before
queuing its attachment. Native intent and original-byte preservation live in existing attachment
and message metadata. Rows stage only their 2–10 selections and queue one typed message.
Staged originals are removed after outgoing preparation, including partial staging errors.
Folder access belongs to the native persisted read grant, not a filesystem path.
Composer snapshots stage their ordered assets before one queue operation, checking origin/chat
freshness before and after staging. Exact one-marker drafts use standalone native intent with
the captured server identity. Mixed drafts and current row preparation require static PNG;
the bounded chunk walk rejects animation chunks without decoding or altering source bytes.

## Responsibilities
- Resolves platform-specific paths for attachments, cache, and temp files
- Manages attachment download destinations (per-GUID subdirectories)
- Cleans up orphaned/cached files when attachments are deleted
- Copies, moves, and deletes files as part of the attachment pipeline

## Key Methods
- `getAttachmentPath(Attachment)` → resolved local file path
- `saveAttachment(Attachment, Uint8List)` → writes bytes to the correct path
- `deleteAttachment(Attachment)` → removes the local file
- `getTempPath()` → temp directory for in-progress downloads / conversions

## Platform Paths
- **Android/iOS**: `getApplicationDocumentsDirectory()` / `getExternalStorageDirectory()`
- **Desktop**: user-configured download path from `Settings.attachmentsPath`
- Guard with `if (kIsWeb) return;` — no filesystem on web

## Related
- Attachment actions: `lib/services/backend/actions/attachment_actions.dart`
- Download manager: `lib/services/network/downloads_service.dart`
