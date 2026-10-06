import 'dart:typed_data';

import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/draft_sticker_thumbnail.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/sticker_composition_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_component.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart' show Skins;
import 'package:bluebubbles/helpers/ui/theme_helpers.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/network/http_service.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/ui/chat/conversation_view_controller.dart';
import 'package:bluebubbles/services/ui/theme/themes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';
import 'package:record/record.dart';

class _Recorder extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Themes extends ThemesService {
  @override
  bool get isAnyMaterialYouSelected => false;
}

class _Folders extends StickerFolderService {
  @override
  Future<Uint8List> read(StickerFolderEntry entry, {String? requestId}) async =>
      throw StateError('No thumbnail bytes in this fixture.');
  @override
  Future<void> cancelRead(String requestId) async {}
}

class _ChatState implements ChatState {
  @override
  final title = RxnString('First title');
  @override
  bool get hasCustomWallpaper => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chats extends ChatsService {
  final state = _ChatState();
  @override
  ChatState? getChatState(String guid) => state;
}

void main() {
  late Settings settings;
  late RecordPlatform previousRecorder;
  late ErrorWidgetBuilder previousErrorBuilder;

  setUp(() {
    settings = Settings();
    settings.replaceEmoticonsWithEmoji.value = false;
    settings.spellcheck.value = false;
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = settings);
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService());
    GetIt.I.registerSingleton<ThemesService>(_Themes());
    previousRecorder = RecordPlatform.instance;
    RecordPlatform.instance = _Recorder();
    previousErrorBuilder = ErrorWidget.builder;
    ErrorWidget.builder = (_) => const SizedBox.shrink();
  });

  tearDown(() async {
    ErrorWidget.builder = previousErrorBuilder;
    RecordPlatform.instance = previousRecorder;
    await GetIt.I.reset();
  });

  Widget composer(
    MentionTextEditingController controller,
    FocusNode focus, {
    ConversationViewController? conversation,
  }) => MaterialApp(
    theme: ThemeData(extensions: const [BubbleText(bubbleText: TextStyle(fontSize: 16))]),
    home: Scaffold(
      body: TextFieldComponent(
        textController: controller,
        focusNode: conversation == null ? focus : null,
        controller: conversation,
        recorderController: null,
        hideMediaPicker: true,
        sendMessage: ({String? effect}) async {},
      ),
    ),
  );

  for (final skin in Skins.values) {
    testWidgets('${skin.name} fresh chat accepts text and reacts to settings without losing the cursor', (
      tester,
    ) async {
      settings.skin.value = skin;
      settings.incognitoKeyboard.value = false;
      final focus = FocusNode();
      final controller = MentionTextEditingController(focusNode: focus);
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      await tester.pumpWidget(composer(controller, focus));
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, 'New Message');
      expect(tester.widget<TextField>(find.byType(TextField)).enableIMEPersonalizedLearning, true);

      await tester.enterText(find.byType(TextField), 'hello world');
      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      final draft = controller.value;
      settings.incognitoKeyboard.value = true;
      settings.skin.value = skin == Skins.iOS ? Skins.Material : Skins.iOS;
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enableIMEPersonalizedLearning, false);
      expect(
        (field.decoration!.suffixIcon! as Padding).padding,
        EdgeInsets.only(right: settings.skin.value == Skins.iOS ? 0 : 5),
      );
      expect(controller.value, draft);
      expect(focus.hasFocus, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('existing chat reacts to title and keyboard settings without changing its draft', (tester) async {
    settings.skin.value = Skins.Samsung;
    settings.recipientAsPlaceholder.value = true;
    settings.incognitoKeyboard.value = false;
    final chats = _Chats();
    GetIt.I.registerSingleton<ChatsService>(chats);
    GetIt.I.registerSingleton<HttpService>(HttpService()..originOverride = 'https://one.invalid');
    final conversation = ConversationViewController(Chat(guid: 'iMessage;-;chat'));
    conversation.textController.value = const TextEditingValue(
      text: 'saved draft',
      selection: TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      conversation.onDelete();
      conversation.textController.dispose();
      conversation.subjectTextController.dispose();
      conversation.focusNode.dispose();
      conversation.subjectFocusNode.dispose();
    });
    await tester.pumpWidget(composer(conversation.textController, conversation.focusNode, conversation: conversation));
    expect(tester.takeException(), isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, 'First title');
    final draft = conversation.textController.value;

    chats.state.title.value = 'Updated title';
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, 'Updated title');
    settings.incognitoKeyboard.value = true;
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enableIMEPersonalizedLearning, false);
    expect(conversation.textController.value, draft);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('composer updates sticker line height after cursor insertion and removal', (tester) async {
    final focus = FocusNode();
    final controller = StickerCompositionController(
      serverIdentity: 'https://one.invalid',
      chatGuid: 'chat',
      focusNode: focus,
      folders: _Folders(),
    );
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    controller.value = const TextEditingValue(text: 'before after', selection: TextSelection.collapsed(offset: 7));
    await tester.pumpWidget(composer(controller, focus));
    expect(tester.takeException(), isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).strutStyle, isNull);

    controller.insertSticker(
      const StickerFolderEntry(
        uri: 'content://synthetic/tree/a/document/b',
        name: 'one.png',
        directory: false,
        size: 8,
      ),
    );
    await tester.pump();
    expect(find.byType(DraftStickerThumbnail), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).strutStyle!.fontSize, 44);
    expect(controller.snapshot().text, 'before \uFFFCafter');
    expect(controller.selection, const TextSelection.collapsed(offset: 8));

    await tester.tap(find.byTooltip('Remove sticker'));
    await tester.pump();
    expect(find.byType(DraftStickerThumbnail), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).strutStyle, isNull);
    expect(controller.text, 'before after');
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
