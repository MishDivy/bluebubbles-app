# Native stickers: feature branch and acceptance plan

Work lives on `feature/native-stickers` in the app, server and helper forks.
This is not a production release. The app branch includes the tested build 12
transparency and animation-loop fixes from `fix/sticker-previews`. Fork `main`
and upstream `master` stay unchanged until the owner accepts a paired build.

## Scope

The goal is native sticker behavior, not an image made smaller to resemble a
sticker. Start with an original asset from a folder the user selects on Android.
Preserve its bytes, alpha and animation, then use a native Messages file transfer
with sticker metadata. Do not flatten several stickers into a collage or silently
send a photo when the native path is unavailable.

Implementation is progressing through standalone stickers, one-message rows,
placement and sticker tapbacks. A passing build does not complete the feature.
The acceptance table below tracks the remaining device checks. Experimental
capabilities stay separate from the production helper and from delivery evidence.

| Behavior | Evidence required before enabling or merging |
| --- | --- |
| Folder browser with separate pack subfolders | Samsung folder grant, restart, revoked grant, cancellation and large-folder tests |
| Static transparent standalone sticker | Native outgoing transfer, database `is_sticker`, and iPad rendering agree |
| Animated standalone sticker | Original bytes remain animated and transparent on both clients, including finite-loop APNG |
| Multiple stickers in a horizontal row | Observe an iPad-created row's message/attachment structure; reproduce separate sticker identities and order without a flattened image |
| Sticker placed on an existing message | Verify target GUID, part, coordinates, scale and rotation against an iPad fixture; never substitute a threaded reply |
| Multiple placements by the same sender | Both remain visible; placement is not a sender's single tapback slot |
| Sticker tapback add, replace and remove | Verify native constructor, asset association and `2007`/`3007` events; do not reuse Unicode-emoji sending |
| Placement deletion | Observe the actual deletion event; `3007` does not establish how a `1000` placement is removed |
| Source pack, accessibility label and effects | Preserve fields supported by real source metadata; do not invent an App Store pack identity or discard effect-bearing originals |
| Live, history and reconnect rendering | Same target, size, position, assets and removal state after leaving the chat and restarting each client |
| Notifications and previews | Useful text or a safe placeholder; no `null`, private payload logging or broken asset lookup |

iOS controls the recipient's layout. Even a correctly encoded row can wrap on a
smaller screen. The acceptance criterion is native composition and sticker
identity, not identical pixel spacing on every device.

## Candidate contract

The companion server adds a dedicated authenticated multipart endpoint,
`POST /api/v1/message/send-sticker`. It is separate from ordinary attachment
sending so a failed native request cannot fall back to a photo or threaded reply.

Fields: `attachment`, `chatGuid`, `tempGuid`, `name`, and optional `stickerLabel`.
Only one standalone sticker is supported by this contract. Placement, rows,
audio, message effects and reaction fields are not accepted.

Rows use `POST /api/v1/message/send-sticker-row` with `chatGuid`, one `tempGuid`,
an ordered JSON `stickers` array of `{name, stickerLabel?}`, and indexed multipart
files `attachment0` through `attachmentN-1`. A row contains 2 to 10 original
assets, each within the single-sticker limit, and at most 5 MiB overall. It is
one queued message and one native send, not a sequence of separate messages.
The helper returns the exact message GUID and ordered attachment GUIDs. The
server verifies their linkage; Android reconciles each distinct local asset.

Targeted actions use `send-sticker-placement`, `send-sticker-tapback`, or
`remove-sticker-tapback` beneath the same message API. Each carries the exact
chat, message GUID, part index and one attempt GUID. Placement also carries
finite `x`, `y`, `scale`, `rotation` and `parentWidth` values. Tapback removal
requires the current confirmed own reaction GUID and accepts no uploaded asset.
The helper rechecks the native target and removal ownership before dispatch.

Android captures only the selected message part in memory for the placement
editor. A gallery containing several parts cannot supply a placement preview.
The editor's position, scale and rotation controls are approximate until paired
device tests establish native sizing. Changing the server, deleting the target,
closing the browser during staging, or losing the operation capability prevents
the queued action from using a stale target. Unconfirmed tapbacks do not replace
the existing visible reaction slot.

