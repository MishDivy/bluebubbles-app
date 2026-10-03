import 'dart:io';
import 'dart:async';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/models/server_details.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/backend/interfaces/send_message_interface.dart';
import 'package:bluebubbles/services/backend/outgoing_message_handler.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/ui/chat/conversation_view_controller.dart';
import 'package:image/image.dart' as image;

class _OfflineApi implements BaseApi {
  final Object? capability;
  final int postStatus;
  final requests = <RequestOptions>[];
  final retries = <bool>[];
  _OfflineApi({this.capability = true, this.postStatus = 200}) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: request.method == 'GET' ? 200 : postStatus,
              data: {
                'data': {
                  'guid': 'sent',
                  'privateApiCapabilities': {'stickerSending': capability},
                },
              },
            ),
          );
        },
      ),
    );
  }
  @override
  final dio = Dio();
  @override
  String get origin => 'https://offline.trycloudflare.invalid';
  @override
  String get apiRoot => '$origin/api/v1';
  @override
  Map<String, String> get headers => {'test-header': 'retained'};
  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => {'guid': 'test-auth', ...params};
  @override
  Future<Response> runApiGuarded(
    Future<Response> Function() func, {
    bool checkOrigin = true,
    bool retryOn502 = true,
  }) async {
    retries.add(retryOn502);
    try {
      return await func();
    } catch (error) {
      if (retryOn502 && error is Response && error.statusCode == 502) return func();
      rethrow;
    }
  }

  @override
  Future<Response> returnSuccessOrError(Response response) async {
    if (response.statusCode != 200) throw response;
    return response;
  }
}

class _Themes extends ThemesService {
  @override
  bool inDarkMode(BuildContext context) => false;
}

class _Folders extends StickerFolderService {
  int sends = 0;
  bool? sentNative;
  String? folder = 'content://test/tree/selected';
  @override
  Future<String?> currentFolder() async => folder;
  @override
  Future<String?> chooseFolder() async => null;
  @override
  Future<StickerFolderPage> list({required String uri, int offset = 0}) async => const StickerFolderPage(
    [
      StickerFolderEntry(uri: 'content://test/tree/selected/document/a', name: 'a.png', directory: false, size: 128),
      StickerFolderEntry(uri: 'content://test/tree/selected/document/pack', name: 'Pack', directory: true, size: 0),
    ],
    2,
    false,
  );
  @override
  Future<Uint8List> read(StickerFolderEntry entry, {String? requestId}) async =>
      Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
  @override
  Future<void> cancelRead(String requestId) async {}
  @override
  Future<void> send(Chat chat, StickerFolderEntry entry, {required bool nativeSticker}) async {
    sends++;
    sentNative = nativeSticker;
  }
}

