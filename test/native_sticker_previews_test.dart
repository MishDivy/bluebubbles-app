import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_asset_image.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/looping_image.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/image_viewer.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_image.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/network/api/attachment_api.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/services/ui/attachments_service.dart';
import 'package:bluebubbles/services/ui/sticker_preview_cache.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as image;

Uint8List artwork({bool animated = false}) {
  final value = image.Image(width: 8, height: 4, numChannels: 4)
    ..frameDuration = 100
    ..loopCount = 1;
  value.setPixelRgba(1, 1, 255, 0, 0, 128);
  if (animated) {
    value
        .addFrame(image.Image(width: 8, height: 4, numChannels: 4)..frameDuration = 100)
        .setPixelRgba(1, 1, 0, 0, 255, 128);
  }
  return Uint8List.fromList(image.encodePng(value));
}

class _PreviewApi implements BaseApi {
  @override
  final dio = Dio();
  String originValue = 'https://first.invalid';
  @override
  String get origin => originValue;
  @override
  String get apiRoot => '$origin/api/v1';
  @override
  Map<String, String> get headers => {'Authorization': 'test-secret'};
  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => {'guid': 'test-guid', ...params};
  final requests = <RequestOptions>[];
  final tokens = <CancelToken?>[];
  int status = 200;
  Uint8List bytes;
  bool animated;
  int? declaredLength;
  Completer<void>? pending;
  int closed = 0;
  int canceled = 0;
  _PreviewApi({this.animated = false}) : bytes = artwork(animated: animated) {
    dio.httpClientAdapter = _Adapter((request, cancelFuture) async {
      requests.add(request);
      tokens.add(request.cancelToken);
      if (pending != null) await pending!.future;
      final headers = {
        'content-type': ['image/png'],
        'content-length': ['${declaredLength ?? bytes.length}'],
        'x-bb-sticker-preview-format': [animated ? 'apng' : 'png'],
        'x-bb-sticker-preview-frames': [animated ? '2' : '1'],
        'x-bb-sticker-preview-width': ['8'],
        'x-bb-sticker-preview-height': ['4'],
        'x-bb-sticker-preview-has-alpha': ['true'],
      };
      final controller = StreamController<Uint8List>(onCancel: () => canceled++);
      scheduleMicrotask(() {
        controller.add(bytes);
        controller.close();
      });
      return ResponseBody(controller.stream, status, headers: headers, onClose: () => closed++);
    });
  }
  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true, bool retryOn502 = true}) {
    expect(retryOn502, false);
    return func();
  }

  @override
  Future<Response> returnSuccessOrError(Response response) async {
    if (response.statusCode != 200) throw response;
    return response;
  }
}

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions, Future<void>?) response;
  _Adapter(this.response);
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      response(options, cancelFuture);
  @override
  void close({bool force = false}) {}
}

