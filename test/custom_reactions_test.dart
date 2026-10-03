import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction_icon.dart';
import 'package:bluebubbles/database/io/message.dart';
import 'package:bluebubbles/database/io/chat.dart';
import 'package:bluebubbles/database/io/attachment.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/global/settings.dart';
import 'package:bluebubbles/app/state/message_state.dart';
import 'package:bluebubbles/helpers/types/extensions/extensions.dart';
import 'package:bluebubbles/helpers/ui/reaction_helpers.dart';
import 'package:bluebubbles/models/server_details.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/network/api/message_api.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:objectbox/objectbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Message event(String guid, String type, int time, {int? actor = 1, int part = 0, int? row, bool self = false}) =>
    Message(
      guid: guid,
      associatedMessageGuid: 'parent',
      associatedMessageType: type,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(time),
      handleId: actor,
      associatedMessagePart: part,
      originalROWID: row,
      isFromMe: self,
    );

void main() {
  final messageBox = _MessageBox();
  setUpAll(() {
    Database.messages = messageBox;
  });
  group('wire normalization and cache roundtrip', () {
    for (final emoji in ['🫡', '👍🏽', '👩🏽‍💻', '❤️‍🔥', '🇺🇸', '1️⃣', '🪿', '\u{1FAEA}']) {
      test('preserves $emoji and its removal', () {
        expect(ReactionTypes.isEmoji(emoji), isTrue);
        for (final type in ['emoji', 2006, '-emoji', 3006]) {
          final parsed = Message.fromMap({
            'guid': 'reaction',
            'associatedMessageGuid': 'p:2/parent',
            'associatedMessageType': type,
            'associatedMessageEmoji': emoji,
          });
          final expected = type == '-emoji' || type == 3006 ? '-$emoji' : emoji;
          expect(parsed.associatedMessageType, expected);
          expect(parsed.associatedMessageGuid, 'parent');
          expect(parsed.associatedMessagePart, 2);
          expect(Message.fromMap(parsed.toMap()).associatedMessageType, expected);
          expect(ReactionTypes.displayEmoji(expected), emoji);
        }
      });
    }
    test('keeps classic, sticker and unknown values distinct', () {
      for (var i = 0; i < 6; i++) {
        expect(ReactionTypes.fromServer(2000 + i, '🫡'), ReactionTypes.toList()[i]);
        expect(ReactionTypes.fromServer(3000 + i, '🫡'), '-${ReactionTypes.toList()[i]}');
      }
      expect(ReactionTypes.fromServer('love', '🫡'), 'love');
      expect(ReactionTypes.fromServer('sticker', null), 'sticker');
      expect(ReactionTypes.fromServer(2007, '🫡'), 'sticker-reaction');
      expect(ReactionTypes.fromServer(4000, null), '4000');
      expect(ReactionTypes.isReaction('sticker'), isFalse);
      expect(ReactionTypes.isReaction('2007'), isFalse);
    });
    test('malformed or missing emoji uses safe fallback', () {
      for (final value in [
        '',
        'a',
        'hello',
        '🫡🫡',
        ' 🫡',
        '🫡\n',
        '🫡\u202E',
        '🫡\u0301',
        '🏽',
        '🇺',
        '🫡‍a',
        '🫡️️',
        '🚗🏻',
        '😀🏽',
      ]) {
        expect(ReactionTypes.isEmoji(value), isFalse, reason: value);
        expect(ReactionTypes.fromServer('emoji', value), 'emoji');
      }
      expect(ReactionTypes.fromServer('emoji', null), 'emoji');
      expect(ReactionTypes.verb('emoji'), 'reacted to');
      expect(ReactionTypes.verb('-emoji'), 'removed a reaction from');
      expect(ReactionTypes.verb('unknown'), 'reacted to');
      expect(ReactionTypes.verb('🫡'), 'reacted with 🫡 to');
      expect(ReactionTypes.verb('-🫡'), 'removed 🫡 from');
      expect(ReactionTypes.verb('love'), 'loved');
    });
  });

  group('latest reaction per actor and part', () {
    test('replace, remove, out of order replay and duplicates', () {
      final first = event('a', 'love', 1);
      final changed = event('b', '🫡', 2);
      final removed = event('c', '-🫡', 3);
      expect(getUniqueReactionMessages([changed, first, changed]).map((m) => m.guid), ['b']);
      expect(getUniqueReactionMessages([removed, first, changed]), isEmpty);
      final readded = event('d', '👍🏽', 4);
      expect(getUniqueReactionMessages([removed, readded, first, changed]).single.guid, 'd');
    });
    test('same actor on different parts and different actors remain independent', () {
      final all = [
        event('a', '🫡', 1),
        event('b', '❤️‍🔥', 2, part: 1),
        event('c', 'like', 3, actor: 2),
        event('d', '-🫡', 4),
      ];
      expect(getUniqueReactionMessages(all).map((m) => m.guid), ['c', 'b']);
      expect(all.map((m) => m.guid), ['a', 'b', 'c', 'd']);
    });
    test('self, missing actors and equal timestamps are handled safely', () {
      final first = event('a', 'love', 1, row: 10);
      final removed = event('b', '-love', 1, row: 11);
      expect(getUniqueReactionMessages([removed, first]), isEmpty);
      final all = [
        event('c', '🫡', 2, actor: null),
        event('d', '🪿', 3, actor: null),
        event('e', 'love', 1, self: true),
        event('f', '-love', 4, self: true),
        event('g', 'like', 5),
      ];
      expect(getUniqueReactionMessages(all).map((m) => m.guid), ['g', 'd', 'c']);
    });
    test('partial duplicate upgrades to its hydrated emoji', () {
      expect(
        getUniqueReactionMessages([event('a', 'emoji', 1), event('a', '🫡', 1)]).single.associatedMessageType,
        '🫡',
      );
    });
    test('live state reconciles temp echo, duplicate echo, change and removal', () {
      GetIt.I.registerSingleton<SettingsService>(SettingsService()..settings = Settings());
      addTearDown(() => GetIt.I.unregister<SettingsService>());
      final state = MessageState(Message(guid: 'parent'));
      state.addAssociatedMessageInternal(event('temp-1', '🫡', 1, self: true));
      state.addAssociatedMessageInternal(event('a', '🫡', 1, self: true));
      state.addAssociatedMessageInternal(event('a', '🫡', 1, self: true));
      expect(state.associatedMessages.length, 1);
      state.addAssociatedMessageInternal(event('b', '❤️‍🔥', 2, self: true));
      expect(getUniqueReactionMessages(state.associatedMessages.toList()).single.associatedMessageType, '❤️‍🔥');
      state.addAssociatedMessageInternal(event('c', '-❤️‍🔥', 3, self: true));
      expect(getUniqueReactionMessages(state.associatedMessages.toList()), isEmpty);
    });
  });

  test('actual notification preview never interpolates null', () {
    messageBox.parent = Message(guid: 'parent', text: 'Hello');
    for (final type in ['love', '🫡', '-🫡', 'emoji', '-emoji', '2007']) {
      final text = event('a', type, 1, self: true).getNotificationText();
      expect(text, 'You ${ReactionTypes.verb(type)} “Hello”');
      expect(text, isNot(contains('null')));
    }
  });
  test('actual notifyReactions preference includes custom add/remove', () {
    final settings = SettingsService()..settings = Settings();
    GetIt.I.registerSingleton<SettingsService>(settings);
    addTearDown(() => GetIt.I.unregister<SettingsService>());
    final chat = Chat(guid: 'chat');
    settings.settings.notifyReactions.value = false;
    for (final type in ['love', '-love', '🫡', '-🫡', 'emoji']) {
      expect(chat.shouldMuteNotification(event('a', type, 1)), isTrue);
    }
    settings.settings.notifyReactions.value = true;
    expect(chat.shouldMuteNotification(event('a', '🫡', 1)), isFalse);
  });
  test('explicit sticker metadata retains HEIC alpha conversion choice', () {
    final sticker = Attachment.fromMap({'guid': 's', 'mimeType': 'image/heic', 'isSticker': true});
    expect(sticker.convertedExtension, 'png');
    expect(Attachment.fromMap(sticker.toMap()).convertedExtension, 'png');
    expect(Attachment(mimeType: 'image/heic').convertedExtension, 'jpg');
    expect(Attachment(mimeType: 'image/tiff').convertedExtension, 'png');
  });
  group('actual HTTP reaction transport with offline intercepted responses', () {
    test('explicit current helper capability sends raw add/change/removal and part', () async {
      final api = _OfflineApi(capability: true);
      for (final reaction in ['👩🏽‍💻', '🫡', '-🫡']) {
        await MessageApi(api).sendTapback('chat', 'Hello', 'parent', reaction, partIndex: 2);
        expect(api.requests.last.data['reaction'], reaction);
        expect(api.requests.last.data['partIndex'], 2);
      }
      expect(api.requests.map((r) => r.method), ['GET', 'POST', 'GET', 'POST', 'GET', 'POST']);
    });
    test('missing, false, or non-boolean capabilities prevent custom POST', () async {
      for (final capability in [null, false, 'true']) {
        final api = _OfflineApi(capability: capability);
        await expectLater(MessageApi(api).sendTapback('chat', 'Hello', 'parent', '🫡'), throwsUnsupportedError);
        expect(api.requests.map((r) => r.method), ['GET']);
      }
    });
    test('classic sends remain compatible and invalid strings never reach HTTP', () async {
      final api = _OfflineApi(capability: false);
      await MessageApi(api).sendTapback('chat', 'Hello', 'parent', 'love');
      expect(api.requests.map((r) => r.method), ['POST']);
      await expectLater(MessageApi(api).sendTapback('chat', 'Hello', 'parent', 'hello'), throwsArgumentError);
      expect(api.requests.length, 1);
    });
  });

  test('custom send capability defaults off regardless of server version', () {
    expect(const ServerDetails.empty().supportsCustomEmojiReactions, isFalse);
    expect(
      const ServerDetails(
        macOSVersion: 26,
        macOSMinorVersion: 0,
        serverVersion: '99.0.0',
        serverVersionCode: 999,
      ).supportsCustomEmojiReactions,
      isFalse,
    );
    expect(
      const ServerDetails(
        macOSVersion: 15,
        macOSMinorVersion: 0,
        serverVersion: '1.9.9',
        serverVersionCode: 298,
        customEmojiReactions: true,
      ).supportsCustomEmojiReactions,
      isTrue,
    );
  });

  testWidgets('custom and missing emoji render text in both display styles', (tester) async {
    for (final svg in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: ReactionIcon(type: '👩🏽‍💻', color: Colors.black, classicAsSvg: svg),
        ),
      );
      expect(find.text('👩🏽‍💻'), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: ReactionIcon(type: 'emoji', color: Colors.black, classicAsSvg: svg),
        ),
      );
      expect(find.text('💬'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('classic SVG path remains available for iOS', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ReactionIcon(type: 'love', color: Colors.pink, classicAsSvg: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

// Only the lookup boundary is doubled; getNotificationText's production
// formatting, Message parsing, state reconciliation and HTTP path all run.
class _MessageBox implements Box<Message> {
  Message? parent;
  @override
  QueryBuilder<Message> query([Condition<Message>? condition]) => _MessageQueryBuilder(parent);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MessageQueryBuilder implements QueryBuilder<Message> {
  _MessageQueryBuilder(this.parent);
  final Message? parent;
  @override
  Query<Message> build() => _MessageQuery(parent);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MessageQuery implements Query<Message> {
  _MessageQuery(this.parent);
  final Message? parent;
  @override
  Message? findFirst() => parent;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineApi implements BaseApi {
  _OfflineApi({required dynamic capability}) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'data': {
                  'privateApiCapabilities': {'customEmojiReactions': capability},
                },
              },
            ),
          );
        },
      ),
    );
  }
  final requests = <RequestOptions>[];
  @override
  final dio = Dio();
  @override
  String get origin => 'https://offline.invalid';
  @override
  String get apiRoot => '$origin/api/v1';
  @override
  Map<String, String> get headers => {};
  @override
  Map<String, dynamic> buildQueryParams([Map<String, dynamic> params = const {}]) => params;
  @override
  Future<Response> runApiGuarded(Future<Response> Function() func, {bool checkOrigin = true, bool retryOn502 = true}) =>
      func();
  @override
  Future<Response> returnSuccessOrError(Response response) async => response;
}
