import 'dart:async';
import 'dart:convert';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/draft_sticker_thumbnail.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/sticker_composition_controller.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/ui/chat/conversation_view_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const artwork = StickerFolderEntry(
  uri: 'content://synthetic/tree/a/document/b',
  name: 'one.png',
  directory: false,
  size: 8,
);

class _Capabilities extends MessageApi {
  bool enabled = false;
  bool standalone = false;
  Completer<void>? pending;
  _Capabilities() : super(HttpService());
  @override
  Future<Map<String, bool>> stickerCapabilities({CancelToken? cancelToken}) async {
    await pending?.future;
    return {'stickerComposition': enabled, 'stickerSending': standalone};
  }
}

class _Folders extends StickerFolderService {
  int sends = 0;
  Completer<void>? pending;
  final texts = <String>[];
  @override
  Future<Uint8List> read(StickerFolderEntry entry, {String? requestId}) async =>
      Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
  @override
  Future<void> cancelRead(String requestId) async {}
  @override
  Future<void> sendComposition(
    Chat chat,
    List<StickerFolderEntry> entries,
    String text,
    String serverIdentity, {
    required bool Function() canQueue,
  }) async {
    sends++;
    await pending?.future;
    if (!canQueue()) throw StateError('The conversation changed.');
    texts.add(text);
  }
}

