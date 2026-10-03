import 'package:bluebubbles/database/models.dart';
import 'package:collection/collection.dart';

class StickerHelper {
  static bool requiresNativePreview(Attachment attachment) =>
      (attachment.mimeType?.toLowerCase().contains('image/hei') == true ||
       RegExp(r'\.(heic|heif|heics)$', caseSensitive: false).hasMatch(attachment.transferName ?? '')) &&
      (attachment.metadata?['isSticker'] == true || attachment.metadata?['sticker'] is Map ||
       attachment.message.target?.isSticker == true);
  static bool isUnconfirmedTargetedEvent(Message message) => message.metadata?['nativeStickerTargetSend'] == true &&
      (message.guid?.startsWith('temp') == true || message.guid?.startsWith('error') == true || message.error != 0);

  static bool shouldVerifyTargetedEcho(Message existing, {String? tempGuid, required bool hasAttachments}) =>
      existing.metadata?['nativeStickerTargetSend'] == true &&
      (existing.guid?.startsWith('temp') == true || tempGuid != null || hasAttachments);

  /// Check the target before a socket echo can release the one-shot attempt.
  static Map<String, String> targetedReplacementGuids(Message existing, Message replacement,
      List<Attachment> attachments) {
    final raw = existing.metadata?['nativeStickerTarget'];
    if (raw is! Map) throw StateError('Missing native sticker target.');
    final target = NativeStickerTarget.fromMap(raw);
    final expectedType = switch (target.operation) {
      NativeStickerOperation.placement => 'sticker',
      NativeStickerOperation.tapback => 'sticker-reaction',
      NativeStickerOperation.removeTapback => '-sticker-reaction',
    };
    if (replacement.guid == null || replacement.guid!.startsWith('temp') || replacement.guid!.startsWith('error') ||
        replacement.isFromMe != true || replacement.associatedMessageGuid != target.messageGuid || replacement.associatedMessagePart != target.partIndex ||
        replacement.associatedMessageType != expectedType ||
        (target.operation == NativeStickerOperation.removeTapback && replacement.guid == target.reactionGuid)) {
      throw StateError('Sticker confirmation does not match its target.');
    }
    // A removal may retain a link to the previous artwork, but adds no asset.
    if (target.operation == NativeStickerOperation.removeTapback) return {};
    final local = existing.dbAttachments.toList();
    if (local.length != 1 || local.single.guid == null || attachments.length != 1 || attachments.single.guid == null ||
        attachments.single.guid!.startsWith('temp') || attachments.single.guid!.startsWith('error')) {
      throw StateError('Sticker confirmation must contain one native asset.');
    }
    return {attachments.single.guid!: local.single.guid!};
  }

  static List<MessagePart> attributedParts(AttributedBody body, List<Attachment> attachments, {String? subject}) {
    final parts = <MessagePart>[];
    final runs =
        body.runs
            .where(
              (run) =>
                  run.range.length == 2 &&
                  run.range[0] >= 0 &&
                  run.range[1] >= 0 &&
                  run.range[0] + run.range[1] <= body.string.length,
            )
            .toList()
          ..sort((a, b) => a.range[0].compareTo(b.range[0]));
    for (final run in runs) {
      final index = run.attributes?.messagePart;
      if (index == null) continue;
      var part = parts.firstWhereOrNull((part) => part.part == index);
      if (part == null) {
        part = MessagePart(part: index, subject: parts.isEmpty ? subject : null);
        parts.add(part);
      }
      if (run.isAttachment) {
        final attachment = attachments.firstWhereOrNull((asset) => asset.guid == run.attributes!.attachmentGuid);
        if (attachment != null && !part.attachments.any((asset) => asset.guid == attachment.guid)) {
          part.attachments.add(attachment);
          if (run.attributes!.emojiImage) {
            part.isInlineSticker = true;
          }
        }
        continue;
      }
      final text = body.string.substring(run.range[0], run.range[0] + run.range[1]).replaceAll('\uFFFC', '');
      if (text.isEmpty) continue;
      final offset = part.text?.length ?? 0;
      part.text = (part.text ?? '') + text;
      if (run.hasMention) {
        part.mentions.add(Mention(mentionedAddress: run.attributes?.mention, range: [offset, offset + text.length]));
      }
    }
    return parts;
  }

  static List<Attachment>? rowAttachments(List<Attachment> attachments) {
    if (attachments.isEmpty) return null;
    Map? row(Attachment attachment) {
      final sticker = attachment.metadata?['sticker'];
      final value = attachment.metadata?['stickerRow'] ?? (sticker is Map ? sticker['row'] : null);
      return value is Map ? value : null;
    }

    final ordered = List<Attachment>.of(attachments);
    if (ordered.any(
      (attachment) =>
          row(attachment)?['partIndex'] != 0 ||
          row(attachment)?['count'] != ordered.length ||
          row(attachment)?['index'] is! int,
    )) {
      return null;
    }
    ordered.sort((a, b) => (row(a)!['index'] as int).compareTo(row(b)!['index'] as int));
    for (var i = 0; i < ordered.length; i++) {
      if (row(ordered[i])!['index'] != i) {
        return null;
      }
    }
    return ordered;
  }

  static List<Attachment> confirmedRowAttachments(Map data, int expectedCount) {
    final layout = data['stickerLayout'];
    final rawGuids = layout is Map ? layout['attachmentGuids'] : null;
    final rawAttachments = data['attachments'];
    if (layout is! Map ||
        layout['partIndex'] != 0 ||
        rawGuids is! List ||
        rawAttachments is! List ||
        rawGuids.length != expectedCount ||
        rawAttachments.length != expectedCount ||
        rawGuids.any((guid) => guid is! String || guid.isEmpty) ||
        rawGuids.toSet().length != expectedCount ||
        rawAttachments.any((attachment) => attachment is! Map)) {
      throw StateError('Sticker row confirmation is incomplete. Check Messages before sending again.');
    }
    final attachments = rawAttachments
        .map((entry) => Attachment.fromMap((entry as Map).cast<String, dynamic>()))
        .toList();
    final ordered = <Attachment>[];
    for (var i = 0; i < rawGuids.length; i++) {
      final matches = attachments.where((attachment) => attachment.guid == rawGuids[i]).toList();
      if (matches.length != 1) throw StateError('Sticker row confirmation has mismatched transfer GUIDs.');
      final attachment = matches.single;
      attachment.metadata = {
        ...?attachment.metadata,
        'isSticker': true,
        'stickerRow': {'index': i, 'count': expectedCount, 'partIndex': 0},
      };
      ordered.add(attachment);
    }
    return ordered;
  }

  static Map<String, String> rowReplacementGuids(List<Attachment> existing, List<Attachment> incoming) {
    final before = rowAttachments(existing);
    final after = rowAttachments(incoming);
    if (before == null ||
        after == null ||
        before.length != after.length ||
        before.any((attachment) => attachment.guid == null) ||
        after.any((attachment) => attachment.guid == null) ||
        before.map((attachment) => attachment.guid).toSet().length != before.length ||
        after.map((attachment) => attachment.guid).toSet().length != after.length) {
      throw StateError('Sticker row echo does not confirm exactly the queued assets.');
    }
    return {for (var i = 0; i < before.length; i++) after[i].guid!: before[i].guid!};
  }
}
