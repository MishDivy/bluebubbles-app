import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';
import 'package:bluebubbles/helpers/types/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/ui/reaction_helpers.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_icon.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_asset_image.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/isolates/global_isolate.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
  final Object? rowCapability;
  final requests = <RequestOptions>[];
  final retries = <bool>[];
  _OfflineApi({this.capability = true, this.rowCapability = false, this.postStatus = 200}) {
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
                  'privateApiCapabilities': {'stickerSending': capability, 'stickerRows': rowCapability},
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
  final rows = <List<StickerFolderEntry>>[];
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

  @override
  Future<void> sendRow(Chat chat, List<StickerFolderEntry> entries) async => rows.add(entries);
}

class _DeferredFolders extends _Folders {
  final pending = <String, Completer<StickerFolderPage>>{};
  @override
  Future<StickerFolderPage> list({required String uri, int offset = 0}) =>
      (pending[uri] = Completer<StickerFolderPage>()).future;
}

class _AttachmentBox implements Box<Attachment> {
  final attachments = <int, Attachment>{};
  @override
  Attachment? get(int id) => attachments[id];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DeferredAttachmentIsolate extends GlobalIsolate {
  final pending = Completer<int?>();
  int calls = 0;
  @override
  Future<T> send<T>(IsolateRequestType type, {dynamic input, Duration? customTimeout}) async {
    expect(type, IsolateRequestType.findOneAttachmentAsync);
    calls++;
    return (await pending.future) as T;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final attachmentBox = _AttachmentBox();
  setUpAll(() => Database.attachments = attachmentBox);
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

  test('row uses one ordered multipart request and never retries 502', () async {
    final api = _OfflineApi(rowCapability: true, postStatus: 502);
    await expectLater(
      MessageApi(api).sendStickerRow('chat', 'temp-row', [selected(), selected()], stickerLabels: ['First', null]),
      throwsA(isA<Response>()),
    );
    final posts = api.requests.where((request) => request.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.path, endsWith('/message/send-sticker-row'));
    final form = posts.single.data as FormData;
    expect(form.files.map((file) => file.key), ['attachment0', 'attachment1']);
    expect(jsonDecode(form.fields.singleWhere((entry) => entry.key == 'stickers').value), [
      {'name': 'animated.gif', 'stickerLabel': 'First'},
      {'name': 'animated.gif'},
    ]);
    expect(form.fields.map((field) => field.key), ['chatGuid', 'tempGuid', 'stickers']);
    expect(api.retries.where((retry) => !retry), hasLength(1));
  });

  test('row capability is explicit and independent of single sending', () async {
    for (final capability in [false, null, 'true', 1]) {
      final api = _OfflineApi(capability: true, rowCapability: capability);
      await expectLater(
        MessageApi(api).sendStickerRow('chat', 'temp-row', [selected(), selected()]),
        throwsA(isA<UnsupportedError>()),
      );
      expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    }
  });

  test('observed three all-part-zero emoji runs retain transfer order and no placeholders', () {
    final assets = ['C', 'A', 'B'].map((guid) => Attachment(guid: guid, mimeType: 'image/png')).toList();
    final body = AttributedBody.fromMap({
      'string': '\uFFFC\uFFFC\uFFFC',
      'runs': [
        for (var i = 0; i < 3; i++)
          {
            'range': [i, 1],
            'attributes': {
              '__kIMMessagePartAttributeName': 0,
              '__kIMFileTransferGUIDAttributeName': ['A', 'B', 'C'][i],
              '__kIMEmojiImageAttributeName': 1,
            },
          },
      ],
    });
    final parts = StickerHelper.attributedParts(AttributedBody.fromMap(body.toMap()), assets);
    expect(parts, hasLength(1));
    expect(parts.single.part, 0);
    expect(parts.single.attachments.map((attachment) => attachment.guid), ['A', 'B', 'C']);
    expect(parts.single.text, isNull);
    expect(parts.single.isInlineSticker, isTrue);
    expect(parts.single.isMediaGallery, isFalse);
    expect(parts.single.isMediaOnlyPart, isFalse);
  });

  test('row fallback requires exact indexed metadata, not database order', () {
    final assets = [2, 0, 1]
        .map(
          (i) => Attachment(
            guid: 'asset-$i',
            metadata: {
              'sticker': {
                'row': {'index': i, 'count': 3, 'partIndex': 0},
              },
            },
          ),
        )
        .toList();
    expect(StickerHelper.rowAttachments(assets)!.map((attachment) => attachment.guid), [
      'asset-0',
      'asset-1',
      'asset-2',
    ]);
    assets.first.metadata = {
      'stickerRow': {'index': 0, 'count': 3, 'partIndex': 0},
    };
    expect(StickerHelper.rowAttachments(assets), isNull);
  });

  test('one confirmation reconciles exactly the ordered row assets, including duplicate names', () {
    final data = {
      'stickerLayout': {
        'attachmentGuids': ['A', 'B'],
        'partIndex': 0,
      },
      'attachments': [
        {'guid': 'B', 'transferName': 'same.png', 'mimeType': null, 'metadata': null, 'dateCreated': null},
        {'guid': 'A', 'transferName': 'same.png', 'mimeType': null, 'metadata': null, 'dateCreated': null},
      ],
    };
    final ordered = StickerHelper.confirmedRowAttachments(data, 2);
    expect(ordered.map((attachment) => attachment.guid), ['A', 'B']);
    expect(StickerHelper.rowAttachments(ordered), ordered);
    expect(() => StickerHelper.confirmedRowAttachments(data, 3), throwsStateError);
    expect(
      () => StickerHelper.confirmedRowAttachments({
        'stickerLayout': {
          'attachmentGuids': ['A', 'A'],
          'partIndex': 0,
        },
        'attachments': data['attachments'],
      }, 2),
      throwsStateError,
    );
    expect(
      () => StickerHelper.confirmedRowAttachments({
        'stickerLayout': {
          'attachmentGuids': ['A', 'missing'],
          'partIndex': 0,
        },
        'attachments': data['attachments'],
      }, 2),
      throwsStateError,
    );
  });

  test('malformed and text-plus-sticker runs keep text separate from object placeholders', () {
    final body = AttributedBody(
      string: 'Hi\uFFFC!',
      runs: [
        Run(range: [-1, 3], attributes: Attributes(messagePart: 0)),
        Run(range: [0, 2], attributes: Attributes(messagePart: 0)),
        Run(
          range: [2, 1],
          attributes: Attributes(messagePart: 0, attachmentGuid: 'A', emojiImage: true),
        ),
        Run(range: [3, 1], attributes: Attributes(messagePart: 0)),
        Run(range: [4, 900], attributes: Attributes(messagePart: 0)),
      ],
    );
    final part = StickerHelper.attributedParts(body, [Attachment(guid: 'A')]).single;
    expect(part.text, 'Hi!');
    expect(part.attachments.single.guid, 'A');
    expect(part.isInlineSticker, isTrue);
  });

  test('ordinary image and mention runs retain their part semantics', () {
    final part = StickerHelper.attributedParts(
      AttributedBody(
        string: 'Joe\uFFFC',
        runs: [
          Run(
            range: [0, 3],
            attributes: Attributes(messagePart: 0, mention: 'joe@example.invalid'),
          ),
          Run(
            range: [3, 1],
            attributes: Attributes(messagePart: 1, attachmentGuid: 'photo'),
          ),
        ],
      ),
      [Attachment(guid: 'photo', mimeType: 'image/jpeg')],
    );
    expect(part, hasLength(2));
    expect(part.first.text, 'Joe');
    expect(part.first.mentions.single.range, [0, 3]);
    expect(part.last.attachments.single.guid, 'photo');
    expect(part.last.isInlineSticker, isFalse);
    expect(part.last.isMediaOnlyPart, isTrue);
  });

  test('socket-first row mapping confirms exact N assets independent of both database orders', () {
    List<Attachment> row(List<int> order, String prefix) => order
        .map(
          (i) => Attachment(
            guid: '$prefix-$i',
            metadata: {
              'stickerRow': {'index': i, 'count': 3, 'partIndex': 0},
            },
          ),
        )
        .toList();
    final before = row([2, 0, 1], 'temp');
    final after = row([1, 2, 0], 'real');
    expect(StickerHelper.rowReplacementGuids(before, after), {
      'real-0': 'temp-0',
      'real-1': 'temp-1',
      'real-2': 'temp-2',
    });
    expect(StickerHelper.rowReplacementGuids(after, after.reversed.toList()), {
      'real-0': 'real-0', 'real-1': 'real-1', 'real-2': 'real-2',
    });
    expect(() => StickerHelper.rowReplacementGuids(before, after.take(2).toList()), throwsStateError);
  });

  test('missing cached attachment hydrates asynchronously once and disposal ignores late results', () async {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<ChatsService>(ChatsService());
    final isolate = _DeferredAttachmentIsolate();
    GetIt.I.registerSingleton<GlobalIsolate>(isolate);
    final body = AttributedBody(
      string: '\uFFFC',
      runs: [
        Run(
          range: [0, 1],
          attributes: Attributes(messagePart: 0, attachmentGuid: 'late', emojiImage: true),
        ),
      ],
    );
    final state = MessageState(Message(guid: 'parent', isFromMe: true, attributedBody: [body]));
    expect(state.attributedBodyToMessagePart(body).single.attachments, isEmpty);
    expect(state.attributedBodyToMessagePart(body).single.attachments, isEmpty);
    expect(isolate.calls, 1);
    attachmentBox.attachments[7] = Attachment(id: 7, guid: 'late');
    isolate.pending.complete(7);
    await Future<void>.delayed(Duration.zero);
    expect(state.parts.single.attachments.single.guid, 'late');
    expect(state.parts.single.attachments.single.isSticker, isTrue);
    state.onClose();

    await GetIt.I.unregister<GlobalIsolate>();
    final lateIsolate = _DeferredAttachmentIsolate();
    GetIt.I.registerSingleton<GlobalIsolate>(lateIsolate);
    final disposed = MessageState(Message(guid: 'disposed', isFromMe: true, attributedBody: [body]));
    disposed.attributedBodyToMessagePart(body);
    disposed.onClose();
    lateIsolate.pending.complete(7);
    await Future<void>.delayed(Duration.zero);
    expect(disposed.parts, isEmpty);
  });

  testWidgets('sticker tapback renders original artwork rather than the emoji fallback', (tester) async {
    final attachment = Attachment(
      guid: 'synthetic-sticker',
      bytes: Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2))),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 30,
          height: 30,
          child: ReactionIcon(type: 'sticker-reaction', color: Colors.white, attachment: attachment),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(StickerAssetImage), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('💬'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('ordered multi-selection toggles, caps at ten, requires rows support and sends once', () async {
    final folders = _Folders();
    final controller = StickerBrowserController(Chat(guid: 'iMessage;-;chat'), folders);
    final entries = List.generate(
      11,
      (i) => StickerFolderEntry(uri: 'sticker-$i', name: '$i.png', directory: false, size: 1),
    );
    controller.supported.value = true;
    controller.select(entries[1]);
    controller.select(entries[0]);
    expect(controller.selection.map((entry) => entry.uri), ['sticker-1', 'sticker-0']);
    await controller.send();
    expect(folders.rows, isEmpty);
    controller.select(entries[1]);
    expect(controller.selection.single.uri, 'sticker-0');
    for (final entry in entries.skip(1)) {
      controller.select(entry);
    }
    expect(controller.selection, hasLength(10));
    controller.rowSupported.value = true;
    expect(folders.rows, isEmpty);
    await controller.send();
    expect(folders.rows, hasLength(1));
    expect(folders.rows.single, hasLength(10));
    expect(folders.sends, 0);
    expect(controller.selection, isEmpty);
    controller.onClose();
  });

  test('partial row staging failure cleans only its prepared originals', () async {
    const channel = MethodChannel('test-partial-sticker-row');
    final staged = await File('${directory.path}/staged.gif').writeAsBytes([1, 2, 3]);
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'stage-sticker');
      calls++;
      if (calls == 2) throw PlatformException(code: 'revoked', message: 'Folder access was revoked.');
      return {'path': staged.path, 'name': 'staged.gif', 'size': 3};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await expectLater(const StickerFolderService(channel: channel).sendRow(Chat(guid: 'chat'), [
      const StickerFolderEntry(uri: 'one', name: 'one.gif', directory: false, size: 3),
      const StickerFolderEntry(uri: 'two', name: 'two.gif', directory: false, size: 3),
    ]), throwsA(isA<PlatformException>()));
    expect(calls, 2);
    expect(await staged.exists(), isFalse);
    expect(await file.exists(), isTrue);
  });

  test('row intent survives serialization with distinct asset and message GUIDs', () {
    final item = OutgoingStickerRow(
      chat: Chat(guid: 'chat'),
      message: Message(guid: 'temp-row'),
      attachments: [
        StickerFolderService.buildAttachment(selected(), nativeSticker: false),
        StickerFolderService.buildAttachment(selected(), nativeSticker: false),
      ],
    );
    item.ensureAttachmentGuids();
    expect(item.attachments.map((attachment) => attachment.guid).toSet(), hasLength(2));
    expect(item.attachments.every((attachment) => attachment.guid != item.message.guid), isTrue);
    for (final attachment in item.attachments) {
      final metadata = jsonDecode(attachment.toMap()['metadata']);
      expect(metadata['nativeStickerRowSend'], isTrue);
      expect(metadata['preserveOriginalBytes'], isTrue);
    }
    expect(StickerHelper.rowAttachments(item.attachments), hasLength(2));
    expect(jsonDecode(item.message.toMap()['metadata'])['nativeStickerRowSend'], isTrue);
  });

  test('local placement hiding is bounded, deduplicated and scoped to server and chat', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    final service = SharedPreferencesService();
    // Use the same categorized helper with an isolated in-memory cache.
    // ignore: deprecated_member_use_from_same_package
    service.i = await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions());
    final prefs = SharedPreferencesMessagingActions(service);
    await prefs.hideStickerPlacement('server-a', 'chat-a', 'placement');
    await prefs.hideStickerPlacement('server-a', 'chat-a', 'placement');
    expect(prefs.isStickerPlacementHidden('server-a', 'chat-a', 'placement'), isTrue);
    expect(prefs.isStickerPlacementHidden('server-b', 'chat-a', 'placement'), isFalse);
    expect(prefs.isStickerPlacementHidden('server-a', 'chat-b', 'placement'), isFalse);
    for (var i = 0; i < 1000; i++) {
      await prefs.hideStickerPlacement('server-a', 'chat-a', 'placement-$i');
    }
    expect(prefs.isStickerPlacementHidden('server-a', 'chat-a', 'placement'), isFalse);
    expect(prefs.isStickerPlacementHidden('server-a', 'chat-a', 'placement-999'), isTrue);
  });

