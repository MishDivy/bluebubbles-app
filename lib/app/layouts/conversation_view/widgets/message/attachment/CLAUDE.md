# attachment/ — Attachment Renderers

Renders all non-text media inside message bubbles. Entry point: `AttachmentHolder`, which dispatches to the appropriate renderer based on MIME type.

## Files

| File | Purpose |
|------|---------|
| `attachment_holder.dart` | **Entry point** — MIME type dispatcher; manages download state |
| `image_viewer.dart` | Images with tap-to-fullscreen gesture |
| `video_player.dart` | Video playback with custom controls |
| `audio_player.dart` | Audio playback with progress bar |
| `contact_card.dart` | Contact / vCard display |
| `sticker_holder.dart` | Independent placement artwork, source details and local-only hiding |
| `inline_sticker_row.dart` | Compact ordered native inline stickers, separate from photo galleries |
| `sticker_asset_image.dart` | Original sticker artwork loader for placements and sticker tapbacks |
| `looping_image.dart` | Native file/memory decoding with continuous playback; source bytes stay unchanged |
| `other_file.dart` | Generic file display for docs, archives, APKs, etc. |
| `live_photo_mixin.dart` | Mixin for handling Live Photo metadata |

## Key Patterns

**Download state**: `AttachmentHolder` holds an `Rx<dynamic> content` that is `null` until downloaded. Observes `AttachmentDownloadController` for progress updates. Auto-download is gated by `AttachmentsSvc.canAutoDownload()`.

**Controller**: Extends `CustomStateful<MessageWidgetController>`. Always set `forceDelete = false` in `initState()` — the message list owns the controller lifecycle.

**Fullscreen**: Tap on `ImageViewer` or `VideoPlayer` pushes `FullscreenMedia` via `NavigationSvc`. See `lib/app/layouts/fullscreen_media/CLAUDE.md`.

## Adding a New Attachment Type

1. Add the MIME type check to `attachment_holder.dart`'s dispatcher.
2. Create `my_type_renderer.dart` in this directory.
3. The renderer receives the `Attachment` object and optionally a download `content` callback.

## Stickers vs Attachments

Stickers (`associatedMessageType == "sticker"`) are **not** routed through `AttachmentHolder`. They are rendered by `StickerObserver` (in `message_holder/`) as overlays positioned above the bubble.
Inline emoji-image runs use `AttachmentHolder` in compact transparent tiles, ordered by their
transfer GUID runs even when every run belongs to part 0. Verified row metadata supplies the
same ordering when attributedBody is absent. Placements do not use tapback actor slots.
Hiding a placement only changes bounded local preferences scoped by server origin, chat and
placement GUID. No native removal is sent. Unverified placement geometry is not applied.

Original-file images use `LoopingFileImage` in `ImageViewer`; overlays use it in
`StickerHolder`. Byte-backed images use `LoopingMemoryImage`. Both providers also
serve `FullscreenImage`. Animations loop without requiring an `isSticker` flag.
They delegate frame decoding, resizing and disposal to Flutter and override
only the animation repeat count. Still-image JPEG previews are unchanged.
Their image-cache keys are distinct from the standard providers, whose finite
animations may already have completed. Static originals still render one frame.
Reply previews keep their existing playback behavior, as does desktop GIF
Reduce Motion (paused until hovered).
