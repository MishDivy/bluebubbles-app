import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/image_viewer.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/looping_image.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_image.dart';
import 'package:bluebubbles/database/models.dart' show Attachment, PlatformFile, Settings;
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;

class _TestThemesService extends ThemesService {
  @override
  bool get isAnyMaterialYouSelected => false;
}

List<int> stickerBytes({int plays = 1, bool animated = true, String format = 'APNG'}) {
  final image = img.Image(width: 8, height: 4, numChannels: 4)
    ..frameDuration = 100
    ..loopCount = plays;
  image.setPixelRgba(1, 1, 255, 0, 0, 128);
  if (animated) {
    image
        .addFrame(img.Image(width: 8, height: 4, numChannels: 4)..frameDuration = 100)
        .setPixelRgba(1, 1, 0, 0, 255, 128);
  }
  if (format == 'GIF') {
    img.fill(image.frames.first, color: img.ColorRgba8(255, 0, 0, 255));
    if (animated) img.fill(image.frames.last, color: img.ColorRgba8(0, 0, 255, 255));
    return img.encodeGif(image);
  }
  if (format == 'WebP') {
    // Synthetic red/blue 2x2 frames from Pillow's lossless WebP encoder.
    final bytes = base64Decode(
      'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhM'
      'DwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA=',
    );
    final data = ByteData.sublistView(bytes);
    for (var offset = 12; offset < bytes.length;) {
      final size = data.getUint32(offset + 4, Endian.little);
      if (ascii.decode(bytes.sublist(offset, offset + 4)) == 'ANIM') {
        data.setUint16(offset + 12, plays, Endian.little);
        return bytes;
      }
      offset += 8 + size + (size % 2);
    }
    throw StateError('Synthetic WebP fixture has no ANIM chunk');
  }
  return img.encodePng(image);
}

Future<void> advanceFrames(WidgetTester tester, {int count = 12}) async {
  for (var i = 0; i < count; i++) {
    // Native file reads and codec work need real asynchronous turns.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget imageWidget(ImageProvider provider, void Function(int) onFrame, {bool enabled = true}) => MediaQuery(
  data: const MediaQueryData(),
  child: TickerMode(
    enabled: enabled,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Image(
        image: provider,
        frameBuilder: (context, child, frame, synchronous) {
          if (frame != null) onFrame(frame);
          return child;
        },
      ),
    ),
  ),
);

