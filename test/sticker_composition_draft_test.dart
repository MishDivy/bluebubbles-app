import 'dart:convert';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/sticker_composition_controller.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

const first = StickerFolderEntry(
  uri: 'content://synthetic/tree/root/document/first',
  name: 'first.png',
  directory: false,
  size: 8,
);
const second = StickerFolderEntry(
  uri: 'content://synthetic/tree/root/document/second',
  name: 'second.png',
  directory: false,
  size: 9,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final controllers = <StickerCompositionController>[];
  final nodes = <FocusNode>[];
  StickerCompositionController create({String chat = 'chat', String server = 'https://one.invalid'}) {
    final node = FocusNode();
    nodes.add(node);
    final controller = StickerCompositionController(serverIdentity: server, chatGuid: chat, focusNode: node);
    controllers.add(controller);
    return controller;
  }

  setUp(() {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I.registerSingleton<FilesystemService>(FilesystemService());
    GetIt.I<SettingsService>().settings.replaceEmoticonsWithEmoji.value = false;
    GetIt.I<SettingsService>().settings.spellcheck.value = false;
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final node in nodes) {
      node.dispose();
    }
    controllers.clear();
    nodes.clear();
    await GetIt.I.reset();
  });

  test('cursor and selection insertion preserve text and ordered artwork in one snapshot', () {
    final controller = create();
    controller.value = const TextEditingValue(text: 'before after', selection: TextSelection.collapsed(offset: 7));
    controller.insertSticker(first);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    controller.insertSticker(second);
    final snapshot = controller.snapshot();
    expect(snapshot.text, '\uFFFC \uFFFCafter');
    expect(snapshot.entries.map((entry) => entry.name), ['second.png', 'first.png']);
    expect(snapshot.entries, isNot(same(controller.snapshot().entries)));
    expect(controller.selection.baseOffset, 1);
  });

  test('backspace, delete and IME replacements reconcile owned markers', () {
    final controller = create();
    controller.insertSticker(first);
    controller.insertSticker(second);
    final one = controller.text.substring(0, 1);
    controller.value = TextEditingValue(
      text: 'typed$one',
      selection: const TextSelection.collapsed(offset: 6),
      composing: const TextRange(start: 0, end: 5),
    );
    expect(controller.snapshot().text, 'typed\uFFFC');
    expect(controller.snapshot().entries.single.name, first.name);
    controller.selection = const TextSelection.collapsed(offset: 6);
    controller.value = const TextEditingValue(text: 'typed', selection: TextSelection.collapsed(offset: 5));
    expect(controller.hasComposition, isFalse);
    expect(controller.serializeDraft(), isNull);
  });

  test('duplicate, orphan and pasted FFFC markers fail closed without removing text', () {
    final controller = create();
    controller.insertSticker(first);
    final owned = controller.text;
    for (final invalid in ['$owned$owned', '$owned\uE1FF', '$owned\uFFFC']) {
      controller.value = TextEditingValue(
        text: invalid,
        selection: TextSelection.collapsed(offset: invalid.length),
      );
      expect(controller.snapshot, throwsStateError);
      expect(controller.text, invalid);
    }
  });

  test('ordinary private-use text remains ordinary and is not globally rejected', () {
    final controller = create();
    controller.text = 'ordinary\uE1FFtext';
    expect(controller.hasComposition, isFalse);
    expect(controller.plainDraftText, controller.text);
    expect(controller.serializeDraft(), isNull);
    expect(() => controller.insertSticker(first), throwsStateError);
    expect(controller.text, 'ordinary\uE1FFtext');
  });

  test('listeners observe reconciled marker ownership and the new revision', () {
    final controller = create();
    final observations = <(int, bool, String?)>[];
    controller.addListener(() {
      observations.add((
        controller.revision,
        controller.hasComposition,
        controller.hasComposition ? controller.snapshot().text : null,
      ));
    });
    controller.insertSticker(first);
    expect(observations.single, (1, true, '\uFFFC'));
    final token = controller.text;
    controller.removeSticker(token);
    expect(observations.last, (2, false, null));
    expect(observations, hasLength(2));
  });

  test('restore listeners see the saved revision and complete ownership atomically', () {
    final source = create()..text = 'a';
    source.insertSticker(first);
    final restored = create();
    restored.addListener(() {
      expect(restored.revision, source.revision);
      expect(restored.snapshot().text, source.snapshot().text);
    });
    restored.restoreDraft(source.serializeDraft()!);
  });

  test('malformed stored assets and cursor cannot mutate an existing draft', () {
    final controller = create()..insertSticker(first);
    final raw = controller.serializeDraft()!;
    final variants = <Map<String, dynamic>>[
      {
        ...jsonDecode(raw),
        'stickers': [null],
      },
      {
        ...jsonDecode(raw),
        'stickers': [1],
      },
      {...jsonDecode(raw), 'text': 'missing token'},
      {...jsonDecode(raw), 'text': '${controller.text}${controller.text}'},
      {
        ...jsonDecode(raw),
        'selection': [-1, 0],
      },
    ];
    for (final invalid in variants) {
      expect(() => controller.restoreDraft(jsonEncode(invalid)), throwsFormatException);
      expect(controller.serializeDraft(), raw);
    }
    final absentCursor = {
      ...jsonDecode(raw),
      'selection': [-1, -1],
    };
    controller.restoreDraft(jsonEncode(absentCursor));
    expect(controller.selection, TextSelection.collapsed(offset: controller.text.length));
  });

  test('a sticker added during ordinary staging survives its eventual completion', () async {
    final controller = create()..text = 'ordinary send';
    final started = controller.revision;
    await Future<void>.value();
    controller.insertSticker(first);
    expect(controller.canClearAfterOrdinarySend(started), false);
    controller.removeSticker(controller.text.substring(controller.text.length - 1));
    expect(controller.canClearAfterOrdinarySend(started), false);
    final plain = create()..text = 'ordinary';
    final plainStarted = plain.revision;
    plain.text = 'ordinary edit';
    expect(plain.canClearAfterOrdinarySend(plainStarted), true);
  });

  test('atomic restore keeps typed assets, text, cursor and server/chat isolation', () {
    final controller = create();
    controller.value = const TextEditingValue(text: 'hello\n', selection: TextSelection.collapsed(offset: 6));
    controller.insertSticker(first);
    final raw = controller.serializeDraft()!;
    final restored = create();
    restored.restoreDraft(raw);
    expect(restored.text, controller.text);
    expect(restored.selection, controller.selection);
    expect(restored.snapshot().text, 'hello\n\uFFFC');
    expect(restored.snapshot().entries.single.uri, first.uri);
    expect(restored.revision, controller.revision);
    expect(() => create(chat: 'other').restoreDraft(raw), throwsFormatException);
    expect(() => create(server: 'https://two.invalid').restoreDraft(raw), throwsFormatException);
    final malformed = jsonDecode(raw) as Map<String, dynamic>;
    malformed['stickers'] = [
      {'token': '\uE100', 'uri': 'file:///etc/passwd', 'name': 'bad.png', 'size': 8},
    ];
    expect(() => restored.restoreDraft(jsonEncode(malformed)), throwsFormatException);
    expect(restored.snapshot().entries.single.uri, first.uri);
  });

  test('completion only clears the same revision and never a newer draft', () {
    final controller = create();
    controller.insertSticker(first);
    final sent = controller.snapshot();
    controller.value = controller.value.copyWith(
      text: '${controller.text} edited',
      selection: TextSelection.collapsed(offset: controller.text.length + 7),
    );
    expect(controller.clearIfUnchanged(sent), isFalse);
    expect(controller.text, endsWith(' edited'));
    final updated = controller.snapshot();
    expect(controller.clearIfUnchanged(updated), isTrue);
    expect(controller.text, isEmpty);
    expect(controller.hasComposition, isFalse);
  });

  test('explicit removal and maximum selection preserve remaining draft', () {
    final controller = create();
    for (var index = 0; index < 10; index++) {
      controller.insertSticker(first);
    }
    expect(() => controller.insertSticker(second), throwsStateError);
    final token = controller.text.substring(5, 6);
    controller.removeSticker(token);
    expect(controller.snapshot().entries, hasLength(9));
    expect(controller.selection.baseOffset, 5);
  });
}
