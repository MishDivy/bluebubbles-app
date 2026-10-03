import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_target_preview.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_placement_editor.dart';
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
  final Object? placementCapability;
  final Object? reactionsCapability;
  String originValue = 'https://offline.trycloudflare.invalid';
  final requests = <RequestOptions>[];
  final retries = <bool>[];
  _OfflineApi({
    this.capability = true,
    this.rowCapability = false,
    this.placementCapability = false,
    this.reactionsCapability = false,
    this.postStatus = 200,
  }) {
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
                  'privateApiCapabilities': {
                    'stickerSending': capability,
                    'stickerRows': rowCapability,
                    'stickerPlacement': placementCapability,
                    'stickerReactions': reactionsCapability,
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
  final dio = Dio();
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
  final targets = <NativeStickerTarget>[];
  final placements = <StickerPlacement?>[];
  Completer<void>? targetPending;
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

  @override
  Future<void> sendTargeted(
    Chat chat,
    StickerFolderEntry entry,
    NativeStickerTarget target, {
    StickerPlacement? placement,
    bool Function()? canQueue,
  }) async {
    if (targetPending != null) await targetPending!.future;
    if (canQueue?.call() == false) return;
    targets.add(target);
    placements.add(placement);
  }
}

class _DeferredFolders extends _Folders {
  final pending = <String, Completer<StickerFolderPage>>{};
  @override
  Future<StickerFolderPage> list({required String uri, int offset = 0}) =>
      (pending[uri] = Completer<StickerFolderPage>()).future;
}

class _SwitchingFile implements File {
  final File file;
  final void Function() onLength;
  _SwitchingFile(this.file, this.onLength);
  @override
  Future<int> length() async {
    final value = await file.length();
    onLength();
    return value;
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) => file.openRead(start, end);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
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

  NativeStickerTarget target(NativeStickerOperation operation, {int part = 7, String? reactionGuid}) =>
      NativeStickerTarget(
        serverIdentity: 'https://offline.trycloudflare.invalid',
        chatGuid: 'iMessage;-;chat',
        messageGuid: 'parent-guid',
        partIndex: part,
        operation: operation,
        reactionGuid: reactionGuid,
      );

  StickerPlacement geometry() => StickerPlacement(x: 0.5, y: 0.75, scale: 1.2, rotation: math.pi / 2, parentWidth: 240);

  test('immutable target intent rejects transient targets and unrelated removal IDs', () {
    final value = target(NativeStickerOperation.removeTapback, reactionGuid: 'current-2007');
    expect(NativeStickerTarget.fromMap(jsonDecode(jsonEncode(value.toMap()))).reactionGuid, 'current-2007');
    expect(() => target(NativeStickerOperation.tapback, reactionGuid: 'unrelated'), throwsArgumentError);
    expect(() => target(NativeStickerOperation.removeTapback), throwsArgumentError);
    expect(() => target(NativeStickerOperation.removeTapback, reactionGuid: 'temp-reaction'), throwsArgumentError);
    expect(() => target(NativeStickerOperation.placement, part: -1), throwsArgumentError);
    expect(() => NativeStickerTarget.fromMap({...value.toMap(), 'operation': 'sendAttachment'}), throwsArgumentError);
  });

  test('placement bounds accept finite native units and retain measured parent width', () {
    final value = geometry();
    expect(StickerPlacement.fromMap(jsonDecode(jsonEncode(value.toMap()))).toMap(), value.toMap());
    expect(value.copyWith(x: -4, y: 4, scale: 0.01, rotation: -2 * math.pi).parentWidth, 240);
    for (final field in ['x', 'y', 'scale', 'rotation', 'parentWidth']) {
      for (final invalid in [double.nan, double.infinity, double.negativeInfinity, true, '1']) {
        expect(() => StickerPlacement.fromMap({...value.toMap(), field: invalid}), throwsA(anything));
      }
    }
    expect(() => value.copyWith(x: 4.001), throwsArgumentError);
    expect(() => value.copyWith(scale: 0), throwsArgumentError);
    expect(() => value.copyWith(rotation: 2 * math.pi + 0.01), throwsArgumentError);
    expect(() => StickerPlacement.fromMap({...value.toMap(), 'parentWidth': 4097}), throwsArgumentError);
  });

  test('placement and tapback upload original bytes to distinct one-shot endpoints', () async {
    for (final operation in [NativeStickerOperation.placement, NativeStickerOperation.tapback]) {
      final api = _OfflineApi(placementCapability: true, reactionsCapability: true, postStatus: 502);
      await expectLater(
        MessageApi(api).sendTargetedSticker(
          target(operation),
          'temp-one-operation',
          file: selected(),
          placement: operation == NativeStickerOperation.placement ? geometry() : null,
          stickerLabel: 'Animated',
        ),
        throwsA(isA<Response>()),
      );
      final posts = api.requests.where((request) => request.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.path, endsWith('/message/${target(operation).endpoint}'));
      expect(posts.single.queryParameters, {'guid': 'test-auth'});
      final form = posts.single.data as FormData;
      final fields = Map.fromEntries(form.fields);
      expect(fields['tempGuid'], 'temp-one-operation');
      expect(fields['selectedMessageGuid'], 'parent-guid');
      expect(fields['partIndex'], '7');
      expect(fields['name'], 'animated.gif');
      expect(fields.containsKey('reactionGuid'), false);
      expect(fields.containsKey('placement'), operation == NativeStickerOperation.placement);
      if (operation == NativeStickerOperation.placement) expect(jsonDecode(fields['placement']!), geometry().toMap());
      expect(form.files.single.key, 'attachment');
      expect(await form.files.single.value.finalize().expand((chunk) => chunk).toList(), await file.readAsBytes());
      expect(api.retries.where((retry) => !retry), hasLength(1));
      expect(posts.any((request) => request.path.endsWith('/message/attachment')), false);
    }
  });

  test('removal sends JSON with current reaction GUID and no new artwork', () async {
    final api = _OfflineApi(reactionsCapability: true);
    await MessageApi(
      api,
    ).sendTargetedSticker(target(NativeStickerOperation.removeTapback, reactionGuid: 'current-2007'), 'temp-remove');
    final post = api.requests.last;
    expect(post.path, endsWith('/message/remove-sticker-tapback'));
    expect(post.data, {
      'chatGuid': 'iMessage;-;chat',
      'tempGuid': 'temp-remove',
      'selectedMessageGuid': 'parent-guid',
      'partIndex': 7,
      'reactionGuid': 'current-2007',
    });
    await expectLater(
      MessageApi(api).sendTargetedSticker(target(NativeStickerOperation.tapback), 'temp-no-asset'),
      throwsArgumentError,
    );
  });

  test('per-operation capability and server identity fail closed before any native POST', () async {
    for (final operation in NativeStickerOperation.values) {
      for (final capability in [false, null, 'true', 1]) {
        final api = _OfflineApi(capability: true, placementCapability: capability, reactionsCapability: capability);
        await expectLater(
          MessageApi(api).sendTargetedSticker(
            target(operation, reactionGuid: operation == NativeStickerOperation.removeTapback ? 'current-2007' : null),
            'temp-gated',
            file: operation == NativeStickerOperation.removeTapback ? null : selected(),
            placement: operation == NativeStickerOperation.placement ? geometry() : null,
          ),
          throwsUnsupportedError,
        );
        expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
      }
    }
    final api = _OfflineApi(reactionsCapability: true)..originValue = 'https://different.invalid';
    await expectLater(
      MessageApi(api).sendTargetedSticker(target(NativeStickerOperation.tapback), 'temp-switch', file: selected()),
      throwsStateError,
    );
    expect(api.requests, isEmpty);
  });

  test('target intent survives message and asset serialization with separate GUIDs', () {
    final message = Message(guid: 'temp-target', text: '', metadata: {'existing': 'kept'});
    final asset = Attachment(
      guid: 'source',
      transferName: 'animated.gif',
      isOutgoing: true,
      metadata: {'stickerLabel': 'Animated'},
    );
    final item = OutgoingTargetedSticker(
      chat: Chat(guid: 'iMessage;-;chat'),
      message: message,
      target: target(NativeStickerOperation.placement),
      placement: geometry(),
      attachment: asset,
    );
    item.ensureIntent();
    expect(message.associatedMessageGuid, 'parent-guid');
    expect(message.associatedMessagePart, 7);
    expect(message.associatedMessageType, 'sticker');
    expect(asset.guid, 'temp-target-sticker');
    expect(asset.guid, isNot(message.guid));
    expect(asset.metadata!['preserveOriginalBytes'], true);
    expect(
      Attachment.fromMap(asset.toMap()).metadata!['nativeStickerTarget'],
      target(NativeStickerOperation.placement).toMap(),
    );
    message.error = 1;
    final reloaded = Message.fromMap(message.toMap());
    expect(reloaded.metadata!['nativeStickerTargetSend'], true);
    expect(reloaded.metadata!['existing'], 'kept');
    expect(reloaded.metadata!['nativeStickerPlacement'], geometry().toMap());
  });

  test('server switch during multipart staging blocks targeted, row and single native sends', () async {
    for (final kind in ['target', 'row', 'single']) {
      final api = _OfflineApi(reactionsCapability: true, rowCapability: true);
      await IOOverrides.runZoned(() async {
        final request = switch (kind) {
          'target' => MessageApi(
            api,
          ).sendTargetedSticker(target(NativeStickerOperation.tapback), 'temp-switch', file: selected()),
          'row' => MessageApi(api).sendStickerRow('chat', 'temp-switch', [selected(), selected()]),
          _ => MessageApi(api).sendSticker('chat', 'temp-switch', selected()),
        };
        await expectLater(request, throwsStateError);
      }, createFile: (_) => _SwitchingFile(file, () => api.originValue = 'https://new-server.invalid'));
      expect(api.requests.where((request) => request.method == 'POST'), isEmpty);
    }
  });

  test('confirmed native partial status update skips send verification but echoes remain strict', () {
    final confirmed = Message(guid: 'native-event', metadata: {'nativeStickerTargetSend': true});
    expect(StickerHelper.shouldVerifyTargetedEcho(confirmed, hasAttachments: false), false);
    expect(StickerHelper.shouldVerifyTargetedEcho(confirmed, tempGuid: 'temp-attempt', hasAttachments: false), true);
    expect(StickerHelper.shouldVerifyTargetedEcho(confirmed, hasAttachments: true), true);
    confirmed.guid = 'temp-attempt';
    expect(StickerHelper.shouldVerifyTargetedEcho(confirmed, hasAttachments: false), true);
    confirmed.metadata = null;
    expect(StickerHelper.shouldVerifyTargetedEcho(confirmed, tempGuid: 'temp-attempt', hasAttachments: true), false);
  });

  test('socket-first target echo maps the asset GUID, and HTTP-first late echo is idempotent', () {
    final pending = Message(
      guid: 'temp-target',
      metadata: {
        'nativeStickerTargetSend': true,
        'nativeStickerTarget': target(NativeStickerOperation.tapback).toMap(),
      },
    );
    final asset = Attachment(guid: 'temp-target-sticker', transferName: 'same.gif')..id = 88;
    attachmentBox.attachments[88] = asset;
    pending.dbAttachments.add(asset);
    final confirmed = Message(
      guid: 'native-2007',
      isFromMe: true,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: 7,
      associatedMessageType: 'sticker-reaction',
    );
    expect(StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'real-asset')]), {
      'real-asset': 'temp-target-sticker',
    });
    pending.guid = 'native-2007';
    asset.guid = 'real-asset';
    expect(StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'real-asset')]), {
      'real-asset': 'real-asset',
    });
    confirmed.associatedMessagePart = 0;
    expect(
      () => StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'real-asset')]),
      throwsStateError,
    );
    confirmed.associatedMessagePart = 7;
    expect(() => StickerHelper.targetedReplacementGuids(pending, confirmed, []), throwsStateError);
    expect(
      () => StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'A'), Attachment(guid: 'B')]),
      throwsStateError,
    );
    pending.metadata!['nativeStickerTarget'] = {'operation': 'sendAttachment'};
    expect(
      () => StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'real-asset')]),
      throwsA(anything),
    );
  });

  test('3007 confirmation is a new event and may reference old artwork without creating an asset', () {
    final pending = Message(
      guid: 'temp-remove',
      metadata: {
        'nativeStickerTargetSend': true,
        'nativeStickerTarget': target(NativeStickerOperation.removeTapback, reactionGuid: 'current-2007').toMap(),
      },
    );
    final confirmed = Message(
      guid: 'native-3007',
      isFromMe: true,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: 7,
      associatedMessageType: '-sticker-reaction',
    );
    expect(
      StickerHelper.targetedReplacementGuids(pending, confirmed, [Attachment(guid: 'linked-old-artwork')]),
      isEmpty,
    );
    confirmed.guid = 'current-2007';
    expect(() => StickerHelper.targetedReplacementGuids(pending, confirmed, []), throwsStateError);
  });

  test('unconfirmed targeted removal does not consume an existing own sticker tapback slot', () {
    final current = Message(
      guid: 'current-2007',
      isFromMe: true,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: 7,
      associatedMessageType: 'sticker-reaction',
      dateCreated: DateTime(2026),
    );
    final pending = Message(
      guid: 'temp-remove',
      isFromMe: true,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: 7,
      associatedMessageType: '-sticker-reaction',
      dateCreated: DateTime(2026, 2),
      metadata: {'nativeStickerTargetSend': true},
    );
    final placed = Message(
      guid: 'independent-1000',
      isFromMe: true,
      associatedMessageGuid: 'parent-guid',
      associatedMessagePart: 7,
      associatedMessageType: 'sticker',
      dateCreated: DateTime(2026, 3),
    );
    expect(getUniqueReactionMessages([current, pending, placed]).single.guid, 'current-2007');
    expect(StickerHelper.isUnconfirmedTargetedEvent(pending), true);
    pending.guid = 'native-3007';
    expect(getUniqueReactionMessages([current, pending, placed]), isEmpty);
  });

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
      'real-0': 'real-0',
      'real-1': 'real-1',
      'real-2': 'real-2',
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
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      const StickerFolderService(channel: channel).sendRow(Chat(guid: 'chat'), [
        const StickerFolderEntry(uri: 'one', name: 'one.gif', directory: false, size: 3),
        const StickerFolderEntry(uri: 'two', name: 'two.gif', directory: false, size: 3),
      ]),
      throwsA(isA<PlatformException>()),
    );
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
    first.metadata = {
      'sticker': {
        'placement': {'sir': false, 'spv': 0},
      },
    };
    second.metadata = {
      'sticker': {
        'placement': {'sir': true, 'spv': 0},
      },
    };
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

  test('target and geometry survive interface and isolate action serialization', () async {
    final api = _OfflineApi(placementCapability: true);
    GetIt.I.registerSingleton<HttpService>(
      HttpService()
        ..originOverride = api.origin
        ..message = MessageApi(api),
    );
    isIsolateOverride = true;
    await SendMessageInterface.sendTargetedSticker(
      target: target(NativeStickerOperation.placement),
      tempGuid: 'temp-isolate-target',
      file: selected(),
      placement: geometry(),
    );
    final fields = Map.fromEntries((api.requests.last.data as FormData).fields);
    expect(api.requests.last.path, endsWith('/message/send-sticker-placement'));
    expect(fields['tempGuid'], 'temp-isolate-target');
    expect(fields['selectedMessageGuid'], 'parent-guid');
    expect(fields['partIndex'], '7');
    expect(jsonDecode(fields['placement']!), geometry().toMap());
  });

  test('target invalidated during SAF staging cleans its owned original without queueing', () async {
    const channel = MethodChannel('test-stale-sticker-target');
    final staged = await File('${directory.path}/staged-target.gif').writeAsBytes([1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => {'path': staged.path, 'name': 'staged-target.gif', 'size': 3},
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      const StickerFolderService(channel: channel).sendTargeted(
        Chat(guid: 'iMessage;-;chat'),
        const StickerFolderEntry(uri: 'one', name: 'one.gif', directory: false, size: 3),
        target(NativeStickerOperation.tapback),
        canQueue: () => false,
      ),
      throwsStateError,
    );
    expect(await staged.exists(), false);
    expect(await file.exists(), true);
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
    NativeStickerTarget? stickerTarget,
    StickerTargetPreview? preview,
    bool Function()? isTargetCurrent,
  }) async {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<ThemesService>(_Themes());
    GetIt.I.registerSingleton<BaseLogger>(BaseLogger());
    GetIt.I.registerSingleton<HttpService>(
      HttpService()
        ..originOverride = 'https://offline.trycloudflare.invalid'
        ..message = MessageApi(
          _OfflineApi(capability: supported, placementCapability: supported, reactionsCapability: supported),
        ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StickerBrowser(
          chat: Chat(guid: chatGuid),
          folders: folders,
          target: stickerTarget,
          targetPreview: preview,
          isTargetCurrent: isTargetCurrent,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  StickerTargetPreview targetPreview() => StickerTargetPreview(
    Uint8List.fromList(image.encodePng(image.Image(width: 24, height: 12))),
    const Size(240, 120),
  );

  testWidgets('placement preview uses measured native parent width and requires explicit single send', (tester) async {
    final folders = _Folders()..targetPending = Completer<void>();
    await harness(
      tester,
      folders,
      supported: true,
      stickerTarget: target(NativeStickerOperation.placement),
      preview: targetPreview(),
    );
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    final controller = tester.widget<StickerBrowser>(find.byType(StickerBrowser)).parentController;
    expect(find.byType(StickerPlacementEditor), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(controller.selection, hasLength(1));
    expect(controller.placement.value!.parentWidth, 240);
    expect(folders.targets, isEmpty);
    await tester.ensureVisible(find.text('Send placement'));
    await tester.tap(find.text('Send placement'));
    await tester.pump();
    await controller.send();
    expect(folders.targets, isEmpty);
    folders.targetPending!.complete();
    await tester.pumpAndSettle();
    expect(folders.targets.single.partIndex, 7);
    expect(folders.placements.single!.parentWidth, 240);
    expect(controller.submitted.value, true);
    await controller.send();
    expect(folders.targets, hasLength(1));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Queued')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale message part and server change prevent target submission', (tester) async {
    final folders = _Folders();
    var current = true;
    await harness(
      tester,
      folders,
      supported: true,
      stickerTarget: target(NativeStickerOperation.tapback),
      isTargetCurrent: () => current,
    );
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    final controller = tester.widget<StickerBrowser>(find.byType(StickerBrowser)).parentController;
    current = false;
    expect(controller.canSendNative, false);
    await controller.send();
    expect(folders.targets, isEmpty);
    current = true;
    HttpSvc.originOverride = 'https://changed.invalid';
    expect(controller.canSendNative, false);
    await controller.send();
    expect(folders.targets, isEmpty);
    await controller.checkCapability();
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send tapback')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposing target browser while staging prevents queueing and preserves draft', (tester) async {
    final folders = _Folders()..targetPending = Completer<void>();
    await harness(tester, folders, supported: true, stickerTarget: target(NativeStickerOperation.tapback));
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    final controller = tester.widget<StickerBrowser>(find.byType(StickerBrowser)).parentController;
    final composer = ConversationViewController(controller.chat);
    SettingsSvc.settings.spellcheck.value = false;
    composer.textController.text = 'Unrelated draft';
    final pending = controller.send();
    await tester.pumpWidget(const SizedBox());
    folders.targetPending!.complete();
    await pending;
    expect(folders.targets, isEmpty);
    expect(composer.textController.text, 'Unrelated draft');
    expect(controller.active, false);
    composer.textController.dispose();
  });

  testWidgets('placement is disabled without exact part preview and tiny editor constraints are safe', (tester) async {
    final folders = _Folders();
    await harness(tester, folders, supported: true, stickerTarget: target(NativeStickerOperation.placement));
    await tester.tap(find.text('a.png'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send placement')).onPressed, isNull);
    expect(find.text('A measured preview of this message part is required to place a sticker.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final controller = StickerBrowserController(
      Chat(guid: 'iMessage;-;chat'),
      folders,
      target: target(NativeStickerOperation.placement),
      targetPreview: targetPreview(),
    );
    controller.select(const StickerFolderEntry(uri: 'one', name: 'one.png', directory: false, size: 10));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            child: SizedBox(width: 20, child: StickerPlacementEditor(controller: controller)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(controller.placement.value!.parentWidth, 240);
    await tester.pumpWidget(const SizedBox());
    controller.onClose();
  });

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
