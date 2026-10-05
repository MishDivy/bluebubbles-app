import 'dart:convert';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/outgoing_message_handler.dart';
import 'package:flutter/services.dart';
import 'package:mime_type/mime_type.dart';
import 'package:universal_io/io.dart';

class StickerFolderEntry {
  final String uri;
  final String name;
  final bool directory;
  final int size;

  const StickerFolderEntry({required this.uri, required this.name, required this.directory, required this.size});

  factory StickerFolderEntry.fromMap(Map<dynamic, dynamic> data) => StickerFolderEntry(
    uri: data['uri'] as String,
    name: data['name'] as String,
    directory: data['directory'] == true,
    size: data['size'] as int,
  );
}

class StickerFolderPage {
  final List<StickerFolderEntry> entries;
  final int nextOffset;
  final bool hasMore;
  const StickerFolderPage(this.entries, this.nextOffset, this.hasMore);
}

/// Stateless access to Android's persisted read grant, with no library import.
class StickerFolderService {
  static const maxBytes = 500 * 1024;
  final MethodChannel channel;
  const StickerFolderService({this.channel = const MethodChannel('com.bluebubbles.messaging/sticker-folder')});

  static void requireStaticCompositionPng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 8 || bytes.length > maxBytes ||
        List.generate(8, (index) => index).any((index) => bytes[index] != signature[index])) {
      throw UnsupportedError('Rows and text with stickers currently support static PNG only. Your selection is still here.');
    }
    final data = ByteData.sublistView(bytes);
    var offset = 8;
    var first = true;
    var hasImage = false;
    while (offset + 12 <= bytes.length) {
      final length = data.getUint32(offset);
      if (length > bytes.length - offset - 12) break;
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'acTL' || type == 'fcTL' || type == 'fdAT') {
        throw UnsupportedError('Animated stickers are not supported in rows or with text yet. Your selection is still here.');
      }
      if (first && (type != 'IHDR' || length != 13)) break;
      first = false;
      if (type == 'IDAT') hasImage = true;
      offset += length + 12;
      if (type == 'IEND') {
        if (length == 0 && hasImage && offset == bytes.length) return;
        break;
      }
    }
    throw StateError('This PNG sticker is incomplete. Choose another sticker. Your draft is still here.');
  }

  Future<void> _checkStaticPng(PlatformFile file) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in File(file.path!).openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw StateError('This sticker exceeds 500 KiB. Your selection is still here.');
      }
      bytes.add(chunk);
    }
    requireStaticCompositionPng(bytes.takeBytes());
  }

  Future<String?> currentFolder() => channel.invokeMethod<String>('get-folder');
  Future<String?> chooseFolder() => channel.invokeMethod<String>('choose-folder');

  Future<StickerFolderPage> list({required String uri, int offset = 0}) async {
    final data = (await channel.invokeMapMethod<String, dynamic>('list-folder', {'uri': uri, 'offset': offset}))!;
    return StickerFolderPage(
      (data['entries'] as List).map((e) => StickerFolderEntry.fromMap(e as Map)).toList(),
      data['nextOffset'] as int,
      data['hasMore'] == true,
    );
  }

  Future<Uint8List> read(StickerFolderEntry entry, {String? requestId}) async =>
      (await channel.invokeMethod<Uint8List>('read-sticker', {'uri': entry.uri, 'requestId': ?requestId}))!;

  Future<void> cancelRead(String requestId) async {
    try {
      await channel.invokeMethod<void>('cancel-read', {'requestId': requestId});
    } on PlatformException {
      // The activity may have closed before the thumbnail disposed.
    } on MissingPluginException {
      // The engine may have detached the feature's channel.
    }
  }

  static Attachment buildAttachment(PlatformFile file, {required bool nativeSticker}) => Attachment(
    isOutgoing: true,
    transferName: file.name,
    totalBytes: file.size,
    mimeType: mime(file.name) ?? 'image/png',
    metadata: {
      'source_path': file.path,
      'preserveOriginalBytes': true,
      if (nativeSticker) 'nativeStickerSend': true,
      if (nativeSticker) 'isSticker': true,
    },
  );

  /// Stages the one selected original, then queues it without touching the draft.
  Future<void> send(Chat chat, StickerFolderEntry entry, {required bool nativeSticker}) async {
    final data = (await channel.invokeMapMethod<String, dynamic>('stage-sticker', {'uri': entry.uri}))!;
    final file = PlatformFile(path: data['path'] as String, name: data['name'] as String, size: data['size'] as int);
    final attachment = buildAttachment(file, nativeSticker: nativeSticker);
    final message = Message(text: '', dateCreated: DateTime.now(), hasAttachments: true, isFromMe: true, handleId: 0);
    try {
      await OutgoingMsgHandler.queue(OutgoingAttachment(chat: chat, message: message, attachment: attachment));
    } finally {
      // queue() finishes staging into attachment storage before it returns.
      try {
        await File(file.path!).delete();
      } on FileSystemException {
        // Android cleans stale files in this feature's cache on later selections.
      }
    }
  }

  Future<void> sendRow(Chat chat, List<StickerFolderEntry> entries) async {
    if (entries.length < 2 || entries.length > 10) throw ArgumentError('Select 2 to 10 stickers for a row.');
    final staged = <PlatformFile>[];
    try {
      for (final entry in entries) {
        final data = (await channel.invokeMapMethod<String, dynamic>('stage-sticker', {'uri': entry.uri}))!;
        staged.add(PlatformFile(path: data['path'] as String, name: data['name'] as String, size: data['size'] as int));
        await _checkStaticPng(staged.last);
      }
      final message = Message(text: '', dateCreated: DateTime.now(), hasAttachments: true, isFromMe: true, handleId: 0);
      await OutgoingMsgHandler.queue(OutgoingStickerRow(chat: chat, message: message,
        attachments: staged.map((file) => buildAttachment(file, nativeSticker: false)).toList()));
    } finally {
      for (final file in staged) {
        try {
          await File(file.path!).delete();
        } on FileSystemException {
          // Later selections clean abandoned files from this feature's cache.
        }
      }
    }
  }

  Future<void> sendComposition(Chat chat, List<StickerFolderEntry> entries, String text,
      String serverIdentity, {required bool Function() canQueue}) async {
    final staged = <PlatformFile>[];
    final standalone = entries.length == 1 && text == '\uFFFC';
    try {
      for (final entry in entries) {
        if (!canQueue()) throw StateError('The conversation or server changed. Your draft is still here.');
        final data = (await channel.invokeMapMethod<String, dynamic>('stage-sticker', {'uri': entry.uri}))!;
        staged.add(PlatformFile(path: data['path'] as String, name: data['name'] as String, size: data['size'] as int));
        if (!standalone) await _checkStaticPng(staged.last);
      }
      if (!canQueue()) throw StateError('The conversation or server changed. Your draft is still here.');
      final message = Message(text: standalone ? '' : text, dateCreated: DateTime.now(),
        hasAttachments: true, isFromMe: true, handleId: 0,
        metadata: standalone ? {'nativeStickerOrigin': serverIdentity} : null);
      message.generateTempGuid();
      if (!standalone && utf8.encode('${chat.guid}${message.guid}${jsonEncode([
        for (final file in staged) {'name': file.name},
      ])}$text').length > 8192) {
        throw StateError('The sticker draft is too large. Shorten the text or filenames. Your draft is still here.');
      }
      if (standalone) {
        final attachment = buildAttachment(staged.single, nativeSticker: true);
        attachment.metadata = {...?attachment.metadata, 'nativeStickerOrigin': serverIdentity};
        await OutgoingMsgHandler.queue(OutgoingAttachment(chat: chat, message: message, attachment: attachment));
      } else {
        await OutgoingMsgHandler.queue(OutgoingStickerRow(chat: chat, message: message,
          attachments: staged.map((file) => buildAttachment(file, nativeSticker: false)).toList(),
          compositionText: text, serverIdentity: serverIdentity));
      }
    } finally {
      for (final file in staged) {
        try {
          await File(file.path!).delete();
        } on FileSystemException {
          // Android also removes stale files from this feature's staging cache.
        }
      }
    }
  }

  Future<void> sendTargeted(Chat chat, StickerFolderEntry entry, NativeStickerTarget target,
      {StickerPlacement? placement, bool Function()? canQueue}) async {
    final data = (await channel.invokeMapMethod<String, dynamic>('stage-sticker', {'uri': entry.uri}))!;
    final file = PlatformFile(path: data['path'] as String, name: data['name'] as String, size: data['size'] as int);
    try {
      if (canQueue?.call() == false) throw StateError('The sticker target is no longer available.');
      await OutgoingMsgHandler.queue(OutgoingTargetedSticker(chat: chat,
        message: Message(text: '', dateCreated: DateTime.now(), isFromMe: true, handleId: 0), target: target,
        placement: placement, attachment: buildAttachment(file, nativeSticker: false)));
    } finally {
      try {
        await File(file.path!).delete();
      } on FileSystemException {
        // Later selections clean abandoned files from this feature's cache.
      }
    }
  }
}
