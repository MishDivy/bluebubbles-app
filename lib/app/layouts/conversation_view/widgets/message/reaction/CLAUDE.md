# reaction/ — Tapback Display

Renders the tapback emoji row that appears above or below a message bubble.

## Files

| File | Purpose |
|------|---------|
| `reaction.dart` | `ReactionWidget` — single tapback emoji with skin-specific styling |
| `reaction_holder.dart` | Horizontal row container for all reactions on a message part |
| `reaction_clipper.dart` | `CustomClipper` for the pill-shaped reaction bubble |
| `reaction_icon.dart` | Classic SVG, custom emoji text, or original sticker tapback artwork |

## Data Source

Reactions come from `MessageState.associatedMessages` (an `RxList<Message>`). Filter with `ReactionTypes.isReaction`: classic/custom emoji and `sticker-reaction` (2007) events share one latest slot per actor and message part; `-sticker-reaction` (3007) removes that slot. `sticker` (1000) events remain separate, deduplicated only by GUID, including free placements and observed `sir=true` automatic sticker piles. Do not infer a tapback slot from its position above a bubble.

Use `ReactionTypes` string constants (from `lib/helpers/ui/`) — never hardcode reaction type strings.

## Key Pattern

`ReactionWidget` looks up the reaction by GUID or by `(type, part, isFromMe)` tuple:
- iOS: solid circle, no border
- Material: solid circle with border

The widget observes its reaction's `MessageState` so it re-renders when a temp GUID is swapped for a real one or when error state changes.

## Placement

`ReactionHolder` is placed as a `Positioned` overlay inside the bubble `Stack` in `MessageHolder`. The x/y offset is calculated based on `isFromMe` (left or right alignment) and the bubble size.

## Sending a Tapback

Sending is triggered from `MessagePopup` → calls `MessageInterface.sendTapback(message, reactionType, partIndex)`. The new reaction arrives back through the incoming message flow and updates `MessageState.associatedMessages`.
