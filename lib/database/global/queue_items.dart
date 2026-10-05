import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';

enum QueueType { sendMessage, sendReaction, sendAttachment, sendMultipart, sendStickerRow, sendTargetedSticker }

abstract class QueueItem {
  QueueType type;
  Completer<void>? completer;

  QueueItem({required this.type, this.completer});
}

abstract class OutgoingQueueItem extends QueueItem {
  Chat chat;
  Message message;

  OutgoingQueueItem({required super.type, super.completer, required this.chat, required this.message});

  /// Whether this item is a user-initiated retry of a previously-failed send.
  /// Retries reuse the message's existing GUID/DB row rather than generating
  /// a new one — see `OutgoingMessageHandler._buildOutgoingMessages`.
  bool get isRetry;

  /// Whether notifications should be cleared for this chat when the message
  /// is added. Not applicable to attachments (always `true`, unused).
  bool get clearNotificationsIfFromMe => true;

  /// The tapback/reaction type for [QueueType.sendReaction] items, `null` otherwise.
  String? get reaction => null;
}

class OutgoingMessage extends OutgoingQueueItem {
  @override
  bool isRetry;
  @override
  bool clearNotificationsIfFromMe;

  OutgoingMessage({
    super.completer,
    required super.chat,
    required super.message,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendMessage);
}

class OutgoingReaction extends OutgoingQueueItem {
  Message selectedMessage;
  @override
  String reaction;
  @override
  bool isRetry;
  @override
  bool clearNotificationsIfFromMe;

  OutgoingReaction({
    super.completer,
    required super.chat,
    required super.message,
    required this.selectedMessage,
    required this.reaction,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendReaction);
}

class OutgoingAttachment extends OutgoingQueueItem {
  Attachment attachment;
  bool get isNativeSticker => attachment.metadata?['nativeStickerSend'] == true;
  bool isAudioMessage;
  @override
  bool isRetry;

  OutgoingAttachment({
    super.completer,
    required super.chat,
    required super.message,
    required this.attachment,
    this.isAudioMessage = false,
    this.isRetry = false,
  }) : super(type: QueueType.sendAttachment);
}

class OutgoingMultipartMessage extends OutgoingQueueItem {
  @override
  bool isRetry;
  @override
  bool clearNotificationsIfFromMe;

  OutgoingMultipartMessage({
    super.completer,
    required super.chat,
    required super.message,
    this.isRetry = false,
    this.clearNotificationsIfFromMe = true,
  }) : super(type: QueueType.sendMultipart);
}

class OutgoingStickerRow extends OutgoingQueueItem {
  final List<Attachment> attachments;
  final String? compositionText;
  final String? serverIdentity;
  @override
  final bool isRetry;

  OutgoingStickerRow({
    super.completer,
    required super.chat,
    required super.message,
    required List<Attachment> attachments,
    this.compositionText,
    this.serverIdentity,
    this.isRetry = false,
  }) : attachments = List.unmodifiable(attachments),
       super(type: QueueType.sendStickerRow) {
    if (compositionText != null) {
      StickerHelper.validateCompositionText(compositionText!, attachments.length);
      if (serverIdentity == null ||
          serverIdentity!.isEmpty ||
          !chat.isIMessage ||
          message.threadOriginatorGuid != null ||
          message.associatedMessageGuid != null ||
          message.expressiveSendStyleId != null ||
          (message.subject?.isNotEmpty ?? false)) {
        throw ArgumentError('A sticker composition requires its original server and an iMessage chat.');
      }
    } else if (attachments.length < 2 || attachments.length > 10) {
      throw ArgumentError('A native sticker row requires 2 to 10 attachments.');
    }
  }

  void ensureAttachmentGuids() {
    final tempGuid = message.guid;
    if (tempGuid == null) throw StateError('A sticker row requires a stable message GUID.');
    if (compositionText != null) message.metadata?.remove('nativeStickerRowSend');
    message.metadata = {
      ...?message.metadata,
      if (compositionText == null) 'nativeStickerRowSend': true,
      if (compositionText != null) 'nativeStickerCompositionSend': true,
      if (compositionText != null) 'nativeStickerCompositionText': compositionText,
      if (compositionText != null) 'nativeStickerCompositionOrigin': serverIdentity,
    };
    if (compositionText != null) message.text = compositionText;
    for (var i = 0; i < attachments.length; i++) {
      attachments[i].guid ??= '$tempGuid-sticker-$i';
      if (compositionText != null) {
        attachments[i].metadata?.remove('nativeStickerRowSend');
        attachments[i].metadata?.remove('stickerRow');
      }
      attachments[i].metadata = {
        ...?attachments[i].metadata,
        if (compositionText == null) 'nativeStickerRowSend': true,
        if (compositionText != null) 'nativeStickerCompositionSend': true,
        'preserveOriginalBytes': true,
        'isSticker': true,
        if (compositionText == null) 'stickerRow': {'index': i, 'count': attachments.length, 'partIndex': 0},
        if (compositionText != null) 'stickerCompositionIndex': i,
      };
    }
    final guids = attachments.map((attachment) => attachment.guid).toSet();
    if (guids.length != attachments.length || guids.contains(tempGuid)) {
      throw StateError('Sticker row attachments require distinct GUIDs separate from the message GUID.');
    }
  }
}

class OutgoingTargetedSticker extends OutgoingQueueItem {
  final NativeStickerTarget target;
  final StickerPlacement? placement;
  final Attachment? attachment;
  @override
  final bool isRetry;
  @override
  String get reaction => switch (target.operation) {
    NativeStickerOperation.placement => 'sticker',
    NativeStickerOperation.tapback => 'sticker-reaction',
    NativeStickerOperation.removeTapback => '-sticker-reaction',
  };

  OutgoingTargetedSticker({required super.chat, required super.message, required this.target,
    this.placement, this.attachment, this.isRetry = false, super.completer}) : super(type: QueueType.sendTargetedSticker) {
    if (chat.guid != target.chatGuid || !chat.isIMessage) throw ArgumentError('The sticker target must belong to this iMessage chat.');
    if ((target.operation == NativeStickerOperation.removeTapback) != (attachment == null) ||
        (target.operation == NativeStickerOperation.placement) != (placement != null)) {
      throw ArgumentError('The sticker operation requires the corresponding asset and placement.');
    }
  }

  void ensureIntent() {
    final tempGuid = message.guid;
    if (tempGuid == null) throw StateError('A targeted sticker requires a stable attempt GUID.');
    message.associatedMessageGuid = target.messageGuid;
    message.associatedMessagePart = target.partIndex;
    message.associatedMessageType = reaction;
    message.hasAttachments = attachment != null;
    message.metadata = {...?message.metadata, 'nativeStickerTargetSend': true, 'nativeStickerTarget': target.toMap(),
      if (placement != null) 'nativeStickerPlacement': placement!.toMap()};
    final asset = attachment;
    if (asset != null) {
      asset.guid = '$tempGuid-sticker';
      asset.metadata = {...?asset.metadata, 'nativeStickerTargetSend': true, 'preserveOriginalBytes': true, 'isSticker': true,
        'nativeStickerTarget': target.toMap()};
    }
  }
}
