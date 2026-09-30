# Custom emoji reactions

Incoming server messages use `associatedMessageType: emoji` / `-emoji` (or
numeric `2006` / `3006`) and `associatedMessageEmoji` containing the complete
Unicode grapheme. `Message.fromMap` normalizes that identity into the existing
`associatedMessageType` column, as a raw emoji / prefixed removal. ObjectBox
schema, cached maps, isolates and MessageState therefore preserve it without a
new field or migration. Classic names and numeric tapbacks still work. Unknown
numeric events remain unknown, with a generic notification verb; they never
become filenames for SVG assets.

The shared validator preserves variation selectors, skin tones, ZWJ sequences,
flags and keycaps. It requires one grapheme and bounds it to 128 UTF-16 units.
Known emoji bases and the supplementary pictograph range support newer incoming
emoji before the picker catalog catches up. This is structural validation, not
a guarantee that the device's font contains every new glyph. Missing/malformed
emoji payloads retain an `emoji` sentinel and show a generic reaction instead of
printing `null`. A partial duplicate gives way to its hydrated emoji.

The reaction row selects the newest event per actor, parent GUID and message
part; a removal hides that actor's preceding event. Equal timestamps prefer the
larger source row ID, when available. Unknown actors remain separate. The live
MessageState path reconciles outgoing temporary GUIDs and server echoes using
the same normalized identity. Previews, notification text and the notify-reactions
preference support custom emoji and removals. Reaction statistics still count
only the classic six types.

Sending uses the existing `/message/react` field: `reaction: 🫡`, or `-🫡` to
remove that same emoji. The popup adds a picker only when `/server/info` explicitly
advertises `privateApiCapabilities.customEmojiReactions: true`. Absence, false,
or a newer version number alone does not enable it. Sends happen in the background
isolate, so the HTTP path checks current server info again before each custom
POST. This also detects a helper downgrade after opening the picker. Classic
sends need no new capability or extra request. Selecting a different emoji
replaces the actor's reaction; selecting the current one or the removal control
removes it. Failed sends use the existing queued reaction error/retry UI.

The raw identity convention and picker concept follow ZachGarcia42's
[upstream app PR #3162](https://github.com/BlueBubblesApp/bluebubbles-app/pull/3162),
adapted to this app's current state/service architecture and explicit helper
capability negotiation. The prior reverted implementation's assumption that the
server already supplied emoji in the type field is not required.

## Stickers and verification limits

Existing `1000`/`sticker` placement remains distinct from custom sticker tapback
types `2007`/`3007`; those numeric types need a native metadata fixture before
rendering or sending is enabled. Attachment `isSticker` is retained in its
existing metadata JSON. Explicit HEIC stickers convert to PNG to retain alpha;
ordinary HEIC photos retain the existing JPEG conversion. StickerHolder displays
the compatible path, including downloaded and cached conversions. This does not
implement custom sticker tapback sending, placement/effect parsing or animation.

Run `flutter test --no-pub test/custom_reactions_test.dart` and
`flutter analyze --no-pub --no-fatal-infos` with pinned Flutter 3.44.6 / Dart 3.12.2.
CI runs these checks for the feature branch. Tests exercise production Message
map ingestion, cached map roundtrips, live MessageState reconciliation,
notification formatting/muting, rendering widgets and the HTTP request path;
database lookup and HTTP responses are doubled locally. They do not prove native
ObjectBox reopen, Android background delivery, Messages helper acceptance, or
HEIC decoder alpha fidelity. Those need a paired server/helper build and device
acceptance: incoming live/history/restart, add/change/remove by multiple actors
on multiple parts, notification previews/muting, all three skins, helper
disconnect/reconnect, and transparent/animated sticker fixtures. No app/server
installation or real message transmission is performed by these tests.