Uint8List fourPlayAnimation() {
  final image = img.Image(width: 8, height: 4, numChannels: 4)
    ..loopCount = 4
    ..frameDuration = 125;
  for (var i = 0; i < 8; i++) {
    final frame = i == 0 ? image : image.addFrame(img.Image(width: 8, height: 4, numChannels: 4));
    frame.frameDuration = 125;
    frame.setPixelRgba(1, 1, i * 30, 0, 255 - i * 30, 128);
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bluebubbles-sticker-playback-');
    file = File('${directory.path}/received.png');
  });

  tearDown(() async {
    isIsolateOverride = false;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await directory.delete(recursive: true);
    await GetIt.I.reset();
  });

  test('memory playback has a separate cache key from finite playback', () {
    final bytes = fourPlayAnimation();
    final looping = LoopingMemoryImage(bytes);
    expect(looping, isNot(MemoryImage(bytes)));
    expect(MemoryImage(bytes), isNot(looping));
    expect(looping, LoopingMemoryImage(bytes));
    expect(looping, isNot(LoopingMemoryImage(bytes, scale: 2)));
  });

  const samplePath = String.fromEnvironment('STICKER_SAMPLE_PATH');
  for (final sample in ['synthetic', if (samplePath.isNotEmpty) 'local sample']) {
    Future<Uint8List> sampleBytes() async =>
        sample == 'synthetic' ? fourPlayAnimation() : File(samplePath).readAsBytes();

    testWidgets('$sample: native playback stops at the four-play limit', (tester) async {
      await tester.runAsync(() async {
        await file.writeAsBytes(await sampleBytes());
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        expect(codec.frameCount, 8);
        expect(codec.repetitionCount, 3);
        codec.dispose();
      });
      var frame = -1;
      await tester.pumpWidget(imageWidget(FileImage(file), (value) => frame = value));
      await advanceFrames(tester, count: 100);
      expect(frame, 31);
      await advanceFrames(tester, count: 20);
      expect(frame, 31);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final fullscreen in [false, true]) {
      for (final fromMemory in [false, true]) {
        testWidgets('$sample: fullscreen=$fullscreen memory=$fromMemory loops past four plays', (tester) async {
          GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
          GetIt.I.registerSingleton<ThemesService>(_TestThemesService());
          GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = directory);
          GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
          isIsolateOverride = true;
          late Uint8List bytes;
          await tester.runAsync(() async {
            bytes = await sampleBytes();
            await file.writeAsBytes(bytes);
          });
          final attachment = Attachment(
            guid: 'finite-received-animation',
            transferName: 'received.png',
            mimeType: 'image/png',
            width: 370,
            height: 300,
            metadata: {'_orientation_processed': true},
          );
          final platformFile = PlatformFile(
            name: 'received.png',
            path: fromMemory ? null : file.path,
            bytes: fromMemory ? bytes : null,
            size: bytes.length,
          );
          Widget viewer() => GetMaterialApp(
            home: Scaffold(
              body: fullscreen
                  ? FullscreenImage(
                      file: platformFile,
                      attachment: attachment,
                      showInteractions: false,
                      updatePhysics: (_) {},
                    )
                  : ImageViewer(file: platformFile, attachment: attachment, isFromMe: false),
            ),
          );
          Future<void> expectMovingPixels() async {
            await advanceFrames(tester, count: 100);
            final frames = <String>{};
            for (var i = 0; i < 16; i++) {
              await advanceFrames(tester, count: 1);
              final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
              await tester.runAsync(() async {
                final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
                frames.add(sha256.convert(pixels!.buffer.asUint8List()).toString());
              });
            }
            expect(frames.length, greaterThan(1));
            expect(tester.takeException(), isNull);
          }

          await tester.pumpWidget(viewer());
          await expectMovingPixels();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(viewer());
          await expectMovingPixels();
          await tester.runAsync(() async => expect(await file.readAsBytes(), bytes));
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  for (final format in ['GIF', 'WebP']) {
    testWidgets('finite-loop $format keeps playing without changing the source', (tester) async {
      final bytes = stickerBytes(format: format);
      await tester.runAsync(() async {
        await file.writeAsBytes(bytes);
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        expect(codec.frameCount, 2);
        expect(codec.repetitionCount, greaterThanOrEqualTo(0));
        codec.dispose();
      });
      var frame = -1;
      await tester.pumpWidget(imageWidget(LoopingFileImage(file), (value) => frame = value));
      await advanceFrames(tester, count: 24);
      expect(frame, greaterThan(5));
      await tester.runAsync(() async => expect(await file.readAsBytes(), bytes));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('received sticker viewer uses looping playback without preview generation', (tester) async {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    final bytes = stickerBytes();
    await tester.runAsync(() => file.writeAsBytes(bytes));
    final attachment = Attachment(
      guid: 'received-sticker',
      transferName: 'received.png',
      mimeType: 'image/png',
      width: 8,
      height: 4,
      metadata: {'isSticker': true, '_orientation_processed': true},
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: ImageViewer(
            file: PlatformFile(name: 'received.png', path: file.path, size: bytes.length),
            attachment: attachment,
            isFromMe: false,
          ),
        ),
      ),
    );
    await advanceFrames(tester);
    final image = tester.widget<Image>(find.descendant(of: find.byType(ImageViewer), matching: find.byType(Image)));
    expect((image.image as ResizeImage).imageProvider, isA<LoopingFileImage>());
    expect(find.byType(FutureBuilder<String?>), findsNothing);
    // No filesystem/isolate service is registered: attempting a preview would fail.
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final format in ['APNG', 'GIF', 'WebP']) {
    for (final stickerFlag in [null, false]) {
      testWidgets('received $format loops with sticker flag $stickerFlag, including after reopening', (tester) async {
        GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
        GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = directory);
        GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
        isIsolateOverride = true;
        final bytes = stickerBytes(format: format);
        await tester.runAsync(() async {
          await file.writeAsBytes(bytes);
          final codec = await ui.instantiateImageCodec(await file.readAsBytes());
          expect(codec.frameCount, 2);
          expect(codec.repetitionCount, greaterThanOrEqualTo(0));
          final colors = <int>{};
          for (var i = 0; i < codec.frameCount; i++) {
            final frame = await codec.getNextFrame();
            final pixels = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
            colors.add(pixels!.getUint32((frame.image.width + 1) * 4));
            frame.image.dispose();
          }
          codec.dispose();
          expect(colors.length, 2, reason: 'The fixture must have visibly different frames');
        });
        final attachment = Attachment.fromMap({
          'guid': 'received-unmarked-animation',
          'transferName': 'received.png',
          'mimeType': format == 'GIF' ? 'image/gif' : 'image/png',
          'width': 8,
          'height': 4,
          'isSticker': ?stickerFlag,
          'metadata': {'_orientation_processed': true},
        });
        expect(attachment.isSticker, isFalse);

        Widget viewer() => GetMaterialApp(
          home: Scaffold(
            body: ImageViewer(
              file: PlatformFile(name: 'received.png', path: file.path, size: bytes.length),
              attachment: attachment,
              isFromMe: false,
            ),
          ),
        );

        Future<void> expectVisibleAnimation() async {
          // Sample pixels after the encoded finite animation would have finished.
          await advanceFrames(tester, count: 24);
          final colors = <int>{};
          for (var i = 0; i < 12; i++) {
            await advanceFrames(tester, count: 1);
            final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
            await tester.runAsync(() async {
              final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
              colors.add(pixels!.getUint32((image.width + 1) * 4));
            });
          }
          expect(colors.length, greaterThan(1));
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(viewer());
        await expectVisibleAnimation();
        await tester.pumpWidget(const SizedBox.shrink());
        await advanceFrames(tester, count: 3);
        await tester.pumpWidget(viewer());
        await expectVisibleAnimation();
        await tester.runAsync(() async => expect(await file.readAsBytes(), bytes));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('play-once sticker stops with FileImage but loops with the sticker provider', (tester) async {
    final bytes = stickerBytes();
    await tester.runAsync(() async {
      await file.writeAsBytes(bytes);
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      expect(codec.frameCount, 2);
      expect(codec.repetitionCount, 0);
      codec.dispose();
    });
    var frame = -1;
    await tester.pumpWidget(imageWidget(FileImage(file), (value) => frame = value));
    await advanceFrames(tester);
    expect(frame, 1);
    await advanceFrames(tester);
    expect(frame, 1);

    final looping = LoopingFileImage(file);
    expect(looping, isNot(FileImage(file)));
    expect(FileImage(file), isNot(looping));
    expect(looping, LoopingFileImage(File(file.path)));
    await tester.pumpWidget(imageWidget(looping, (value) => frame = value));
    await advanceFrames(tester);
    expect(frame, greaterThan(3));
    final previous = frame;
    await advanceFrames(tester);
    expect(frame, greaterThan(previous));
    await tester.runAsync(() async => expect(await file.readAsBytes(), bytes));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sticker continues after leaving and reopening its cached image', (tester) async {
    await tester.runAsync(() => file.writeAsBytes(stickerBytes()));
    var frame = -1;
    final provider = LoopingFileImage(file);
    await tester.pumpWidget(imageWidget(provider, (value) => frame = value));
    await advanceFrames(tester);
    expect(frame, greaterThan(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await advanceFrames(tester, count: 3);
    frame = -1;
    await tester.pumpWidget(imageWidget(LoopingFileImage(file), (value) => frame = value));
    await advanceFrames(tester);
    expect(frame, greaterThan(3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ticker mode pauses and resumes sticker playback', (tester) async {
    await tester.runAsync(() => file.writeAsBytes(stickerBytes()));
    var frame = -1;
    final provider = LoopingFileImage(file);
    void onFrame(int value) => frame = value;
    await tester.pumpWidget(imageWidget(provider, onFrame));
    await advanceFrames(tester);
    expect(frame, greaterThan(1));
    await tester.pumpWidget(imageWidget(provider, onFrame, enabled: false));
    await advanceFrames(tester, count: 3);
    final pausedFrame = frame;
    await advanceFrames(tester);
    expect(frame, pausedFrame);
    await tester.pumpWidget(imageWidget(provider, onFrame));
    await advanceFrames(tester);
    expect(frame, greaterThan(pausedFrame));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('static stickers stay still and resized decoding preserves alpha', (tester) async {
    await tester.runAsync(() => file.writeAsBytes(stickerBytes(animated: false)));
    var frame = -1;
    await tester.pumpWidget(
      imageWidget(ResizeImage.resizeIfNeeded(4, null, LoopingFileImage(file)), (value) => frame = value),
    );
    await advanceFrames(tester);
    expect(frame, 0);
    final rendered = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((rendered.width, rendered.height), (4, 2));
    await tester.runAsync(() async {
      final pixels = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels!.getUint8((4 * 2 - 1) * 4 + 3), 0);
    });
    await advanceFrames(tester);
    expect(frame, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
