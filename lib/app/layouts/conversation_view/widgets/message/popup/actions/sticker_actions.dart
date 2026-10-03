import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/popup/message_popup_action_context.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_asset_image.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';

Message? ownedStickerTapback(MessagePopupActionContext ctx) =>
    getUniqueReactionMessages(ctx.messageState.associatedMessages.toList()).firstWhereOrNull(
      (event) =>
          event.isFromMe == true &&
          (event.associatedMessagePart ?? 0) == ctx.part.part &&
          ReactionTypes.isStickerReaction(event.associatedMessageType) &&
          event.guid?.startsWith('temp') != true &&
          event.error == 0,
    );

bool _isCurrent(MessagePopupActionContext ctx, NativeStickerTarget target) =>
    !ctx.messageState.isClosed &&
    ctx.messageState.guid.value == target.messageGuid &&
    !ctx.messageState.isSending.value &&
    !ctx.messageState.hasError.value &&
    ctx.messageState.message.dateDeleted == null &&
    ctx.messageState.parts.any((part) => part.part == target.partIndex && !part.isUnsent) &&
    ctx.cvController.chat.guid == target.chatGuid;

Future<void> open(MessagePopupActionContext ctx, NativeStickerOperation operation) async {
  final target = NativeStickerTarget(
    serverIdentity: HttpSvc.origin,
    chatGuid: ctx.chat.guid,
    messageGuid: ctx.message.guid!,
    partIndex: ctx.part.part,
    operation: operation,
  );
  final preview = await ctx.captureStickerPreview?.call();
  if (!ctx.context.mounted || !_isCurrent(ctx, target)) return;
  if (operation == NativeStickerOperation.placement && preview == null) {
    ctx.showSnack('Sticker preview unavailable', 'This message part could not be captured. Choose another part.');
    return;
  }
  await Navigator.of(ctx.context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => StickerBrowser(
        chat: ctx.chat,
        target: target,
        targetPreview: preview,
        isTargetCurrent: () => _isCurrent(ctx, target),
      ),
    ),
  );
}

Future<void> removeTapback(MessagePopupActionContext ctx) async {
  final current = ownedStickerTapback(ctx);
  if (current?.guid == null) return;
  final target = NativeStickerTarget(
    serverIdentity: HttpSvc.origin,
    chatGuid: ctx.chat.guid,
    messageGuid: ctx.message.guid!,
    partIndex: ctx.part.part,
    operation: NativeStickerOperation.removeTapback,
    reactionGuid: current!.guid,
  );
  var accepted = false;
  final confirmed = await showDialog<bool>(
    context: ctx.context,
    builder: (context) => AlertDialog(
      title: const Text('Remove your sticker tapback?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (current.dbAttachments.isNotEmpty)
            SizedBox(width: 64, height: 64, child: StickerAssetImage(attachment: current.dbAttachments.first)),
          const Text(
            'This removes your current sticker tapback for everyone. Independent placed stickers stay unchanged.',
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (accepted) return;
            accepted = true;
            Navigator.pop(context, true);
          },
          child: const Text('Remove tapback'),
        ),
      ],
    ),
  );
  if (confirmed != true || !ctx.context.mounted) return;
  if (!_isCurrent(ctx, target) ||
      ownedStickerTapback(ctx)?.guid != target.reactionGuid ||
      HttpSvc.origin != target.serverIdentity) {
    ctx.showSnack('Sticker tapback changed', 'Open the message actions again before removing it.');
    return;
  }
  try {
    await OutgoingMsgHandler.queue(
      OutgoingTargetedSticker(
        chat: ctx.chat,
        target: target,
        message: Message(text: '', dateCreated: DateTime.now(), isFromMe: true, handleId: 0),
      ),
    );
    if (ctx.context.mounted) ctx.popDetails();
  } catch (_) {
    ctx.showSnack('Could not queue sticker removal', 'Check Messages on your Mac before trying again.');
  }
}
