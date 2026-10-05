import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/env.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';
import 'package:bluebubbles/services/backend/interfaces/send_message_interface.dart';
import 'package:bluebubbles/services/backend/outgoing_message_handler.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

class _Api implements BaseApi {
  Object? composition = true;
  int status = 200;
  bool switchAfterCapabilities = false;
  bool switchAfterPost = false;
  bool timeoutPost = false;
  String originValue = 'https://offline.invalid';
  final requests = <RequestOptions>[];
  final retries = <bool>[];
  @override
  final dio = Dio();
  _Api() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          if (request.method == 'GET' && switchAfterCapabilities) originValue = 'https://other.invalid';
          if (request.method == 'POST' && switchAfterPost) originValue = 'https://other.invalid';
          if (request.method == 'POST' && timeoutPost) {
            handler.reject(DioException(requestOptions: request, type: DioExceptionType.receiveTimeout));
            return;
          }
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: request.method == 'GET' ? 200 : status,
              data: {
                'data': {
                  'privateApiCapabilities': {
                    'stickerSending': true,
                    'stickerRows': true,
                    'stickerComposition': composition,
                  },
                },
              },
            ),
          );
        },
      ),
    );
  }
  @override
  String get origin => originValue;
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
    return func();
  }

  @override
  Future<Response> returnSuccessOrError(Response response) async {
    if (response.statusCode != 200) throw response;
    return response;
  }
}

