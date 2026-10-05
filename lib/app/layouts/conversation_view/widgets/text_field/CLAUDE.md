# widgets/text_field/ — Message Composer

## Files (top-level)
- `conversation_text_field.dart` — composer entry point / orchestration
- `conversation_text_field_local_controller.dart` — local (non-service) text field controller state
- `text_field_component.dart` — main composable text input widget
- `send_button.dart` — send / schedule button
- `text_field_icon_bar.dart` — attachment/emoji/etc. icon row
- `text_field_suffix.dart` — trailing icon(s) inside the field
- `text_field_emoji_picker_section.dart` — inline emoji picker section
- `text_field_recording_overlay.dart` — voice message recording overlay UI
- `voice_message_recorder.dart` — voice message recording logic
- `picked_attachment.dart` / `picked_attachments_holder.dart` — pending attachment chip + holder
- `reply_holder.dart` — selected reply preview above the field
- `sticker_composition_controller.dart` — typed cursor-order sticker draft, restoration and immutable send snapshots
- `draft_sticker_thumbnail.dart` — selected inline artwork, selection and removal controls

## Buttons (`buttons/`)
Action buttons inside and around the input field:
- Attachment picker button
- Emoji picker button
- Audio record button
- Send / schedule button

## Handlers (`handlers/`)
- `clipboard_paste_handler.dart` — image/file paste handling
- `emoji_autocomplete_handler.dart` — `:shortcode:` emoji autocomplete
- `keyboard_shortcut_handler.dart` — composer keyboard shortcuts (desktop)
- `mention_autocomplete_handler.dart` — `@mention` autocomplete
- `text_field_match_helper.dart` — shared text-matching logic for autocomplete handlers

## Helpers (`helpers/`)
Input field utilities: mention detection, text formatting, cursor management.

## Controller
All composer state lives in `ConversationViewController` (`lib/services/ui/chat/conversation_view_controller.dart`):
- Current text content
- Pending attachments list (→ `AttachmentsService`)
- Selected reply message
- Scheduled send time
- Send progress

## Key Interactions
- Attachments added here → tracked by `AttachmentsService`
- Send → `OutgoingMsgHandler` (`OutgoingMessageHandler`)
- Reply selection rendered by `widgets/message/reply/`
- Mention autocomplete → `custom_text_editing_controllers.dart` in `lib/app/components/`

## Sticker drafts

Android folder selections insert one composer-local private-use marker with its typed SAF asset.
The mention controller's U+FFFC delimiter stays separate. Only a validated send snapshot converts
owned markers into the wire U+FFFC positions. Duplicate, unowned or pasted object markers fail closed.
Text and assets save as one origin/chat-scoped preference record; the ordinary chat draft is marker-free.
Invalid records remain untouched until the user chooses `Discard saved sticker draft`.

Exactly one marker with no other text uses the existing standalone native path, including animation.
Text or multiple markers require explicit `stickerComposition`; current preparation accepts static PNG
only. Subject, reply, mentions, effects, schedules, edits and ordinary attachments are rejected visibly
without clearing the draft. One queue attempt has a stable snapshot and server identity. Completion
clears only the same draft revision. An ordinary send cannot clear stickers inserted while it was staging.
The composer observes its controller to increase line height only while inline artwork is present.
Drafts and the multipart wire preserve text/sticker order, but Samsung's mixed message display
still puts text above stickers. This batch does not claim exact chat layout or full parity.
Pure native row rendering and received animated multipart behavior are unchanged.
