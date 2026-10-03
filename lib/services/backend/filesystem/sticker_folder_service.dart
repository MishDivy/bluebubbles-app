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
}
