import 'dart:convert';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/draft_sticker_thumbnail.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:flutter/material.dart';

class DraftStickerAsset {
  final String token;
  final StickerFolderEntry entry;
  const DraftStickerAsset(this.token, this.entry);
  Map<String, dynamic> toMap() => {'token': token, 'uri': entry.uri, 'name': entry.name, 'size': entry.size};
  factory DraftStickerAsset.fromMap(Map data) {
    final token = data['token'];
    final uri = data['uri'];
    final name = data['name'];
    final size = data['size'];
    if (token is! String ||
        !StickerCompositionController.isToken(token) ||
        uri is! String ||
        !uri.startsWith('content://') ||
        uri.length > 4096 ||
        name is! String ||
        name.isEmpty ||
        name.length > 255 ||
        size is! int ||
        size < 1 ||
        size > StickerFolderService.maxBytes) {
      throw const FormatException('The saved sticker draft is invalid.');
    }
    return DraftStickerAsset(token, StickerFolderEntry(uri: uri, name: name, size: size, directory: false));
  }
}

class StickerCompositionSnapshot {
  final String serverIdentity;
  final String chatGuid;
  final String text;
  final List<StickerFolderEntry> entries;
  final int revision;
  const StickerCompositionSnapshot(this.serverIdentity, this.chatGuid, this.text, this.entries, this.revision);
}

/// A composer-local marker occupies one cursor position, separate from mention delimiters.
class StickerCompositionController extends MentionTextEditingController {
  final String serverIdentity;
  final String chatGuid;
  final StickerFolderService folders;
  final Map<String, DraftStickerAsset> _stickers = {};
  bool _active = false;
  int _revision = 0;
  bool _disposed = false;
  bool _updatingValue = false;
  bool _pendingNotification = false;
  int? _restoringRevision;
  int _lastStickerRevision = -1;
  StickerCompositionController({
    required this.serverIdentity,
    required this.chatGuid,
    required FocusNode focusNode,
    this.folders = const StickerFolderService(),
  }) : super(focusNode: focusNode);

  static final tokenPattern = RegExp('[\uE100-\uE1FF]');
  static bool isToken(String value) => value.length == 1 && tokenPattern.hasMatch(value);
  bool get hasComposition => _active;
  bool get isDisposed => _disposed;
  StrutStyle? get composerStrut => _active ? const StrutStyle(fontSize: 44, height: 1, forceStrutHeight: true) : null;
  int get revision => _revision;
  String get plainDraftText =>
      !_active ? text : _stickers.keys.fold(text, (current, token) => current.replaceAll(token, ''));

  @override
  set value(TextEditingValue newValue) {
    if (_active && !newValue.selection.isValid) {
      newValue = newValue.copyWith(selection: TextSelection.collapsed(offset: newValue.text.length));
    }
    final previous = value.text;
    final wasActive = _active;
    _updatingValue = true;
    try {
      super.value = newValue;
    } finally {
      if (_restoringRevision != null) _revision = _restoringRevision!;
      if (text != previous) {
        if (_restoringRevision == null) _revision++;
        if (wasActive) _lastStickerRevision = _revision;
        _stickers.removeWhere((token, _) => !text.contains(token));
        if (_stickers.isEmpty && !tokenPattern.hasMatch(text)) _active = false;
      }
      _updatingValue = false;
      if (_pendingNotification) {
        _pendingNotification = false;
        super.notifyListeners();
      }
    }
  }

  bool canClearAfterOrdinarySend(int startedRevision) => !_active && _lastStickerRevision <= startedRevision;

  @override
  void notifyListeners() {
    if (_updatingValue) {
      _pendingNotification = true;
      return;
    }
    super.notifyListeners();
  }

  void insertSticker(StickerFolderEntry entry) {
    if (_disposed) throw StateError('The conversation closed. Open it again.');
    if (!_active && tokenPattern.hasMatch(text)) {
      throw StateError('This draft contains reserved sticker characters. Remove them before adding a sticker.');
    }
    if (entry.directory || entry.size < 1 || entry.size > StickerFolderService.maxBytes || entry.name.length > 255) {
      throw StateError('Choose a sticker up to 500 KiB with a filename up to 255 characters.');
    }
    final range = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final replaced = text.substring(range.start, range.end);
    if (_stickers.keys.where((token) => !replaced.contains(token)).length >= 10) {
      throw StateError('A message can contain at most 10 stickers.');
    }
    final token = List.generate(
      256,
      (index) => String.fromCharCode(0xE100 + index),
    ).firstWhere((candidate) => !text.contains(candidate) && !_stickers.containsKey(candidate));
    _active = true;
    _stickers[token] = DraftStickerAsset(token, entry);
    value = TextEditingValue(
      text: text.replaceRange(range.start, range.end, token),
      selection: TextSelection.collapsed(offset: range.start + 1),
    );
  }