class _DeferredFolders extends _Folders {
  final pending = <String, Completer<StickerFolderPage>>{};
  @override
  Future<StickerFolderPage> list({required String uri, int offset = 0}) =>
      (pending[uri] = Completer<StickerFolderPage>()).future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bluebubbles-native-sticker-test-');
    file = await File('${directory.path}/animated.gif').writeAsBytes([71, 73, 70, 56, 57, 97, 1, 2, 3]);
  });
  tearDown(() async {
    isIsolateOverride = false;
    await GetIt.I.reset();
    await directory.delete(recursive: true);
  });

  PlatformFile selected() => PlatformFile(name: 'animated.gif', path: file.path, size: 9);

  test('native form retains original bytes, auth and only standalone fields', () async {
    final api = _OfflineApi();
    await MessageApi(api).sendSticker('iMessage;-;chat', 'temp-stable', selected(), stickerLabel: 'Wave');
    expect(api.requests.map((r) => r.method), ['GET', 'POST']);
    final request = api.requests.last;
    expect(request.path, endsWith('/message/send-sticker'));
    expect(request.queryParameters, {'guid': 'test-auth'});
    expect(request.headers['test-header'], 'retained');
    final form = request.data as FormData;
    expect(Map.fromEntries(form.fields), {
      'chatGuid': 'iMessage;-;chat',
      'tempGuid': 'temp-stable',
      'name': 'animated.gif',
      'stickerLabel': 'Wave',
    });
    expect(form.files.single.key, 'attachment');
    final bytes = await form.files.single.value.finalize().expand((chunk) => chunk).toList();
    expect(bytes, await file.readAsBytes());
    expect(api.retries.first, false);
  });

  test('old, false, and non-boolean capability produce no sticker or photo POST', () async {
    for (final capability in [null, false, 'true', 1]) {
      final api = _OfflineApi(capability: capability);
      await expectLater(MessageApi(api).sendSticker('chat', 'temp', selected()), throwsUnsupportedError);
      expect(api.requests.map((r) => r.method), ['GET']);
    }
    expect(const ServerDetails.empty().supportsStickerSending, false);
  });

  test('ambiguous native failure has exactly one POST and no photo fallback', () async {
    final api = _OfflineApi(postStatus: 502);
    await expectLater(MessageApi(api).sendSticker('chat', 'temp', selected()), throwsA(isA<Response>()));
    expect(api.requests.where((r) => r.method == 'POST').length, 1);
    expect(api.requests.any((r) => r.path.endsWith('/message/attachment')), false);
  });

  test('interface and action retain the native endpoint and stable temp GUID in isolate context', () async {
    final api = _OfflineApi();
    GetIt.I.registerSingleton<HttpService>(HttpService()..message = MessageApi(api));
    isIsolateOverride = true;
    await SendMessageInterface.sendSticker(
      chatGuid: 'chat',
      tempGuid: 'temp-stable',
      filePath: file.path,
      fileName: 'animated.gif',
      fileSize: 9,
    );
    expect(Map.fromEntries((api.requests.last.data as FormData).fields)['tempGuid'], 'temp-stable');
    expect(api.requests.last.path, endsWith('/message/send-sticker'));
  });

  test('persisted attachment metadata retains native intent and blocks generic retry before mutations', () async {
    final original = StickerFolderService.buildAttachment(selected(), nativeSticker: true);
    final reloaded = Attachment.fromMap(original.toMap());
    expect(reloaded.metadata?['preserveOriginalBytes'], true);
    expect(reloaded.isSticker, true);
    final message = Message(guid: 'temp-original');
    final item = OutgoingAttachment(
      chat: Chat(guid: 'chat'),
      message: message,
      attachment: reloaded,
      isRetry: true,
    );
    expect(item.isNativeSticker, true);
    await expectLater(OutgoingMessageHandler().queue(item), throwsUnsupportedError);
    expect(message.guid, 'temp-original');
    final photo = StickerFolderService.buildAttachment(selected(), nativeSticker: false);
    expect(photo.metadata?['nativeStickerSend'], isNull);
    expect(photo.metadata?['preserveOriginalBytes'], true);
  });

  test('one-shot HTTP guard suppresses Cloudflare retry but regular requests still retry', () async {
    final settings = SettingsService()..settings = Settings();
    settings.settings.serverAddress.value = 'https://test.trycloudflare.invalid';
    GetIt.I.registerSingleton<SettingsService>(settings);
    final http = HttpService();
    GetIt.I.registerSingleton<HttpService>(http);
    var attempts = 0;
    Future<Response> fail() async {
      attempts++;
      throw Response(requestOptions: RequestOptions(), statusCode: 502);
    }

    await expectLater(http.runApiGuarded(fail, retryOn502: false), throwsA(isA<Response>()));
    expect(attempts, 1);
    attempts = 0;
    await expectLater(http.runApiGuarded(fail), throwsA(isA<Response>()));
    expect(attempts, 2);
  });

  test('SAF bridge preserves opaque tree URI and page cursor, handles cancellation and revoked grant', () async {
    const channel = MethodChannel('test-sticker-folder');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'choose-folder') return null;
      if (call.method == 'get-folder') throw PlatformException(code: 'folder-access', message: 'Choose again');
      return {'entries': [], 'nextOffset': 400, 'hasMore': true};
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const folders = StickerFolderService(channel: channel);
    expect(await folders.chooseFolder(), isNull);
    await expectLater(folders.currentFolder(), throwsA(isA<PlatformException>()));
    final page = await folders.list(
      uri: 'content://provider/tree/root%3AStickers/document/root%3AStickers%2FPack',
      offset: 200,
    );
    expect(calls.last.arguments, {
      'uri': 'content://provider/tree/root%3AStickers/document/root%3AStickers%2FPack',
      'offset': 200,
    });
    expect(page.nextOffset, 400);
    expect(page.hasMore, true);
  });

  test('thumbnail cancellation tolerates native teardown and missing channel', () async {
    const channel = MethodChannel('test-cancel-sticker-folder');
    const folders = StickerFolderService(channel: channel);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'closed');
    });
    await folders.cancelRead('thumbnail:1');
    expect(calls.single.arguments, {'requestId': 'thumbnail:1'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await folders.cancelRead('thumbnail:2');
  });

  test('two browsers for the same chat have independent controller lifetimes', () {
    final chat = Chat(guid: 'iMessage;-;chat');
    final first = StickerBrowserController(chat, _Folders());
    final second = StickerBrowserController(chat, _Folders());
    expect(first.tag, isNot(second.tag));
    first.onClose();
    expect(first.active, false);
    expect(second.active, true);
    second.onClose();
  });

  Future<void> harness(
    WidgetTester tester,
    _Folders folders, {
    required bool supported,
    String chatGuid = 'iMessage;-;chat',
  }) async {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<ThemesService>(_Themes());
    GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
    GetIt.I.registerSingleton<HttpService>(HttpService()..message = MessageApi(_OfflineApi(capability: supported)));
    await tester.pumpWidget(
      MaterialApp(
        home: StickerBrowser(
          chat: Chat(guid: chatGuid),
          folders: folders,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('selection defaults native and sends only after explicit Send', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: true);
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    expect(folders.sends, 0);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send sticker')).onPressed, isNotNull);
    await tester.tap(find.text('Send sticker'));
    await tester.pumpAndSettle();
    expect(folders.sends, 1);
    expect(folders.sentNative, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported native sends stay disabled, explicit image override works', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: false);
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send sticker')).onPressed, isNull);
    expect(folders.sends, 0);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send image'));
    await tester.pumpAndSettle();
    expect(folders.sentNative, false);
    await tester.pumpWidget(const SizedBox());
  });

  test('stale async folder responses and disposal cannot replace the current folder', () async {
    final folders = _DeferredFolders();
    final controller = StickerBrowserController(Chat(guid: 'iMessage;-;chat'), folders);
    controller.folder.value = 'old';
    final old = controller.load(reset: true);
    controller.folder.value = 'new';
    final current = controller.load(reset: true);
    const selected = StickerFolderEntry(uri: 'new/a', name: 'new.png', directory: false, size: 1);
    folders.pending['new']!.complete(const StickerFolderPage([selected], 1, false));
    await current;
    folders.pending['old']!.complete(const StickerFolderPage([], 0, false));
    await old;
    expect(controller.entries.single.name, 'new.png');
    controller.folder.value = 'disposed';
    final disposed = controller.load();
    controller.onClose();
    folders.pending['disposed']!.complete(const StickerFolderPage([], 0, true));
    await disposed;
    expect(controller.hasMore.value, false);
    expect(controller.entries.single.name, 'new.png');
  });

  testWidgets('normal image override and sticker send leave the unrelated composer draft intact', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: true);
    final browser = tester.widget<StickerBrowser>(find.byType(StickerBrowser)).parentController;
    final composer = ConversationViewController(browser.chat);
    composer.textController.text = 'Unsent text';
    composer.subjectTextController.text = 'Unsent subject';
    final attachment = PlatformFile(name: 'draft.png', path: '/unrelated/draft.png', size: 10);
    composer.pickedAttachments.add(attachment);
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send sticker'));
    await tester.pumpAndSettle();
    expect(composer.textController.text, 'Unsent text');
    expect(composer.subjectTextController.text, 'Unsent subject');
    expect(composer.pickedAttachments.single, same(attachment));
    await tester.pumpWidget(const SizedBox());
    composer.textController.dispose();
    composer.subjectTextController.dispose();
    composer.focusNode.dispose();
    composer.subjectFocusNode.dispose();
  });

  testWidgets('SMS native Send is disabled even when helper capability is true', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: true, chatGuid: 'SMS;-;chat');
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send sticker')).onPressed, isNull);
    expect(find.text('Native stickers require an iMessage conversation.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('subfolders stay separate and cancelling folder selection retains the current folder', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: true);
    final controller = tester.widget<StickerBrowser>(find.byType(StickerBrowser)).parentController;
    await tester.tap(find.byTooltip('Choose sticker folder'));
    await tester.pumpAndSettle();
    expect(controller.folder.value, folders.folder);
    await tester.tap(find.text('Pack'));
    await tester.pumpAndSettle();
    expect(controller.folder.value, endsWith('/document/pack'));
    expect(controller.parents.single.name, 'Pack');
    await tester.tap(find.text('Back to parent folder'));
    await tester.pumpAndSettle();
    expect(controller.folder.value, folders.folder);
    expect(controller.parents, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