class _Themes extends ThemesService {
  @override
  bool get isAnyMaterialYouSelected => false;
  @override
  bool inDarkMode(BuildContext context) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() async => GetIt.I.reset());

  test('preview GET authenticates without conversion options and preserves PNG/APNG bytes', () async {
    for (final animated in [false, true]) {
      final api = _PreviewApi(animated: animated);
      final response = await AttachmentApi(api).stickerPreview('transfer/guid');
      expect(response.data, api.bytes);
      expect(api.requests.single.path, endsWith('/attachment/transfer%2Fguid/sticker-preview'));
      expect(api.requests.single.queryParameters, {'guid': 'test-guid'});
      expect(api.requests.single.headers['Authorization'], 'test-secret');
      final decoded = image.decodePng(response.data);
      expect(decoded!.numFrames, animated ? 2 : 1);
      expect(decoded.getPixel(1, 1).a, 128);
    }
  });

  test('preview rejects oversized bytes and canvases before decoding', () async {
    final api = _PreviewApi()..declaredLength = AttachmentApi.maxStickerPreviewBytes + 1;
    await expectLater(AttachmentApi(api).stickerPreview('huge'), throwsStateError);
    final value = artwork();
    ByteData.sublistView(value).setUint32(16, 619);
    api.declaredLength = null;
    api.bytes = value;
    await expectLater(AttachmentApi(api).stickerPreview('canvas'), throwsStateError);
    api.bytes = Uint8List(AttachmentApi.maxStickerPreviewBytes + 1);
    api.declaredLength = 1;
    await expectLater(AttachmentApi(api).stickerPreview('stream'), throwsStateError);
  });

  test('preview rejects frame and decoded-pixel budgets and mismatched headers', () {
    final headers = Headers.fromMap({
      'x-bb-sticker-preview-format': ['apng'],
      'x-bb-sticker-preview-frames': ['2'],
      'x-bb-sticker-preview-width': ['8'],
      'x-bb-sticker-preview-height': ['4'],
    });
    final value = artwork(animated: true);
    AttachmentApi.validateStickerPreview(value, headers);
    for (var offset = 8; offset + 12 <= value.length;) {
      final data = ByteData.sublistView(value);
      if (String.fromCharCodes(value.sublist(offset + 4, offset + 8)) == 'acTL') {
        data.setUint32(offset + 8, 101);
        break;
      }
      offset += data.getUint32(offset) + 12;
    }
    expect(() => AttachmentApi.validateStickerPreview(value, headers), throwsStateError);
    expect(() => AttachmentApi.validateStickerPreview(artwork(), headers), throwsStateError);
    final excessive = BytesBuilder()..add(artwork().sublist(0, 33));
    Uint8List chunk(String name, Uint8List payload) {
      final value = Uint8List(payload.length + 12);
      ByteData.sublistView(value).setUint32(0, payload.length);
      value.setRange(4, 8, name.codeUnits);
      value.setRange(8, 8 + payload.length, payload);
      return value;
    }

    final acTL = Uint8List(8);
    ByteData.sublistView(acTL).setUint32(0, 70);
    excessive.add(chunk('acTL', acTL));
    for (var i = 0; i < 70; i++) {
      final frame = Uint8List(26);
      ByteData.sublistView(frame)
        ..setUint32(4, 1)
        ..setUint32(8, 1);
      excessive.add(chunk('fcTL', frame));
    }
    excessive.add(chunk('IEND', Uint8List(0)));
    final budget = excessive.takeBytes();
    ByteData.sublistView(budget)
      ..setUint32(16, 618)
      ..setUint32(20, 618);
    expect(
      () => AttachmentApi.validateStickerPreview(
        budget,
        Headers.fromMap({
          'x-bb-sticker-preview-format': ['apng'],
          'x-bb-sticker-preview-frames': ['70'],
          'x-bb-sticker-preview-width': ['618'],
          'x-bb-sticker-preview-height': ['618'],
        }),
      ),
      throwsStateError,
    );
  });

  test('single-subscription rejected responses cancel real Dio transport without masking errors', () async {
    for (final mode in ['headers', 'stream', 'status']) {
      final api = _PreviewApi();
      if (mode == 'headers') api.declaredLength = AttachmentApi.maxStickerPreviewBytes + 1;
      if (mode == 'stream') {
        api.bytes = Uint8List(AttachmentApi.maxStickerPreviewBytes + 1);
        api.declaredLength = 1;
      }
      if (mode == 'status') api.status = 503;
      await expectLater(AttachmentApi(api).stickerPreview(mode), throwsA(anything));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.tokens.single!.isCancelled, true);
      expect(api.closed, greaterThan(0));
    }
  });

  test('absolute deadline cancels a stalled preview stream', () async {
    final api = _PreviewApi();
    final stream = StreamController<Uint8List>();
    var closed = false;
    api.dio.httpClientAdapter = _Adapter(
      (request, cancelFuture) async => ResponseBody(
        stream.stream,
        200,
        headers: {
          'content-type': ['image/png'],
        },
        onClose: () => closed = true,
      ),
    );
    await expectLater(
      AttachmentApi(api, previewDeadline: const Duration(milliseconds: 30)).stickerPreview('stalled'),
      throwsA(anything),
    );
    expect(closed, true);
    await stream.close();
  });

  test('cache coalesces consumers, retains request until last disposal and isolates servers', () async {
    final api = _PreviewApi()..pending = Completer<void>();
    final cache = StickerPreviewCache();
    final inline = cache.acquire(api.origin, 'same', AttachmentApi(api));
    final fullscreen = cache.acquire(api.origin, 'same', AttachmentApi(api));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.requests, hasLength(1));
    inline.release();
    expect(api.tokens.single!.isCancelled, false);
    api.pending!.complete();
    final bytes = await fullscreen.future;
    expect(await inline.future, same(bytes));
    fullscreen.release();
    final cached = cache.acquire(api.origin, 'same', AttachmentApi(api));
    expect(await cached.future, same(bytes));
    cached.release();
    expect(api.requests, hasLength(1));
    api.originValue = 'https://second.invalid';
    final other = cache.acquire(api.origin, 'same', AttachmentApi(api));
    await other.future;
    other.release();
    expect(api.requests, hasLength(2));
  });

  test('last disposal cancels work and a reconnect discards an in-flight preview', () async {
    final api = _PreviewApi()..pending = Completer<void>();
    final cache = StickerPreviewCache();
    final abandoned = cache.acquire(api.origin, 'one', AttachmentApi(api));
    final failure = expectLater(abandoned.future, throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    abandoned.release();
    expect(api.tokens.single!.isCancelled, true);
    api.pending!.complete();
    await failure;
    api.pending = Completer<void>();
    final changed = cache.acquire(api.origin, 'two', AttachmentApi(api));
    final switched = expectLater(changed.future, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    api.originValue = 'https://different.invalid';
    api.pending!.complete();
    await switched;
    changed.release();
  });

  test('unavailable failures memoize until intentional retry or bounded expiry', () async {
    var now = DateTime(2026);
    final cache = StickerPreviewCache(now: () => now);
    final api = _PreviewApi()..status = 422;
    Future<void> attempt({bool retry = false}) async {
      final lease = cache.acquire(api.origin, 'unsupported', AttachmentApi(api), retry: retry);
      await expectLater(lease.future, throwsA(anything));
      lease.release();
    }

    await attempt();
    await attempt();
    expect(api.requests, hasLength(1));
    await attempt(retry: true);
    expect(api.requests, hasLength(2));
    now = now.add(const Duration(minutes: 6));
    await attempt();
    expect(api.requests, hasLength(3));
  });

  test('queued work rejects a changed origin and explicit retry discards cached bytes', () async {
    final api = _PreviewApi()..pending = Completer<void>();
    final cache = StickerPreviewCache();
    final leases = List.generate(3, (i) => cache.acquire(api.origin, 'change-$i', AttachmentApi(api)));
    final results = leases.map((lease) => expectLater(lease.future, throwsStateError)).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    api.originValue = 'https://second.invalid';
    api.pending!.complete();
    await Future.wait(results);
    for (final lease in leases) {
      lease.release();
    }
    expect(api.requests, hasLength(2));
    api.pending = null;
    final cached = cache.acquire(api.origin, 'retry', AttachmentApi(api));
    final first = await cached.future;
    cached.release();
    final retried = cache.acquire(api.origin, 'retry', AttachmentApi(api), retry: true);
    expect(await retried.future, isNot(same(first)));
    retried.release();
    expect(api.requests, hasLength(4));
  });

  test('bounded FIFO automatically loads a ten-sticker row with only two active requests', () async {
    final api = _PreviewApi()..pending = Completer<void>();
    final cache = StickerPreviewCache();
    final row = List.generate(10, (i) => cache.acquire(api.origin, 'row-$i', AttachmentApi(api)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.requests, hasLength(2));
    api.pending!.complete();
    await Future.wait(row.map((lease) => lease.future));
    for (final lease in row) {
      lease.release();
    }
    expect(api.requests, hasLength(10));
  });

  Future<_PreviewApi> harness(
    WidgetTester tester,
    Widget Function(Attachment, PlatformFile) child, {
    bool animated = true,
    int status = 200,
    Completer<void>? pending,
  }) async {
    final api = _PreviewApi(animated: animated)
      ..status = status
      ..pending = pending;
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<ThemesService>(_Themes());
    GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
    GetIt.I.registerSingleton<HttpService>(
      HttpService()
        ..originOverride = api.origin
        ..attachment = AttachmentApi(api),
    );
    final asset = Attachment(
      guid: 'synthetic-${DateTime.now().microsecondsSinceEpoch}',
      mimeType: 'image/heic',
      transferName: 'original.heic',
      width: 8,
      height: 4,
      metadata: {
        'sticker': {'packId': 'synthetic'},
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 180,
            child: child(asset, PlatformFile(name: 'original.heic', path: '/nonexistent/original.heic', size: 4)),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return api;
  }

  testWidgets('inline HEIC uses transparent looping preview and never touches original file', (tester) async {
    final api = await harness(tester, (asset, file) => ImageViewer(file: file, attachment: asset, isFromMe: false));
    expect(find.byType(StickerAssetImage), findsOneWidget);
    final display = tester.widget<Image>(find.byType(Image));
    expect(display.image, isA<LoopingMemoryImage>());
    expect((display.image as MemoryImage).bytes, api.bytes);
    expect(api.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native HEIC reply preview retains the compact 100px bounds', (tester) async {
    await harness(tester, (asset, file) {
      asset.width = 400;
      asset.height = 200;
      return Align(
        child: ImageViewer(file: file, attachment: asset, isFromMe: false, isInReply: true),
      );
    });
    final size = tester.getSize(find.byType(StickerAssetImage));
    expect(size.width, lessThanOrEqualTo(100));
    expect(size.height, lessThanOrEqualTo(100));
    expect(size.width / size.height, 2);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<LoopingMemoryImage>());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fullscreen HEIC uses the same looping preview provider', (tester) async {
    final api = await harness(
      tester,
      (asset, file) => FullscreenImage(file: file, attachment: asset, showInteractions: false, updatePhysics: (_) {}),
    );
    expect(find.byType(StickerAssetImage), findsOneWidget);
    expect(api.requests, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('faithful APNG preview loops beyond the encoded play-once limit', (tester) async {
    var frame = -1;
    await harness(
      tester,
      (asset, _) => StickerAssetImage(
        attachment: asset,
        imageBuilder: (context, provider, fallback) => Image(
          image: provider,
          frameBuilder: (context, child, current, synchronous) {
            if (current != null) frame = current;
            return child;
          },
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
    for (var i = 0; i < 16; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(frame, greaterThan(8));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('simultaneous inline and fullscreen consumers share work through one disposal', (tester) async {
    final pending = Completer<void>();
    final showInline = ValueNotifier(true);
    final api = await harness(
      tester,
      (asset, file) => ValueListenableBuilder<bool>(
        valueListenable: showInline,
        builder: (context, visible, _) => Column(
          children: [
            if (visible)
              SizedBox(
                key: const ValueKey('inline'),
                width: 240,
                height: 60,
                child: ImageViewer(file: file, attachment: asset, isFromMe: false),
              ),
            Expanded(
              key: const ValueKey('fullscreen'),
              child: FullscreenImage(file: file, attachment: asset, showInteractions: false, updatePhysics: (_) {}),
            ),
          ],
        ),
      ),
      pending: pending,
    );
    expect(api.requests, hasLength(1));
    expect(find.byType(StickerAssetImage), findsNWidgets(2));
    showInline.value = false;
    await tester.pump();
    expect(api.tokens.single!.isCancelled, false);
    pending.complete();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(api.requests, hasLength(1));
    expect(find.byType(StickerAssetImage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    showInline.dispose();
  });

  testWidgets('unsupported preview stays explicit and retries only on tap', (tester) async {
    final api = await harness(tester, (asset, _) => StickerAssetImage(attachment: asset), status: 422);
    expect(find.text('Retry preview'), findsOneWidget);
    expect(find.textContaining('original is unchanged'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(api.requests, hasLength(1));
    api.status = 200;
    await tester.tap(find.text('Retry preview'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(api.requests, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unavailable preview fits a small sticker tile', (tester) async {
    final api = await harness(
      tester,
      (asset, _) => Align(
        child: SizedBox(width: 100, height: 100, child: StickerAssetImage(attachment: asset)),
      ),
      status: 422,
    );
    expect(find.text('Retry preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(api.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('replacing artwork identity disposes the old controller and requests the new GUID', (tester) async {
    final api = await harness(tester, (asset, _) => StickerAssetImage(attachment: asset));
    final old = tester.widget<StickerAssetImage>(find.byType(StickerAssetImage)).parentController;
    final replacement = Attachment(
      guid: 'replacement-native',
      mimeType: 'image/heic',
      transferName: 'new.heic',
      metadata: {
        'sticker': {'packId': 'synthetic'},
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 240, height: 180, child: StickerAssetImage(attachment: replacement)),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(old.updateWidgetFunctions, isEmpty);
    expect(api.requests.last.path, contains('replacement-native'));
    expect(api.requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing server identity replaces same-GUID artwork even with a caller key', (tester) async {
    const key = ValueKey('caller-artwork');
    final api = await harness(tester, (asset, _) => StickerAssetImage(key: key, attachment: asset));
    final old = tester.widget<StickerAssetImage>(find.byType(StickerAssetImage)).parentController;
    api.originValue = 'https://second.invalid';
    GetIt.I<HttpService>().originOverride = api.origin;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 180,
            child: StickerAssetImage(key: key, attachment: old.attachment),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    final current = tester.widget<StickerAssetImage>(find.byType(StickerAssetImage)).parentController;
    expect(current, isNot(same(old)));
    expect(api.requests.last.path, startsWith(api.origin));
    expect(api.requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  test('ordinary HEIC photos retain compatibility behavior; native originals remain unchanged', () async {
    expect(StickerHelper.requiresNativePreview(Attachment(mimeType: 'image/heic', transferName: 'photo.heic')), false);
    final directory = await Directory.systemTemp.createTemp('native-sticker-preview-original-');
    try {
      final file = await File('${directory.path}/original.heic').writeAsBytes([1, 2, 3, 4]);
      final asset = Attachment(
        guid: 'native',
        mimeType: 'image/heic',
        transferName: 'original.heic',
        metadata: {'isSticker': true},
      );
      expect(await AttachmentsSvc.ensureImageCompatibility(asset, actualPath: file.path), isNull);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(await directory.list().length, 1);
      await File('${file.path}.png').writeAsBytes([8, 9]);
      await File('${file.path}.jpg').writeAsBytes([6, 7]);
      expect((AttachmentsSvc.getContent(asset, path: file.path, autoDownload: false) as PlatformFile).path, file.path);
      expect(AttachmentsSvc.hasLocalFile(asset, path: file.path), true);
      await file.delete();
      expect(AttachmentsSvc.hasLocalFile(asset, path: file.path), false);
      expect(AttachmentsSvc.getContent(asset, path: file.path, autoDownload: false), same(asset));
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
