# popup/ — Long-Press Context Menu

Handles the action sheet / context menu shown when the user long-presses (or right-clicks on desktop) a message bubble.

## Files

| File | Purpose |
|------|---------|
| `message_popup_holder.dart` | `GestureDetector` wrapper inside message bubbles; triggers popup presentation |
| `message_popup.dart` | Core popup layout/composition and action availability rules |
| `message_popup_action_context.dart` | Shared typed context passed to extracted action functions |
| `details_menu_action.dart` | Individual menu action row widget |
| `reaction_picker_clipper.dart` | `CustomClipper` for tapback picker shape |
| `actions/media_actions.dart` | Attachment/media actions (save/open/share/copy/redownload) |
| `actions/text_actions.dart` | Text/link actions (copy text, copy selection, open link) |
| `actions/navigation_actions.dart` | Navigation actions (reply/thread/DM/forward/new conversation) |
| `actions/message_actions.dart` | Message lifecycle actions (edit/unsend/delete/bookmark/remind/info/etc.) |
| `actions/sticker_actions.dart` | Target-aware placement/tapback browser entrypoints and own-current-2007 removal confirmation |
| `widgets/reaction_details.dart` | Reactions preview widget rendered at top of popup |
| `widgets/custom_reaction_picker.dart` | Emoji picker and removal control; available only when the server explicitly advertises connected-helper support |

## MessagePopupActionContext Contract

`MessagePopupActionContext` carries the data/dependencies needed by reusable action handlers:
- UI context: `context`, `widthContext`, `popDetails`, `showSnack`
- Message scope: `messageState`, `message`, `part`, `chat`, `service`
- Controller scope: `cvController`
- Capability flags: `serverDetails`, `isEmbeddedMedia`
- Related entities: `dmChat`
- Action metadata: `action`
- Optional memory-only selected-part capture: `captureStickerPreview`

## How It Works

1. `MessagePopupHolder` triggers `showMessagePopup(...)` from a message bubble.
2. `MessagePopup` computes action availability and ordering in `_allActions`.
3. Each menu action callback builds a `MessagePopupActionContext` and dispatches into `actions/*.dart`.
4. Action functions own behavior; `message_popup.dart` owns visibility conditions and layout.

Android sticker placement captures the selected part's own repaint boundary, excluding outer
reaction/sticker overlays. A gallery is not treated as one measured native part. Snapshots stay
in memory, are capped at four million pixels/four MiB, and are disposed after encoding.
Target actions retain real part indices and do not modify the compose draft or reply selection.
Removal requires the latest own type-2007 event GUID; type-1000 placements cannot use that endpoint.

## Adding a New Popup Action

1. Add/confirm enum + icon entry in `details_menu_action.dart`.
2. Add a reusable function in the appropriate `actions/*.dart` file (or add a new category file if needed).
3. Wire the callback in `message_popup.dart` using `_buildActionContext(...)`.
4. Add action visibility condition in `_allActions` and ensure ordering via `SettingsSvc.settings.detailsMenuActions`.
5. Verify desktop and mobile behavior (availability + navigation/pop semantics).

## Desktop Behavior

On desktop, right-click opens this popup (instead of long-press). `MessagePopupHolder` handles gesture differences for desktop vs mobile.