Map<String, dynamic> _confirmation() => jsonDecode(
  jsonEncode({
    'guid': 'native-message',
    'isFromMe': true,
    'error': 0,
    'attributedBody': [
      {
        'string': 'a\uFFFC\n\uFFFCb',
        // Unsorted runs and reverse DB attachment order must not change marker order.
        'runs': [
          {
            'range': [4, 1],
            'attributes': {'__kIMMessagePartAttributeName': 7},
          },
          {
            'range': [3, 1],
            'attributes': {
              '__kIMMessagePartAttributeName': 7,
              '__kIMFileTransferGUIDAttributeName': 'B',
              '__kIMEmojiImageAttributeName': 1,
            },
          },
          {
            'range': [0, 1],
            'attributes': {'__kIMMessagePartAttributeName': 2},
          },
          {
            'range': [1, 1],
            'attributes': {
              '__kIMMessagePartAttributeName': 2,
              '__kIMFileTransferGUIDAttributeName': 'A',
              '__kIMEmojiImageAttributeName': 1,
            },
          },
          {
            'range': [2, 1],
            'attributes': {'__kIMMessagePartAttributeName': 2},
          },
        ],
      },
    ],
    'attachments': [
      for (final guid in ['B', 'A']) {'guid': guid, 'isSticker': true, 'mimeType': 'image/png'},
    ],
    'stickerComposition': {
      'attachmentGuids': ['A', 'B'],
      'parts': [
        {
          'range': [1, 1],
          'partIndex': 2,
        },
        {
          'range': [3, 1],
          'partIndex': 7,
        },
      ],
    },
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PlatformFile asset;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sticker-composition-');
    final file = await File('${directory.path}/source.png').writeAsBytes([1, 2, 3]);
    asset = PlatformFile(name: 'source.png', path: file.path, size: 3);
  });
  tearDown(() async {
    isIsolateOverride = false;
    await GetIt.I.reset();
    await directory.delete(recursive: true);
  });

  test('interface and action preserve composition text and immutable origin across the isolate boundary', () async {
    final api = _Api();
    GetIt.I.registerSingleton<HttpService>(HttpService()..message = MessageApi(api));
    isIsolateOverride = true;
    await SendMessageInterface.sendStickerRow(
      chatGuid: 'iMessage;-;self',
      tempGuid: 'temp-one',
      files: [asset],
      text: 'before\uFFFCafter',
      expectedOrigin: api.origin,
    );
    final form = api.requests.last.data as FormData;
    expect(Map.fromEntries(form.fields)['text'], 'before\uFFFCafter');
    api.requests.clear();
    await expectLater(
      SendMessageInterface.sendStickerRow(
        chatGuid: 'iMessage;-;self',
        tempGuid: 'temp-other',
        files: [asset],
        text: '\uFFFC',
        expectedOrigin: 'https://other.invalid',
      ),
      throwsStateError,
    );
    expect(api.requests, isEmpty);
  });

  test('standalone isolate action preserves draft origin without adding new wire fields', () async {
    final api = _Api();
    GetIt.I.registerSingleton<HttpService>(HttpService()..message = MessageApi(api));
    isIsolateOverride = true;
    await expectLater(
      SendMessageInterface.sendSticker(
        chatGuid: 'iMessage;-;self',
        tempGuid: 'temp-one',
        filePath: asset.path!,
        fileName: asset.name,
        fileSize: asset.size,
        expectedOrigin: 'https://other.invalid',
      ),
      throwsStateError,
    );
    expect(api.requests, isEmpty);
  });

  test('composition uses one authenticated ordered request preserving exact text and disables resend', () async {
    final api = _Api()..status = 502;
    const text = ' a\uFFFC\n\uFFFC ';
    await expectLater(
      MessageApi(
        api,
      ).sendStickerRow('iMessage;-;self', 'temp-one', [asset, asset], text: text, expectedOrigin: api.origin),
      throwsA(isA<Response>()),
    );
    final posts = api.requests.where((request) => request.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect(posts.single.queryParameters['guid'], 'test-auth');
    final form = posts.single.data as FormData;
    expect(form.fields.singleWhere((field) => field.key == 'text').value, text);
    expect(form.files.map((file) => file.key), ['attachment0', 'attachment1']);
    expect(jsonDecode(form.fields.singleWhere((field) => field.key == 'stickers').value), [
      {'name': 'source.png'},
      {'name': 'source.png'},
    ]);
    expect(api.retries.where((retry) => !retry), [false]);
  });

  test('composition capability is independent and missing or nonboolean values fail before POST', () async {
    for (final value in [false, null, 1, 'true']) {
      final api = _Api()..composition = value;
      await expectLater(
        MessageApi(
          api,
        ).sendStickerRow('iMessage;-;self', 'temp-one', [asset], text: '\uFFFC', expectedOrigin: api.origin),
        throwsUnsupportedError,
      );
      expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    }
  });

  test('original origin is checked before negotiation and again before upload', () async {
    for (final changedDuring in [false, true]) {
      final api = _Api()..switchAfterCapabilities = changedDuring;
      await expectLater(
        MessageApi(api).sendStickerRow(
          'iMessage;-;self',
          'temp-one',
          [asset],
          text: '\uFFFC',
          expectedOrigin: changedDuring ? api.origin : 'https://other.invalid',
        ),
        throwsStateError,
      );
      expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    }
    final api = _Api();
    await expectLater(
      MessageApi(api).sendSticker('iMessage;-;self', 'temp-one', asset, expectedOrigin: 'https://other.invalid'),
      throwsStateError,
    );
    expect(api.requests, isEmpty);
  });

  test('text markers Unicode and combined byte limits fail before any request', () async {
    for (final text in ['missing', '\uFFFC\uFFFC', '\uD800\uFFFC', '\uDC00\uFFFC', '${'a' * 4096}\uFFFC']) {
      final api = _Api();
      await expectLater(
        MessageApi(api).sendStickerRow('iMessage;-;self', 'temp-one', [asset], text: text, expectedOrigin: api.origin),
        throwsArgumentError,
      );
      expect(api.requests, isEmpty);
    }
    final api = _Api();
    await expectLater(
      MessageApi(
        api,
      ).sendStickerRow('iMessage;-;self', 'temp-one', [asset], text: '${'界' * 3000}\uFFFC', expectedOrigin: api.origin),
      throwsArgumentError,
    );
    expect(api.requests, isEmpty);
    expect(() => StickerHelper.validateCompositionText('\u{1F600}\uFFFC', 1), returnsNormally);
  });

  test('timeout and origin switch after dispatch remain unknown with only one POST', () async {
    for (final timeout in [true, false]) {
      final api = _Api()
        ..timeoutPost = timeout
        ..switchAfterPost = !timeout;
      await expectLater(
        MessageApi(
          api,
        ).sendStickerRow('iMessage;-;self', 'temp-one', [asset], text: '\uFFFC', expectedOrigin: api.origin),
        timeout ? throwsA(isA<DioException>()) : throwsStateError,
      );
      expect(api.requests.where((request) => request.method == 'POST'), hasLength(1));
    }
    final api = _Api()..switchAfterPost = true;
    await expectLater(
      MessageApi(api).sendSticker('iMessage;-;self', 'temp-one', asset, expectedOrigin: api.origin),
      throwsStateError,
    );
    expect(api.requests.where((request) => request.method == 'POST'), hasLength(1));
  });

  test('composition upload bytes are bounded before a request', () async {
    final api = _Api();
    await expectLater(
      MessageApi(api).sendStickerRow(
        'iMessage;-;self',
        'temp-one',
        [PlatformFile(name: asset.name, path: asset.path, size: 500 * 1024 + 1)],
        text: '\uFFFC',
        expectedOrigin: api.origin,
      ),
      throwsArgumentError,
    );
    expect(api.requests, isEmpty);
  });

  test('full body validates actual sorted ranges parts and distinct GUIDs instead of filenames or DB order', () {
    final confirmed = StickerHelper.confirmedCompositionAttachments(_confirmation(), 'a\uFFFC\n\uFFFCb', 2);
    expect(confirmed.map((attachment) => attachment.guid), ['A', 'B']);
    expect(confirmed.map((attachment) => attachment.metadata?['stickerCompositionIndex']), [0, 1]);
    expect(confirmed.any((attachment) => attachment.metadata?['stickerRow'] != null), false);
  });

  test('incomplete overlapping or unlinked body and lying response hints are rejected', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (data) => data.remove('attributedBody'),
      (data) => data['attributedBody'][0]['string'] = 'different',
      (data) => data['attributedBody'][0]['runs'].removeLast(),
      (data) => data['attributedBody'][0]['runs'][0]['range'] = [3, 1],
      (data) => data['attributedBody'][0]['runs'][2]['attributes']['__kIMMessagePartAttributeName'] = 1.5,
      (data) => data['attributedBody'][0]['runs'][1]['attributes']['__kIMEmojiImageAttributeName'] = true,
      (data) => data['attributedBody'][0]['runs'][1]['attributes'].remove('__kIMFileTransferGUIDAttributeName'),
      (data) => data['attributedBody'][0]['runs'][1]['attributes']['__kIMFileTransferGUIDAttributeName'] = 'A',
      (data) => data['stickerComposition']['attachmentGuids'] = ['B', 'A'],
      (data) => data['stickerComposition']['parts'][0]['partIndex'] = 0,
      (data) => data['stickerComposition']['parts'][0]['range'] = [1.0, 1],
      (data) => data['attachments'][0]['isSticker'] = false,
      (data) => data['isFromMe'] = false,
      (data) => data['error'] = 1,
      (data) => data['associatedMessageGuid'] = 'parent',
    ];
    for (final mutate in mutations) {
      final data = _confirmation();
      mutate(data);
      expect(() => StickerHelper.confirmedCompositionAttachments(data, 'a\uFFFC\n\uFFFCb', 2), throwsStateError);
    }
  });

  test('socket-first and failed unknown attempts remain pending until verified HTTP', () async {
    final item = OutgoingStickerRow(
      chat: Chat(guid: 'iMessage;-;self'),
      message: Message(guid: 'temp-one'),
      attachments: [Attachment(guid: 'temp-asset')],
      compositionText: '\uFFFC',
      serverIdentity: 'https://offline.invalid',
      isRetry: true,
    );
    item.ensureAttachmentGuids();
    expect(StickerHelper.awaitsCompositionHttp(item.message), true);
    final loaded = Message.fromMap(item.message.toMap());
    expect(loaded.metadata?['nativeStickerCompositionText'], '\uFFFC');
    loaded.guid = 'error-one';
    expect(StickerHelper.awaitsCompositionHttp(loaded), true);
    await expectLater(OutgoingMessageHandler().queue(item), throwsUnsupportedError);
    expect(item.message.guid, 'temp-one');
    expect(item.attachments.single.metadata?['stickerRow'], isNull);
    expect(item.attachments.single.metadata?['preserveOriginalBytes'], true);
  });

  test('confirmed socket body can update only the already verified native assets', () {
    final data = _confirmation();
    final existing = Message(
      guid: 'native-message',
      metadata: {'nativeStickerCompositionSend': true, 'nativeStickerCompositionText': 'a\uFFFC\n\uFFFCb'},
    );
    existing.dbAttachments.addAll(StickerHelper.confirmedCompositionAttachments(data, 'a\uFFFC\n\uFFFCb', 2));
    final replacement = Message.fromMap(data);
    final incoming = (data['attachments'] as List).map((raw) => Attachment.fromMap(raw)).toList();
    expect(StickerHelper.compositionReplacementGuids(existing, replacement, incoming), {'A': 'A', 'B': 'B'});
    replacement.attributedBody.clear();
    expect(() => StickerHelper.compositionReplacementGuids(existing, replacement, incoming), throwsStateError);
  });

  test('composition intent rejects reply effect and subject without changing ordinary queue types', () {
    for (final message in [
      Message(threadOriginatorGuid: 'parent'),
      Message(associatedMessageGuid: 'parent'),
      Message(expressiveSendStyleId: 'effect'),
      Message(subject: 'subject'),
    ]) {
      expect(
        () => OutgoingStickerRow(
          chat: Chat(guid: 'iMessage;-;self'),
          message: message,
          attachments: [Attachment()],
          compositionText: '\uFFFC',
          serverIdentity: 'https://offline.invalid',
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => OutgoingStickerRow(
        chat: Chat(guid: 'iMessage;-;self'),
        message: Message(subject: 'legacy'),
        attachments: [Attachment(), Attachment()],
      ),
      returnsNormally,
    );
  });

  test('reduced receipt keeps the verified body and text even when it carries stale or malformed runs', () {
    final existing = Message.fromMap(_confirmation());
    final receipt = Message(
      guid: existing.guid,
      text: 'stale text',
      attributedBody: [
        AttributedBody(
          string: 'stale\uFFFC',
          runs: [
            Run(range: [-1, 100]),
          ],
        ),
      ],
    );
    StickerHelper.retainCompositionReceiptBody(existing, receipt);
    expect(receipt.text, existing.text);
    expect(receipt.attributedBody.single.string, 'a\uFFFC\n\uFFFCb');
    expect(receipt.attributedBody.single.toMap(), existing.attributedBody.single.toMap());
    receipt.attributedBody.clear();
    expect(existing.attributedBody, hasLength(1));
  });
}
