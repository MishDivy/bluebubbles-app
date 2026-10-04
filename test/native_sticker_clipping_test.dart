import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/message_holder/message_holder_indicators.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/app/state/message_state_scope.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/ui/message/messages_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as image;

Uint8List edgeArtwork() {
  final canvas = image.Image(width: 100, height: 100, numChannels: 4);
  canvas.setPixelRgba(95, 50, 255, 0, 0, 255);
  canvas.setPixelRgba(4, 50, 0, 0, 255, 255);
  canvas.setPixelRgba(50, 50, 0, 255, 0, 128);
  return Uint8List.fromList(image.encodePng(canvas));
}

Future<ByteData> snapshot(WidgetTester tester, GlobalKey key) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final rendered = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final pixels = await tester.runAsync(() => rendered!.toByteData(format: ui.ImageByteFormat.rawRgba));
  rendered!.dispose();
  return pixels!;
}

void main() {
  setUp(() {
    GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
    GetIt.I<SettingsService>().settings.skin.value = Skins.Samsung;
  });
  tearDown(() async => GetIt.I.reset());

  for (final skin in Skins.values) {
    for (final scenario in [
      (name: 'outgoing failed', fromMe: true, failed: true, count: 1),
      (name: 'outgoing sent', fromMe: true, failed: false, count: 1),
      (name: 'received', fromMe: false, failed: false, count: 1),
      (name: 'outgoing row', fromMe: true, failed: false, count: 3),
    ]) {
      testWidgets('${skin.name} ${scenario.name} sticker-only tile keeps edge artwork outside the bubble clip', (
        tester,
      ) async {
        GetIt.I<SettingsService>().settings.skin.value = skin;
        final message = Message(
          guid: scenario.failed ? 'error-native-sticker' : 'synthetic-native-sticker',
          isFromMe: scenario.fromMe,
          error: scenario.failed ? 1 : 0,
          errorMessage: 'Synthetic send failure',
        );
        final state = MessageState(message);
        final part = MessagePart(
          part: 0,
          isInlineSticker: true,
          attachments: List.generate(
            scenario.count,
            (index) => Attachment(guid: 'synthetic-$index', mimeType: 'image/png'),
          ),
        );
        final tileKey = GlobalKey();
        final artwork = edgeArtwork();
        final content = clipMessagePartContent(
          part: part,
          clipper: TailClipper(isFromMe: scenario.fromMe, showTail: true, connectUpper: false, connectLower: false),
          child: Wrap(
            spacing: 4,
            children: List.generate(
              scenario.count,
              (_) => SizedBox(width: 100, height: 100, child: Image.memory(artwork, fit: BoxFit.contain)),
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MessageStateScope(
              messageState: state,
              child: Center(
                child: SizedBox(
                  width: 420,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: scenario.fromMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: RepaintBoundary(key: tileKey, child: content),
                        ),
                      ),
                      ErrorIndicatorObserver(
                        chat: Chat(guid: 'synthetic-chat'),
                        service: MessagesService('synthetic-chat'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() => precacheImage(MemoryImage(artwork), tester.element(find.byKey(tileKey))));
        await tester.pump();
        expect(find.byType(ClipPath), findsNothing);
        final tileRect = tester.getRect(find.byKey(tileKey));
        expect(tileRect.width, scenario.count * 100 + (scenario.count - 1) * 4);
        expect(tileRect.height, 100);
        if (scenario.failed) {
          final errorRect = tester.getRect(find.byType(IconButton));
          expect(tileRect.right, lessThanOrEqualTo(errorRect.left));
          expect(tileRect.overlaps(errorRect), isFalse);
        } else {
          expect(find.byType(IconButton), findsNothing);
        }
        final pixels = await snapshot(tester, tileKey);
        for (var index = 0; index < scenario.count; index++) {
          final x = index * 104;
          final rightEdge = (50 * tileRect.width.toInt() + x + 95) * 4;
          final leftEdge = (50 * tileRect.width.toInt() + x + 4) * 4;
          final transparentCorner = x * 4 + 3;
          final translucentCenter = (50 * tileRect.width.toInt() + x + 50) * 4 + 3;
          expect(pixels.getUint8(rightEdge), 255);
          expect(pixels.getUint8(rightEdge + 3), 255);
          expect(pixels.getUint8(leftEdge + 2), 255);
          expect(pixels.getUint8(leftEdge + 3), 255);
          expect(pixels.getUint8(transparentCorner), 0);
          expect(pixels.getUint8(translucentCenter), 128);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        state.onClose();
      });
    }
  }

  test('ordinary bubbles and mixed text or subject parts keep the same clipper', () {
    final clipper = TailClipper(isFromMe: true, showTail: true, connectUpper: false, connectLower: false);
    const child = SizedBox(width: 100, height: 100);
    for (final part in [
      MessagePart(part: 0, text: 'ordinary text'),
      MessagePart(part: 0, attachments: [Attachment(mimeType: 'image/png')]),
      MessagePart(part: 0, isInlineSticker: true, text: 'mixed text'),
      MessagePart(part: 0, isInlineSticker: true, subject: 'mixed subject'),
    ]) {
      final result = clipMessagePartContent(part: part, clipper: clipper, child: child);
      expect(result, isA<ClipPath>());
      expect((result as ClipPath).clipper, same(clipper));
      expect(result.child, same(child));
    }
  });

  test('Samsung outgoing bubble clip excludes the right-edge sticker marker', () {
    final clipper = TailClipper(isFromMe: true, showTail: true, connectUpper: false, connectLower: false);
    final path = clipper.getClip(const Size(100, 100));
    expect(path.contains(const Offset(95, 50)), isFalse);
    expect(path.contains(const Offset(50, 50)), isTrue);
  });
}