  void removeSticker(String token) {
    final offset = text.indexOf(token);
    if (!_stickers.containsKey(token) || offset < 0) return;
    value = TextEditingValue(
      text: text.replaceRange(offset, offset + 1, ''),
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  StickerCompositionSnapshot snapshot() {
    if (!_active || _stickers.isEmpty) throw StateError('Add a sticker before sending this composition.');
    if (text.contains(MentionTextEditingController.escapingChar)) {
      throw StateError('Mentions and pasted object markers are not supported in sticker compositions.');
    }
    final matches = tokenPattern.allMatches(text).toList();
    if (matches.length != _stickers.length ||
        matches.any((match) => !_stickers.containsKey(match.group(0))) ||
        matches.map((match) => match.group(0)).toSet().length != matches.length) {
      throw StateError('A sticker marker has no unique artwork. Remove it and choose the sticker again.');
    }
    final wireText = text.replaceAll(tokenPattern, '\uFFFC');
    if (wireText.length > 4096) throw StateError('The sticker draft is too long. Shorten the text before sending.');
    for (var index = 0; index < wireText.length; index++) {
      final unit = wireText.codeUnitAt(index);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (++index >= wireText.length || wireText.codeUnitAt(index) < 0xDC00 || wireText.codeUnitAt(index) > 0xDFFF) {
          throw StateError('The draft contains an incomplete Unicode character.');
        }
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        throw StateError('The draft contains an incomplete Unicode character.');
      }
    }
    return StickerCompositionSnapshot(
      serverIdentity,
      chatGuid,
      wireText,
      List.unmodifiable(matches.map((match) => _stickers[match.group(0)]!.entry)),
      _revision,
    );
  }

  bool clearIfUnchanged(StickerCompositionSnapshot sent) {
    if (_disposed || sent.serverIdentity != serverIdentity || sent.chatGuid != chatGuid || sent.revision != _revision) {
      return false;
    }
    _stickers.clear();
    _active = false;
    clear();
    return true;
  }

  String? serializeDraft() => !_active
      ? null
      : jsonEncode({
          'version': 1,
          'server': serverIdentity,
          'chat': chatGuid,
          'revision': _revision,
          'text': text,
          'selection': [selection.baseOffset, selection.extentOffset],
          'stickers': _stickers.values.map((asset) => asset.toMap()).toList(),
        });

  void restoreDraft(String raw) {
    if (raw.length > 65536) throw const FormatException('The saved sticker draft is too large.');
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['version'] != 1 ||
        data['server'] != serverIdentity ||
        data['chat'] != chatGuid ||
        data['text'] is! String ||
        data['stickers'] is! List ||
        (data['stickers'] as List).length > 10 ||
        data['revision'] is! int ||
        data['selection'] is! List ||
        (data['selection'] as List).length != 2) {
      throw const FormatException('The saved sticker draft does not belong to this conversation.');
    }
    final savedAssets = data['stickers'] as List;
    if (savedAssets.isEmpty || savedAssets.any((asset) => asset is! Map) || (data['revision'] as int) < 0) {
      throw const FormatException('The saved sticker artwork is invalid.');
    }
    final assets = savedAssets.map((asset) => DraftStickerAsset.fromMap(asset as Map)).toList();
    if (assets.map((asset) => asset.token).toSet().length != assets.length) {
      throw const FormatException('The saved sticker draft contains duplicate artwork markers.');
    }
    final draftText = data['text'] as String;
    final tokens = tokenPattern.allMatches(draftText).map((match) => match.group(0)).toList();
    if (tokens.length != assets.length ||
        tokens.toSet().length != tokens.length ||
        tokens.any((token) => !assets.any((asset) => asset.token == token))) {
      throw const FormatException('The saved sticker draft has unmatched artwork markers.');
    }
    final offsets = data['selection'] as List;
    if (offsets.any((offset) => offset is! int || offset < -1 || offset > draftText.length) ||
        (offsets[0] == -1) != (offsets[1] == -1)) {
      throw const FormatException('The saved sticker cursor is invalid.');
    }
    _stickers.clear();
    _stickers.addEntries(assets.map((asset) => MapEntry(asset.token, asset)));
    _active = true;
    _restoringRevision = data['revision'] as int;
    try {
      value = TextEditingValue(
        text: draftText,
        selection: offsets[0] == -1
            ? TextSelection.collapsed(offset: draftText.length)
            : TextSelection(baseOffset: offsets[0] as int, extentOffset: offsets[1] as int),
      );
    } finally {
      _restoringRevision = null;
    }
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final original = super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    if (!_active) return original;
    InlineSpan replace(InlineSpan span) {
      if (span is! TextSpan) return span;
      final chunk = span.text ?? '';
      if (!tokenPattern.hasMatch(chunk)) {
        return TextSpan(
          text: span.text,
          style: span.style,
          children: span.children?.map(replace).toList(),
          recognizer: span.recognizer,
          onEnter: span.onEnter,
          onExit: span.onExit,
        );
      }
      final children = <InlineSpan>[];
      var start = 0;
      for (final match in tokenPattern.allMatches(chunk)) {
        children.add(TextSpan(text: chunk.substring(start, match.start)));
        final token = match.group(0)!;
        final asset = _stickers[token];
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: DraftStickerThumbnail(
              key: ValueKey((serverIdentity, token, asset?.entry.uri)),
              entry: asset?.entry,
              folders: folders,
              onSelect: () {
                final offset = text.indexOf(token);
                if (offset >= 0) selection = TextSelection(baseOffset: offset, extentOffset: offset + 1);
              },
              onRemove: () => removeSticker(token),
            ),
          ),
        );
        start = match.end;
      }
      children.add(TextSpan(text: chunk.substring(start)));
      children.addAll(span.children?.map(replace) ?? []);
      return TextSpan(style: span.style, children: children);
    }

    return replace(original) as TextSpan;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