The server forwards `send-sticker` with `chatGuid`, a server-owned staged
`filePath`, optional `filename` and optional `stickerLabel`. The helper returns
the constructed message's own `identifier`, not a chat-wide last-message value.
The server must confirm the corresponding outgoing sticker row in the requested
chat. This confirms a local send, not recipient delivery.

`privateApiCapabilities.stickerSending` must be explicitly true for a live
Messages helper before native sending is offered. Version strings are not
capabilities. Missing, stale or disconnected helpers disable sending. The helper
requires an experimental build opt-in and matching runtime method signatures.
Each additional operation has its own capability. Experimental row builds now
advertise `stickerRows` when their native signatures match. Placement and tapback
builds likewise require `stickerPlacement` and `stickerReactions`. They must pass
their own guards and tests; the production helper still has none
of these sticker-sending capabilities enabled.

Uploads are bounded to 500 KiB, PNG/APNG, GIF or JPEG, at most 618 pixels on either
axis, 100 frames and 25 million aggregate decoded pixels. These are conservative
candidate limits, not a claim that every Apple sticker API has identical limits.
The helper validates and decodes the original bytes before dispatch. Filename
extensions and Android MIME hints alone are not sufficient validation.

Any ambiguous dispatch result needs inspection before another send. An HTTP
timeout or proxy error does not establish that nothing was sent. Do not retry
automatically or change the send intent to an ordinary attachment.

## Received HEIC previews

The candidate server has an authenticated, GUID-only
`GET /api/v1/attachment/:guid/sticker-preview` endpoint. A separately packaged
public ImageIO executable derives PNG or timed APNG artwork in a private bounded
cache. It checks decoded pixels, alpha, dimensions and animation timing before
publishing a preview. Original attachment downloads remain byte-preserving.

Unknown effects, untimed multi-image files and unsupported auxiliary planes
return an explicit unavailable result. The narrow static HEIC raster exception
and its limits are documented in the server's
`packages/server/native/sticker-preview/README.md`. A derived raster does not
establish fidelity for an unknown effect. Android integration and paired-device
acceptance remain separate gates.

The Mac artifact workflow defaults to the stable helper. Its explicit
`native_stickers` input selects the pinned experimental helper and includes the
converter hash in the manifest. Building an artifact does not install it, change
the current startup owner, or enable an experimental helper in production.

## Android folder access

Use Android's Storage Access Framework to select a directory and retain only its
read grant. Browse subfolders on demand. Do not scan the whole phone, request
all-files access, or copy the entire collection into app storage. A provider URI
does not have to be a filesystem path; do not infer sticker intent from a guessed
path or a matching filename in the generic photo picker.

Choosing an asset selects it for an explicit send. It must not send immediately,
erase an unrelated text draft, or grant write access to the source folder.
Cancellation, moved files and revoked grants must leave the source unchanged.
Temporary copies should contain only selected assets and have bounded lifetimes.

## Controlled device fixtures

The owner can create these later in an iPad self-chat. No friend needs to be
contacted. Creating fixtures is a separate, user-approved testing session; an
implementation task does not authorize reading arbitrary chats or sending test
messages to existing participants.

1. Send one static transparent sticker and one animated sticker normally.
2. Send two or three stickers in the same row as iOS supports it.
3. Place two stickers on one message; resize or rotate one. Repeat on a nonzero
   part of a multipart message, then delete one placement.
4. Add, replace and remove a sticker tapback.
5. If available, send one effect-bearing sticker and one source-pack sticker.

Record only these chosen message and attachment rows, before and after each
operation. Relevant fields include row GUIDs, sender identity, association type,
target GUID and part, attachment GUIDs, MIME/UTI, original hashes and dimensions,
`sticker_user_info` and `attribution_info`. A screenshot helps compare layout but
cannot replace the original attachment and association metadata.

