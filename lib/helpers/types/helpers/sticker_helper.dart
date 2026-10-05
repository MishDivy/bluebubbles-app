import 'package:bluebubbles/database/models.dart';
import 'package:collection/collection.dart';

class StickerHelper {
  static void validateCompositionText(String text, int count) {
    if (count < 1 || count > 10 || text.length > 4096 || '\uFFFC'.allMatches(text).length != count) {
      throw ArgumentError('The sticker draft must contain one marker per sticker and fit within the text limit.');
    }
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (++i >= text.length || text.codeUnitAt(i) < 0xDC00 || text.codeUnitAt(i) > 0xDFFF) {
          throw ArgumentError('The sticker draft contains incomplete Unicode.');
        }
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        throw ArgumentError('The sticker draft contains incomplete Unicode.');
      }
    }
  }

  static bool _nativeGuid(Object? guid) =>
      guid is String && guid.isNotEmpty && !guid.startsWith('temp') && !guid.startsWith('error');

  static bool awaitsCompositionHttp(Message message) => message.metadata?['nativeStickerCompositionSend'] == true &&
      (message.guid?.startsWith('temp') == true || message.guid?.startsWith('error') == true);

  static void retainCompositionReceiptBody(Message existing, Message receipt) {
    receipt.attributedBody = List.of(existing.attributedBody);
    receipt.text = existing.text;
  }

  static List<({String guid, int offset, int partIndex})> _compositionTransfers(
    Object? bodies,
    String text,
    int count,
  ) {
    validateCompositionText(text, count);
    if (bodies is! List || bodies.length != 1 || bodies.single is! Map || bodies.single['string'] != text) {
      throw StateError('Sticker composition confirmation is incomplete. Check Messages before sending again.');
    }
    final rawRuns = bodies.single['runs'];
    if (rawRuns is! List || rawRuns.isEmpty || rawRuns.length > text.length || rawRuns.any((run) => run is! Map)) {
      throw StateError('Sticker composition confirmation is missing its body runs.');
    }
    final runs = List<Map>.from(rawRuns);
    for (final run in runs) {
      final range = run['range'];
      final attributes = run['attributes'];
      final part = attributes is Map ? attributes['__kIMMessagePartAttributeName'] : null;
      if (range is! List ||
          range.length != 2 ||
          range.any((value) => value is! int) ||
          range[0] < 0 ||
          range[1] < 1 ||
          range[0] + range[1] > text.length ||
          part is! int ||
          part < 0 ||
          part > 0x7fffffff) {
        throw StateError('Sticker composition confirmation has invalid body ranges or parts.');
      }
    }
    runs.sort((a, b) => (a['range'][0] as int).compareTo(b['range'][0] as int));
    final transfers = <({String guid, int offset, int partIndex})>[];
    var cursor = 0;
    for (final run in runs) {
      final range = run['range'] as List;
      final attributes = run['attributes'] as Map;
      final slice = text.substring(range[0], range[0] + range[1]);
      final guid = attributes['__kIMFileTransferGUIDAttributeName'];
      if (range[0] != cursor) throw StateError('Sticker composition confirmation has incomplete body coverage.');
      cursor += range[1] as int;
      if (guid != null) {
        // Static inline composition is separate from animated native multipart messages.
        if (!_nativeGuid(guid) ||
            slice != '\uFFFC' ||
            range[1] != 1 ||
            attributes['__kIMEmojiImageAttributeName'] != 1) {
          throw StateError('Sticker composition confirmation has an unsupported transfer run.');
        }
        transfers.add((
          guid: guid as String,
          offset: range[0] as int,
          partIndex: attributes['__kIMMessagePartAttributeName'] as int,
        ));
      } else if (slice.contains('\uFFFC')) {
        throw StateError('Sticker composition confirmation has an unlinked marker.');
      }
    }
    if (cursor != text.length ||
        transfers.length != count ||
        transfers.map((run) => run.guid).toSet().length != count) {
      throw StateError('Sticker composition confirmation has mismatched transfers.');
    }
    return transfers;
  }

  static List<Attachment> confirmedCompositionAttachments(Map data, String text, int count) {
    final transfers = _compositionTransfers(data['attributedBody'], text, count);
    final hint = data['stickerComposition'];
    final raw = data['attachments'];
    final guids = hint is Map ? hint['attachmentGuids'] : null;
    final parts = hint is Map ? hint['parts'] : null;
    if (!_nativeGuid(data['guid']) ||
        data['isFromMe'] != true ||
        data['error'] != 0 ||
        data['associatedMessageGuid'] != null ||
        data['associatedMessageType'] != null ||
        guids is! List ||
        guids.length != count ||
        parts is! List ||
        parts.length != count ||
        raw is! List ||
        raw.length != count ||
        raw.any((asset) => asset is! Map)) {
      throw StateError('Sticker composition confirmation is incomplete. Check Messages before sending again.');
    }
    for (var i = 0; i < count; i++) {
      final part = parts[i];
      if (guids[i] != transfers[i].guid ||
          part is! Map ||
          part['partIndex'] is! int ||
          part['partIndex'] != transfers[i].partIndex ||
          part['range'] is! List ||
          part['range'].length != 2 ||
          part['range'].any((value) => value is! int) ||
          part['range'][0] != transfers[i].offset ||
          part['range'][1] != 1) {
        throw StateError('Sticker composition confirmation hint does not match its body.');
      }
    }
    final attachments = raw.map((entry) => Attachment.fromMap((entry as Map).cast<String, dynamic>())).toList();
    return _orderedCompositionAttachments(attachments, transfers.map((run) => run.guid).toList());
  }

  static List<Attachment> _orderedCompositionAttachments(List<Attachment> attachments, List<String> guids) {
    final ordered = <Attachment>[];
    for (var i = 0; i < guids.length; i++) {
      final guid = guids[i];
      final matches = attachments.where((asset) => asset.guid == guid).toList();
      if (matches.length != 1 || matches.single.metadata?['isSticker'] != true) {
        throw StateError('Sticker composition confirmation has mismatched sticker assets.');
      }
      final attachment = matches.single;
      attachment.metadata = {...?attachment.metadata, 'stickerCompositionIndex': i, 'preserveOriginalBytes': true};
      ordered.add(attachment);
    }
    return ordered;
  }

  static Map<String, String> compositionReplacementGuids(
    Message existing,
    Message replacement,
    List<Attachment> attachments,
  ) {
    final text = existing.metadata?['nativeStickerCompositionText'];
    final before = existing.dbAttachments.toList()
      ..sort(
        (a, b) => (a.metadata?['stickerCompositionIndex'] as int? ?? -1).compareTo(
          b.metadata?['stickerCompositionIndex'] as int? ?? -1,
        ),
      );
    if (text is! String ||
        before.isEmpty ||
        before.length != attachments.length ||
        !_nativeGuid(replacement.guid) || (_nativeGuid(existing.guid) && replacement.guid != existing.guid) ||
        replacement.isFromMe != true ||
        replacement.error != 0 ||
        replacement.associatedMessageGuid != null ||
        replacement.associatedMessageType != null) {
      throw StateError('Sticker composition echo is incomplete.');
    }
    for (var i = 0; i < before.length; i++) {
      if (before[i].guid == null || before[i].metadata?['stickerCompositionIndex'] != i) {
        throw StateError('Sticker composition echo has no exact local asset order.');
      }
    }
    if (before.map((asset) => asset.guid).toSet().length != before.length) {
      throw StateError('Sticker composition echo has duplicate local assets.');
    }
    final transfers = _compositionTransfers(
      replacement.attributedBody.map((body) => body.toMap()).toList(),
      text,
      before.length,
    );
    final after = _orderedCompositionAttachments(attachments, transfers.map((run) => run.guid).toList());
    for (var i = 0; i < before.length; i++) {
      if (_nativeGuid(before[i].guid) && before[i].guid != after[i].guid) {
        throw StateError('Sticker composition echo does not match the confirmed asset identities.');
      }
    }
    return {for (var i = 0; i < before.length; i++) after[i].guid!: before[i].guid!};
  }

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
