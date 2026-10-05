import 'dart:io';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/backend/outgoing_message_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as image;

const first = StickerFolderEntry(uri: 'content://synthetic/one', name: 'one.png', directory: false, size: 8);
const second = StickerFolderEntry(uri: 'content://synthetic/two', name: 'two.png', directory: false, size: 8);

class _Queue extends OutgoingMessageHandler {
  final items = <OutgoingQueueItem>[];
  final bytes = <List<int>>[];
  @override
  Future<void> queue(OutgoingQueueItem item) async {
    items.add(item);
    final attachments = item is OutgoingStickerRow ? item.attachments : [(item as OutgoingAttachment).attachment];
    for (final attachment in attachments) {
      final path = attachment.metadata!['source_path'] as String;
      expect(await File(path).exists(), true);
      bytes.add(await File(path).readAsBytes());
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/composition-staging');
  const folders = StickerFolderService(channel: channel);
  final chat = Chat(guid: 'iMessage;-;synthetic');
  late Directory staging;
  late _Queue queue;
  late List<int> original;
  final stagedPaths = <String>[];
  var calls = 0;
  var current = true;
  var failSecond = false;
  var invalidateAfterStage = false;
  setUp(() async {
    staging = await Directory.systemTemp.createTemp('bb-synthetic-composition-');
    queue = _Queue();
    GetIt.I.registerSingleton<OutgoingMessageHandler>(queue);
    original = image.encodePng(image.Image(width: 2, height: 2));
    calls = 0;
    current = true;
    failSecond = false;
    invalidateAfterStage = false;
    stagedPaths.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'stage-sticker');
      calls++;
      if (failSecond && calls == 2) throw PlatformException(code: 'revoked');
      final file = File('${staging.path}/selected-$calls.png');
      await file.writeAsBytes(original);
      stagedPaths.add(file.path);
      if (invalidateAfterStage) current = false;
      return {'path': file.path, 'name': 'selected-$calls.png', 'size': original.length};
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await GetIt.I.reset();
    await staging.delete(recursive: true);
  });

  test('ordered originals queue one composition before staged assets are removed', () async {
    await folders.sendComposition(
      chat,
      [first, second],
      'before\uFFFC\n\uFFFCafter',
      'https://one.invalid',
      canQueue: () => current,
    );
    final item = queue.items.single as OutgoingStickerRow;
    expect(item.compositionText, 'before\uFFFC\n\uFFFCafter');
    expect(item.serverIdentity, 'https://one.invalid');
    expect(item.attachments, hasLength(2));
    expect(queue.bytes, [original, original]);
    for (final path in stagedPaths) {
      expect(await File(path).exists(), false);
    }
  });

  test('exactly one marker routes animated original through the standalone native intent', () async {
    original = 'GIF89a-synthetic-original'.codeUnits;
    await folders.sendComposition(chat, [first], '\uFFFC', 'https://one.invalid', canQueue: () => current);
    final item = queue.items.single as OutgoingAttachment;
    expect(item.isNativeSticker, true);
    expect(item.message.text, isEmpty);
    expect(item.message.metadata!['nativeStickerOrigin'], 'https://one.invalid');
    expect(item.attachment.metadata!['nativeStickerOrigin'], 'https://one.invalid');
    expect(item.attachment.metadata!['preserveOriginalBytes'], true);
    expect(queue.bytes.single, original);
    expect(await File(stagedPaths.single).exists(), false);
  });

  test('whitespace with one marker remains composition and cannot flatten an animated input', () async {
    original = 'GIF89a-synthetic-original'.codeUnits;
    await expectLater(
      folders.sendComposition(chat, [first], '\uFFFC ', 'https://one.invalid', canQueue: () => current),
      throwsUnsupportedError,
    );
    expect(queue.items, isEmpty);
    expect(await File(stagedPaths.single).exists(), false);
  });

  test('server switch after stage or partial revoked grant leaves no queued message or staged original', () async {
    invalidateAfterStage = true;
    await expectLater(
      folders.sendComposition(chat, [first], '\uFFFC', 'https://one.invalid', canQueue: () => current),
      throwsStateError,
    );
    expect(queue.items, isEmpty);
    expect(await File(stagedPaths.single).exists(), false);
    invalidateAfterStage = false;
    current = true;
    calls = 0;
    stagedPaths.clear();
    failSecond = true;
    await expectLater(
      folders.sendComposition(chat, [first, second], '\uFFFC\uFFFC', 'https://one.invalid', canQueue: () => current),
      throwsA(isA<PlatformException>()),
    );
    expect(queue.items, isEmpty);
    expect(await File(stagedPaths.single).exists(), false);
  });
}
