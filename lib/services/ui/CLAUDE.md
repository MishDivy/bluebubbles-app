# services/ui/ — UI State Services

All are GetX singletons. Shorthand getters live in `lib/services/services.dart`.

## Chat → `chat/CLAUDE.md`
- `chat/chats_service.dart` (`ChatsSvc`) — sorted chat list, unread count, `ChatState` map, active chat tracking; loads in batches of 100
- `chat/conversation_view_controller.dart` — state for the currently open conversation (text, attachments, reply, scroll position)

## Messages → `message/CLAUDE.md`
- `message/messages_service.dart` (`MessagesSvc`) — per-chat service tagged by GUID; owns `MessageState` map for granular widget reactivity. Per-message controller state now lives directly on `MessageState` (`lib/app/state/message_state.dart`) — the old `MessageWidgetController` was merged into it.

## Contacts
- `contact_service_v2.dart` (`ContactsSvcV2`) — desktop sync (requires server v42+)

## Handles & Typing
- `handle_service.dart` — owns the `HandleState` map, mirrors `handle_state.dart` reactive fields
- `typing_indicator_service.dart` — typing indicator state per chat

## Other
- `theme/themes_service.dart` (`ThemeSvc`) — theme switching, custom theme management, preset themes
- `navigator/navigator_service.dart` (`NavigationSvc`) — GetX-based app routing; always use this over `Navigator.of(context)` directly
- `attachments_service.dart` — tracks attachments and send progress; caches opaque still-image previews. Stickers, alpha and animation use the original file. Deliberate original-file decisions are cached by actual path for the session; decode failures remain retryable. Preview replacement/clear also invalidates these decisions. Preview v2 paths exclude old flattened JPEG caches.
- `sticker_preview_cache.dart` is owned by `AttachmentsService` for native HEIC display only. Its
  private memory cache separates server origin and transfer GUID, with 32 MiB/16 successful entries.
  Two requests run at once; a FIFO caps all active/pending work at 12. Coalesced consumers cancel
  only when the last releases; canceled requests remain counted until they settle. At most 64
  failures expire after five minutes, and explicit Retry clears failed or decoded preview bytes.
  Native HEIC content/export paths ignore converted siblings and keep the original file.
- `unifiedpush.dart` — push notification provider abstraction (UnifiedPush protocol)

## Key Separation Rule
`ChatState` / `MessageState` (in `lib/app/state/`) are what widgets **read**.
`ChatsService` / `MessagesService` call `updateXxxInternal()` on state — **widgets never write state directly**.