Keep private fixtures and paid-pack artwork outside Git and CI in protected local
storage. Do not copy the Messages database or log whole socket payloads. Turn any
needed regression fixture into synthetic data, removing addresses, chat content,
host paths, tokens and identifying pack artwork. Inspection never writes to the
Messages database.

The owner has supplied standalone, three-sticker-row and placement fixtures.
Read-only inspection confirmed that the row is one message with three distinct
attachments, each at part 0 with the emoji-image attribute. Multiple placements
use independent type-1000 messages. Removing placements on the iPad did not
establish a remote deletion event. Android therefore treats hiding a placement
as device-local and keeps that action separate from removing a sticker tapback.

A sticker selected through the iPad reaction picker also arrived as type `1000`,
with `sir=true` in its sticker metadata. It is an independent reaction-layout
sticker, not proof of a type-2007 tapback. After the owner removed one self-chat
copy through Sticker Details, the Mac still had both copies and no new related
removal event. Preserve type-1000 messages by their own GUIDs even when they have
the reaction flag. Never use the type-3007 endpoint to remove them.

An isolated synthetic `IMStickerTapback` constructor probe separately returned
native types `2007` and `3007` for add and remove descriptors. Both representations
therefore exist on the tested Mac. Device acceptance must distinguish their
layout, replacement, and removal behavior rather than treating them as aliases.

After the owner's restart on 2026-10-03, the Mac reported macOS 27.0.1 (26A434)
and the existing production service passed its authenticated readiness check.
Isolated native probes confirmed sticker-tapback signatures, the association-aware
message constructor, and geometry field/key names. Synthetic layout calculations
confirmed centered fractional positioning and radian rotation for layout intents
0. Native scale, orientation and recipient rendering still need acceptance.
Fixture metadata can use either numeric strings (position version 0) or numbers
(version 1); receive code must preserve both without inventing absent values.
`pid` denotes a pack identifier; `sbid` and attribution's `bundle-id` identify the
source bundle. Do not describe the pack identifier as an App Store bundle ID.

## Review and release gates

- Offline tests cover validation, folder boundaries, explicit capability checks,
  request intent, duplicates and uncertain outcomes. They do not prove native
  Messages behavior.
- Compile and run the helper's synthetic tests on macOS without injecting it or
  restarting Messages. Use the safe build scripts, not inherited install phases.
- Before a device test, record the three source revisions and artifact hashes,
  keep the existing signing identity, and prepare rollback through the existing
  `divy-mac-utils` lifecycle tooling. Do not start a second production server.
- Test during an agreed interruption window. Verify plain text, edit, invite and
  classic/custom emoji reactions still work along with the accepted sticker
  behaviors. Use self-chat unless the owner explicitly chooses another chat.
- Keep the feature branches separate while the parity table has unimplemented
  rows. Partial deployment or a narrower merge requires an explicit scope
  decision; do not call the single-sticker candidate full parity.

For a macOS upgrade, first repeat the method-signature probe and synthetic build
tests, then the controlled native fixture tests. Missing or changed selectors
disable only the affected capability. Do not bypass security settings, add a
daemon, or merge the unrelated upstream helper rewrite as an upgrade shortcut.

## Primary references

- [Android folder access and persisted URI grants](https://developer.android.com/training/data-storage/shared/documents-files).
- [Apple MSSticker](https://developer.apple.com/documentation/messages/mssticker).
- [imsg native sticker implementation, pinned revision](https://github.com/openclaw/imsg/tree/640f58f4f80220b10082eafe4d725049fe2acb77/Sources/IMsgHelper).
  Its standalone/placed sticker implementation informs the native candidate;
  it does not prove sticker tapback support or compatibility with this Mac.
- Companion helper `docs/custom-reactions.md` records the macOS 27 probe and
  distinguishes placement `1000` from sticker tapback `2007`/`3007`.
- [imbridge's pinned sticker tapback patch](https://github.com/christianblandford/imbridge/blob/df8c9601b05f2fc2daef070a07f4f883cee350ba/helper/patches/0010-sticker-tapbacks.patch)
  identifies the native tapback constructor and sender. Adaptations retain its
  Apache license and notice. Its chat-wide last-message fallback is not used.
