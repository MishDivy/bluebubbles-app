import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/database/global/settings.dart';
import 'package:bluebubbles/database/io/attachment.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/services/backend/actions/image_actions.dart';
import 'package:bluebubbles/services/backend/interfaces/image_interface.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/ui/attachments_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;

img.Image transparentImage() {
  final image = img.Image(width: 8, height: 4, numChannels: 4);
  image.setPixelRgba(1, 1, 255, 0, 0, 128);
  return image;
}

img.Image animation() {
  final image = img.Image(width: 8, height: 4)..frameDuration = 100;
  img.fill(image, color: img.ColorRgb8(255, 0, 0));
  final second = img.Image(width: 8, height: 4)..frameDuration = 100;
  img.fill(second, color: img.ColorRgb8(0, 0, 255));
  image.addFrame(second);
  return image;
}

// Two opaque 2x2 frames (red, blue), generated with Pillow's lossless WebP encoder.
final animatedWebP = base64Decode(
  'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhM'
  'DwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AttachmentsService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bluebubbles-image-preview-test-');
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService()..appDocDir = directory);
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
    isIsolateOverride = true;
    service = AttachmentsService();
  });

  tearDown(() async {
    isIsolateOverride = false;
    await GetIt.I.reset();
    await directory.delete(recursive: true);
  });

  Future<File> source(List<int> bytes) async {
    return File('${directory.path}/original.bin').writeAsBytes(bytes);
  }

  Future<bool> generate(File original) => ImageInterface.generatePreview(
    path: original.path,
    outputPath: '${directory.path}/preview.jpg',
    maxDimension: 4,
    quality: 75,
  );

  Future<Attachment> attachment(List<int> bytes, {String mime = 'image/png', bool sticker = false}) async {
    final result = Attachment(
      guid: 'fixture',
      transferName: 'sticker.bin',
      mimeType: mime,
      metadata: {'isSticker': sticker},
    );
    await Directory(result.directory).create(recursive: true);
    await File(result.path).writeAsBytes(bytes);
    return result;
  }

  test('transparent PNG keeps the original alpha without a JPEG preview', () async {
    final bytes = img.encodePng(transparentImage());
    final original = await source(bytes);
    expect(await generate(original), isFalse);
    expect(await File('${directory.path}/preview.jpg').exists(), isFalse);
    expect(await original.readAsBytes(), bytes);
    final decoded = img.decodePng(await original.readAsBytes())!;
    expect(decoded.getPixel(0, 0).a, 0);
    expect(decoded.getPixel(1, 1).a, 128);
  });

  test('indexed PNG transparency also bypasses JPEG conversion', () async {
    final image = img.Image(width: 2, height: 2, numChannels: 4, withPalette: true);
    image.palette!.setRgba(0, 0, 0, 0, 0);
    image.palette!.setRgba(1, 255, 0, 0, 128);
    image.getPixel(1, 1).index = 1;
    final bytes = img.encodePng(image);
    expect(img.decodePng(bytes)!.hasAlpha, isTrue);
    expect(await generate(await source(bytes)), isFalse);
  });

  for (final format in ['PNG', 'GIF', 'WebP']) {
    test('animated $format is detected from bytes before making a still preview', () async {
      final bytes = switch (format) {
        'PNG' => img.encodePng(animation()),
        'GIF' => img.encodeGif(animation()),
        _ => animatedWebP,
      };
      expect(img.decodeImage(bytes)!.numFrames, 2);
      final original = await source(bytes);
      expect(await generate(original), isFalse);
      expect(await original.readAsBytes(), bytes);
      expect(await File('${directory.path}/preview.jpg').exists(), isFalse);
    });
  }

  test('opaque still photos retain downsampled JPEG previews', () async {
    final image = img.Image(width: 8, height: 4);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    for (final bytes in [img.encodePng(image), img.encodeJpg(image)]) {
      final original = await source(bytes);
      expect(await generate(original), isTrue);
      final preview = img.decodeJpg(await File('${directory.path}/preview.jpg').readAsBytes())!;
      expect((preview.width, preview.height), (4, 2));
      expect(await original.readAsBytes(), bytes);
    }
  });

  test('JPEG previews still apply EXIF orientation exactly once', () async {
    final image = img.Image(width: 8, height: 4);
    image.exif.imageIfd.orientation = 6;
    final original = await source(img.encodeJpg(image));
    expect(await generate(original), isTrue);
    final preview = img.decodeJpg(await File('${directory.path}/preview.jpg').readAsBytes())!;
    expect((preview.width, preview.height), (2, 4));
  });

  test('corrupt input falls back without leaving a preview', () async {
    expect(await generate(await source([1, 2, 3])), isFalse);
    expect(await File('${directory.path}/preview.jpg').exists(), isFalse);
  });

  test('isolate results distinguish originals from retryable failures', () async {
    for (final (bytes, expected) in [
      (img.encodePng(transparentImage()), 'original'),
      (img.encodePng(animation()), 'original'),
      (img.encodeJpg(img.Image(width: 8, height: 4)), 'created'),
      ([1, 2, 3], 'failed'),
    ]) {
      final original = await source(bytes);
      expect(
        await ImageActions.generatePreview({
          'path': original.path,
          'outputPath': '${directory.path}/preview.jpg',
          'maxDimension': 4,
          'quality': 75,
        }),
        expected,
      );
    }
  });

  test('original-file decisions survive quality changes and clear on replacement', () async {
    final item = await attachment(img.encodePng(transparentImage()));
    expect(service.usesOriginalImage(item), isFalse);
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.usesOriginalImage(item), isTrue);
    GetIt.I<SettingsService>().settings.previewImageQuality.value = 0.5;
    // This would produce a JPEG if the cached decision were ignored.
    await File(item.path).writeAsBytes(img.encodeJpg(img.Image(width: 8, height: 4)));
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.usesOriginalImage(item), isTrue);
    await service.deleteImagePreviews(item);
    expect(service.usesOriginalImage(item), isFalse);
    expect(await service.getOrCreateImagePreview(item), isNotNull);
  });

  test('failed and missing sources remain retryable', () async {
    final item = await attachment([1, 2, 3]);
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.usesOriginalImage(item), isFalse);
    await File(item.path).delete();
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.usesOriginalImage(item), isFalse);
    await File(item.path).writeAsBytes(img.encodeJpg(img.Image(width: 8, height: 4)));
    expect(await service.getOrCreateImagePreview(item), isNotNull);
  });

  test('original decisions follow the actual path and cache clearing', () async {
    final item = await attachment([1, 2, 3]);
    await File(item.convertedPath).writeAsBytes(img.encodePng(transparentImage()));
    expect(await service.getOrCreateImagePreview(item, actualPath: item.convertedPath), isNull);
    expect(service.usesOriginalImage(item), isFalse);
    expect(service.usesOriginalImage(item, actualPath: item.convertedPath), isTrue);
    service.clearImagePreviewCache();
    expect(service.usesOriginalImage(item, actualPath: item.convertedPath), isFalse);
    await service.getOrCreateImagePreview(item, actualPath: item.convertedPath);
    await service.deleteImagePreviews(item);
    expect(service.usesOriginalImage(item, actualPath: item.convertedPath), isFalse);
  });

  test('legacy white JPEG cache is ignored for transparent attachments', () async {
    final item = await attachment(img.encodePng(transparentImage()));
    final oldPreview = File('${item.path}.preview.q75.jpg');
    await oldPreview.writeAsBytes(img.encodeJpg(transparentImage()));
    expect(item.previewPathForQuality(75), isNot(oldPreview.path));
    expect(service.knownPreviewPath(item), isNull);
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.knownPreviewPath(item), isNull);
    expect(await File(item.path).exists(), isTrue);
  });

  test('explicit HEIC stickers bypass the opaque native JPEG converter', () async {
    final item = await attachment([1, 2, 3], mime: 'image/heic', sticker: true);
    await File(item.previewPathForQuality(75)).writeAsBytes([1, 2, 3]);
    expect(await service.getOrCreateImagePreview(item), isNull);
    expect(service.knownPreviewPath(item), isNull);
  });

  for (final format in ['PNG', 'GIF', 'WebP']) {
    test('animated $format survives a wrong MIME label and native decoding', () async {
      final bytes = switch (format) {
        'PNG' => img.encodePng(animation()),
        'GIF' => img.encodeGif(animation()),
        _ => animatedWebP,
      };
      final item = await attachment(bytes, mime: 'image/jpeg');
      expect(await service.getOrCreateImagePreview(item), isNull);
      final codec = await ui.instantiateImageCodec(await File(item.path).readAsBytes());
      addTearDown(codec.dispose);
      expect(codec.frameCount, 2);
      final first = await codec.getNextFrame();
      final second = await codec.getNextFrame();
      addTearDown(first.image.dispose);
      addTearDown(second.image.dispose);
      final firstPixels = await first.image.toByteData();
      final secondPixels = await second.image.toByteData();
      expect(firstPixels!.buffer.asUint8List(), isNot(secondPixels!.buffer.asUint8List()));
    });
  }

  test('the native fallback retains fully and partly transparent PNG pixels', () async {
    final item = await attachment(img.encodePng(transparentImage()));
    expect(await service.getOrCreateImagePreview(item), isNull);
    final codec = await ui.instantiateImageCodec(await File(item.path).readAsBytes());
    addTearDown(codec.dispose);
    final frame = await codec.getNextFrame();
    addTearDown(frame.image.dispose);
    final rgba = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    expect(rgba.getUint8(3), 0);
    expect(rgba.getUint8((1 * 8 + 1) * 4 + 3), 128);
  });

  test('late sticker metadata bypasses an already-known photo preview', () async {
    final item = await attachment(img.encodeJpg(img.Image(width: 8, height: 4)), mime: 'image/jpeg');
    expect(await service.getOrCreateImagePreview(item), isNotNull);
    expect(service.knownPreviewPath(item), isNotNull);
    item.metadata = {'isSticker': true};
    expect(service.knownPreviewPath(item), isNull);
    expect(await service.getOrCreateImagePreview(item), isNull);
  });

  test('valid opaque previews are reused and keep independent quality buckets', () async {
    final item = await attachment(img.encodeJpg(img.Image(width: 8, height: 4)), mime: 'image/jpeg');
    final path = await service.getOrCreateImagePreview(item);
    expect(path, item.previewPathForQuality(75));
    expect(service.knownPreviewPath(item), path);
    expect(await service.getOrCreateImagePreview(item), path);
    GetIt.I<SettingsService>().settings.previewImageQuality.value = 0.5;
    expect(service.knownPreviewPath(item), isNull);
    expect(await service.getOrCreateImagePreview(item), item.previewPathForQuality(50));
    expect(item.previewPathForQuality(50), isNot(path));
    await service.deleteImagePreviews(item);
    expect(service.knownPreviewPath(item), isNull);
    expect(await File(path!).exists(), isFalse);
    expect(await File(item.path).exists(), isTrue);
  });
}