  test('placements keep independent GUIDs while sticker tapbacks occupy actor slots', () {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    Message associated(String guid, String type, int time) => Message(
      guid: guid,
      isFromMe: true,
      associatedMessageGuid: 'parent',
      associatedMessageType: type,
      associatedMessagePart: 0,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(time),
    );
    final first = associated('placement-1', 'sticker', 1);
    final second = associated('placement-2', 'sticker', 2);
    first.metadata = {'sticker': {'placement': {'sir': false, 'spv': 0}}};
    second.metadata = {'sticker': {'placement': {'sir': true, 'spv': 0}}};
    expect(ReactionTypes.fromServer(1000, null), 'sticker');
    expect(ReactionTypes.isReaction(first.associatedMessageType), isFalse);
    expect(ReactionTypes.isReaction(second.associatedMessageType), isFalse);
    final state = MessageState(Message(guid: 'parent', isFromMe: true));
    state.addAssociatedMessageInternal(associated('temp-placement', 'sticker', 0));
    state.addAssociatedMessageInternal(first);
    state.addAssociatedMessageInternal(second);
    expect(state.associatedMessages, hasLength(3));
    expect(MessageHelper.normalizedAssociatedMessages([first, second, first]), hasLength(2));
    expect(
      getUniqueReactionMessages([
        first,
        second,
        associated('sticker-slot', 'sticker-reaction', 3),
        associated('classic-slot', 'love', 4),
      ]).map((message) => message.guid),
      ['classic-slot'],
    );
    expect(
      getUniqueReactionMessages([
        associated('sticker-slot', 'sticker-reaction', 3),
        associated('remove-slot', '-sticker-reaction', 4),
      ]),
      isEmpty,
    );
    state.removeAssociatedMessageInternal(first);
    expect(state.associatedMessages.map((message) => message.guid), ['temp-placement', 'placement-2']);
  });

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
