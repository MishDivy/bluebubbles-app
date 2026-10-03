# conversation_view/widgets/media_picker/ — Attachment Picker UI

UI for selecting media files to attach before sending a message.

## Files

| File | Purpose |
|------|---------|
| `text_field_attachment_picker.dart` | Bottom-sheet picker that browses the photo library and recent files; tapping an item adds it to the composer draft |
| `attachment_picker_file.dart` | Renders a single file/photo thumbnail item inside the picker |
| `sticker_browser.dart` | Android folder browser, with a controller and separate grid, thumbnail and selection widgets |

## Integration
Opened from the compose bar via the attachment (paperclip / `+`) button in `widgets/text_field/`.
Selected ordinary attachments are stored in `ConversationViewController.pickedAttachments`.
The Android Stickers action opens `StickerBrowser`, whose `StickerBrowserController` owns Rx state.
It uses the persisted SAF read grant through `StickerFolderService`. Sticker sends queue
separately and preserve the conversation's draft and reply. Native Send requires an iMessage
chat and the connected helper's explicit `stickerSending` capability. Folder pages return at
most 60 entries after scanning at most 200 provider rows; thumbnails load only visible tiles.

## Related
- Compose bar: `../text_field/CLAUDE.md`
- Conversation view controller: `lib/services/ui/chat/conversation_view_controller.dart`
- Attachment state: `lib/app/state/attachment_state.dart`
