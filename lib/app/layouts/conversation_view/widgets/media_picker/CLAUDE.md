# conversation_view/widgets/media_picker/ — Attachment Picker UI

UI for selecting media files to attach before sending a message.

## Files

| File | Purpose |
|------|---------|
| `text_field_attachment_picker.dart` | Bottom-sheet picker that browses the photo library and recent files; tapping an item adds it to the composer draft |
| `attachment_picker_file.dart` | Renders a single file/photo thumbnail item inside the picker |
| `sticker_browser.dart` | Android folder browser, with a controller and separate grid, thumbnail and selection widgets |
| `sticker_placement_editor.dart` | Approximate in-memory placement preview with center-fraction drag, size and radian rotation controls |
| `sticker_target_preview.dart` | Bounded memory-only snapshot and measured logical size of the selected message part |

## Integration
Opened from the compose bar via the attachment (paperclip / `+`) button in `widgets/text_field/`.
Selected ordinary attachments are stored in `ConversationViewController.pickedAttachments`.
The Android Stickers action opens `StickerBrowser`, whose `StickerBrowserController` owns Rx state.
It uses the persisted SAF read grant through `StickerFolderService`. Sticker sends queue
separately and preserve the conversation's draft and reply. Native Send requires an iMessage
chat and the connected helper's explicit `stickerSending` capability. Folder pages return at
most 60 entries after scanning at most 200 provider rows; thumbnails load only visible tiles.
Selection order defines a native row of 2–10 stickers, gated independently by `stickerRows`.
Rows queue one message with distinct attachment GUIDs, not a series of single sends.
The normal-image override is single-selection only; no selection is silently converted.
Message-part popup actions open the same browser with an immutable `NativeStickerTarget`.
Target mode selects one sticker, offers no photo override, checks target/server freshness and
locks after one queue attempt. Placement requires the exact part snapshot; galleries fail
closed because their boundary contains multiple cards. The original measured width is sent,
not the scaled editor width. Artwork size is explicitly approximate pending native acceptance.

## Related
- Compose bar: `../text_field/CLAUDE.md`
- Conversation view controller: `lib/services/ui/chat/conversation_view_controller.dart`
- Attachment state: `lib/app/state/attachment_state.dart`