class _Chats extends ChatsService {
  final saved = <String?>[];
  @override
  Future<void> setChatTextFieldText(Chat chat, String? value) async {
    saved.add(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  late SharedPreferencesService prefs;
  late _Capabilities api;
  late HttpService http;
  final composers = <ConversationViewController>[];
  ConversationViewController create() {
    final cvc = ConversationViewController(Chat(guid: 'iMessage;-;chat'));
    cvc.subjectTextController;
    composers.add(cvc);
    return cvc;
  }

  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesService();
    // ignore: deprecated_member_use_from_same_package
    prefs.i = await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions());
    prefs.messaging = SharedPreferencesMessagingActions(prefs);
    GetIt.I.registerSingleton<SharedPreferencesService>(prefs);
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I<SettingsService>().settings.replaceEmoticonsWithEmoji.value = false;
    GetIt.I<SettingsService>().settings.spellcheck.value = false;
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService());
    api = _Capabilities();
    http = HttpService()
      ..originOverride = 'https://one.invalid'
      ..message = api;
    GetIt.I.registerSingleton<HttpService>(http);
    GetIt.I.registerSingleton<ChatsService>(_Chats());
  });
  tearDown(() async {
    for (final composer in composers) {
      if (!composer.isClosed) composer.onDelete();
      composer.textController.dispose();
      composer.subjectTextController.dispose();
      composer.focusNode.dispose();
      composer.subjectFocusNode.dispose();
    }
    composers.clear();
    await GetIt.I.reset();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  testWidgets('real text input renders artwork at cursor and selection/removal preserve text', (tester) async {
    final focus = FocusNode();
    final controller = StickerCompositionController(
      serverIdentity: 'https://one.invalid',
      chatGuid: 'chat',
      focusNode: focus,
      folders: _Folders(),
    );
    controller.value = const TextEditingValue(text: 'before after', selection: TextSelection.collapsed(offset: 7));
    controller.insertSticker(artwork);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, child) => TextField(
              controller: controller,
              focusNode: focus,
              minLines: 1,
              maxLines: 14,
              strutStyle: controller.composerStrut,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(DraftStickerThumbnail), findsOneWidget);
    expect(controller.snapshot().text, 'before \uFFFCafter');
    await tester.tap(
      find.descendant(of: find.byType(DraftStickerThumbnail), matching: find.byType(GestureDetector)).first,
    );
    await tester.pump();
    expect(controller.selection, const TextSelection(baseOffset: 7, extentOffset: 8));
    await tester.tap(find.byTooltip('Remove sticker'));
    await tester.pump();
    expect(controller.text, 'before after');
    expect(controller.hasComposition, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    focus.dispose();
  });

  test('invalid saved draft stays atomic until explicit discard, including debounce-style save', () async {
    final composer = create();
    const raw = '{"version":1,"stickers":[null]}';
    await prefs.messaging.saveStickerComposition(http.origin, composer.chat.guid, raw);
    composer.textController.text = 'ordinary fallback';
    expect(composer.restoreStickerDraft(), true);
    expect(composer.stickerDraftError.value, isNotNull);
    composer.textController.text = 'edited ordinary fallback';
    await composer.saveStickerDraft();
    expect(prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid), raw);
    await expectLater(composer.sendStickerComposition(), throwsStateError);
    await composer.discardSavedStickerDraft();
    expect(composer.stickerDraftError.value, isNull);
    expect(prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid), isNull);
    expect(composer.textController.text, 'edited ordinary fallback');
  });

  test('persisted text/artwork snapshot restores only in its origin and chat', () async {
    final source = create();
    source.textController.text = 'hello\n';
    source.textController.insertSticker(artwork);
    await source.saveStickerDraft();
    final restored = create();
    expect(restored.restoreStickerDraft(), true);
    expect(restored.textController.snapshot().text, 'hello\n\uFFFC');
    final raw = prefs.messaging.loadStickerComposition(http.origin, source.chat.guid)!;
    expect((jsonDecode(raw) as Map)['stickers'], hasLength(1));
    expect(prefs.messaging.loadStickerComposition('https://two.invalid', source.chat.guid), isNull);
    expect(prefs.messaging.loadStickerComposition(http.origin, 'other'), isNull);
  });

  test('oversized saves report failure without replacing the last atomic record, then recover on edit', () async {
    final composer = create()..textController.insertSticker(artwork);
    await composer.saveStickerDraft();
    final original = prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid);
    composer.textController.text = '${composer.textController.text}${'a' * 66000}';
    await composer.saveStickerDraft();
    expect(composer.stickerDraftSaveError.value, isNotNull);
    expect(prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid), original);
    composer.textController.text = composer.textController.text.substring(0, 1);
    await composer.saveStickerDraft();
    expect(composer.stickerDraftSaveError.value, isNull);
  });

  test('missing composition capability preserves draft and does not stage', () async {
    api.standalone = true;
    final composer = create();
    composer.textController.text = 'text';
    composer.textController.insertSticker(artwork);
    final folders = _Folders();
    await expectLater(composer.sendStickerComposition(folders: folders), throwsUnsupportedError);
    expect(folders.sends, 0);
    expect(composer.textController.snapshot().text, 'text\uFFFC');
    expect(composer.sendingStickerComposition.value, false);
  });

  test('one immutable queued draft, double-submit lock and newer revision retention', () async {
    api.enabled = true;
    final composer = create();
    composer.textController.text = 'text';
    composer.textController.insertSticker(artwork);
    final folders = _Folders()..pending = Completer<void>();
    final send = composer.sendStickerComposition(folders: folders);
    await Future<void>.delayed(Duration.zero);
    await composer.sendStickerComposition(folders: folders);
    composer.textController.text = '${composer.textController.text} edited';
    folders.pending!.complete();
    await send;
    expect(folders.sends, 1);
    expect(folders.texts, ['text\uFFFC']);
    expect(composer.textController.snapshot().text, 'text\uFFFC edited');
    expect(prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid), isNotNull);
  });

  test('server switch during capability lookup prevents staging', () async {
    api.standalone = true;
    api.pending = Completer<void>();
    final composer = create()..textController.insertSticker(artwork);
    final folders = _Folders();
    final send = composer.sendStickerComposition(folders: folders);
    http.originOverride = 'https://two.invalid';
    api.pending!.complete();
    await expectLater(send, throwsStateError);
    expect(folders.sends, 0);
    expect(composer.textController.hasComposition, true);
  });

  test('disposal during staging prevents queue and completion clearing', () async {
    api.standalone = true;
    final composer = create()..textController.insertSticker(artwork);
    final folders = _Folders()..pending = Completer<void>();
    final send = composer.sendStickerComposition(folders: folders);
    await Future<void>.delayed(Duration.zero);
    composer.onDelete();
    folders.pending!.complete();
    await expectLater(send, throwsStateError);
    expect(folders.texts, isEmpty);
    expect(composer.textController.hasComposition, true);
  });

  test('one sticker without text uses standalone capability and clears only its matching draft', () async {
    api.standalone = true;
    final composer = create()..textController.insertSticker(artwork);
    final folders = _Folders();
    await composer.sendStickerComposition(folders: folders);
    expect(folders.texts, ['\uFFFC']);
    expect(composer.textController.text, isEmpty);
    expect(composer.textController.hasComposition, false);
    expect(prefs.messaging.loadStickerComposition(http.origin, composer.chat.guid), isNull);
  });

  test('ordinary attachments, subject, effects and schedules fail without changing the draft', () async {
    api.enabled = true;
    final composer = create()..textController.insertSticker(artwork);
    final folders = _Folders();
    composer.pickedAttachments.add(PlatformFile(name: 'ordinary.png', size: 8));
    await expectLater(composer.sendStickerComposition(folders: folders), throwsStateError);
    composer.pickedAttachments.clear();
    composer.subjectTextController.text = 'subject';
    await expectLater(composer.sendStickerComposition(folders: folders), throwsStateError);
    composer.subjectTextController.clear();
    await expectLater(composer.sendStickerComposition(folders: folders, effect: 'confetti'), throwsStateError);
    composer.scheduledDate.value = DateTime.now();
    await expectLater(composer.sendStickerComposition(folders: folders), throwsStateError);
    expect(folders.sends, 0);
    expect(composer.textController.snapshot().text, '\uFFFC');
  });

  test('static PNG chunk preflight rejects animation and malformed lengths without decoding', () {
    final png = Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
    StickerFolderService.requireStaticCompositionPng(png);
    final animated = Uint8List.fromList([
      ...png.sublist(0, 33),
      0,
      0,
      0,
      8,
      ...'acTL'.codeUnits,
      ...List.filled(12, 0),
      ...png.sublist(33),
    ]);
    expect(() => StickerFolderService.requireStaticCompositionPng(animated), throwsUnsupportedError);
    for (final type in ['fcTL', 'fdAT']) {
      final orphan = Uint8List.fromList([
        ...png.sublist(0, 33),
        0,
        0,
        0,
        4,
        ...type.codeUnits,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        ...png.sublist(33),
      ]);
      expect(() => StickerFolderService.requireStaticCompositionPng(orphan), throwsUnsupportedError);
    }
    final literal = Uint8List.fromList([
      ...png.sublist(0, 33),
      0,
      0,
      0,
      4,
      ...'tEXt'.codeUnits,
      ...'acTL'.codeUnits,
      0,
      0,
      0,
      0,
      ...png.sublist(33),
    ]);
    StickerFolderService.requireStaticCompositionPng(literal);
    expect(
      () => StickerFolderService.requireStaticCompositionPng(Uint8List.fromList('GIF89a'.codeUnits)),
      throwsUnsupportedError,
    );
    final malformed = Uint8List.fromList(png)..[8] = 255;
    expect(() => StickerFolderService.requireStaticCompositionPng(malformed), throwsStateError);
    expect(
      () => StickerFolderService.requireStaticCompositionPng(Uint8List.fromList(png.sublist(0, png.length - 1))),
      throwsStateError,
    );
  });
}
