import 'package:bluebubbles/app/layouts/conversation_view/pages/handlers/message_list_updates.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Message message(String guid, {bool fromMe = true, int error = 0}) =>
      Message(guid: guid, isFromMe: fromMe, error: error, text: 'same sticker');

  test('echo before HTTP coalesces only the exact real GUID and retains the incoming self-copy', () {
    final incoming = message('native-incoming', fromMe: false);
    final unrelated = message('native-unrelated');
    final failed = message('temp-one', error: 1);
    final echo = message('native-one');
    final visible = [incoming, echo, unrelated, failed];
    final confirmed = message('native-one');

    final update = updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one');

    expect(update, (updated: true, removedIndex: 1));
    expect(visible, [incoming, unrelated, confirmed]);
    expect(visible.where((item) => item.guid == 'native-one'), hasLength(1));
    expect(visible.last.error, 0);
  });

  test('a real echo following the temp slot coalesces without shifting the replacement incorrectly', () {
    final unrelated = message('native-unrelated');
    final visible = [message('temp-one'), unrelated, message('native-one')];
    final confirmed = message('native-one');

    expect(updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one'), (updated: true, removedIndex: 2));
    expect(visible, [confirmed, unrelated]);
  });

  for (final echoFirst in [true, false]) {
    test('state-mutated pending GUID coalesces when echo is ${echoFirst ? 'before' : 'after'} pending slot', () {
      final pending = message('temp-one', error: 1);
      final echo = message('native-one');
      final incoming = message('native-incoming', fromMe: false);
      final unrelated = message('native-unrelated');
      final visible = echoFirst ? [echo, incoming, unrelated, pending] : [pending, incoming, unrelated, echo];
      // MessageState updates this shared object before the visible-list callback.
      pending.guid = 'native-one';
      final confirmed = message('native-one');

      expect(updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one'), (updated: true, removedIndex: 3));
      expect(visible, [confirmed, incoming, unrelated]);
      expect(visible.where((item) => item.guid == 'native-one'), hasLength(1));
      expect(visible.first.error, 0);
    });
  }

  test('HTTP before echo promotes the temp once and a receipt updates the same slot', () {
    final incoming = message('native-incoming', fromMe: false);
    final visible = [message('temp-one'), incoming];
    final confirmed = message('native-one');
    expect(updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one'), (updated: true, removedIndex: null));

    final receipt = message('native-one')..isDelivered = true;
    expect(updateVisibleMessage(visible, receipt), (updated: true, removedIndex: null));
    expect(visible, [receipt, incoming]);
  });

  test('a repeated confirmed swap updates the real slot after the temp has gone', () {
    final incoming = message('native-incoming', fromMe: false);
    final visible = [message('native-one'), incoming];
    final confirmed = message('native-one');

    expect(updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one'), (updated: true, removedIndex: null));
    expect(visible, [confirmed, incoming]);
  });

  test('an unmatched update never removes an unrelated message', () {
    final unrelated = message('native-unrelated');
    final visible = [unrelated];

    expect(updateVisibleMessage(visible, message('native-one'), oldGuid: 'temp-one'), (
      updated: false,
      removedIndex: null,
    ));
    expect(visible, [unrelated]);
  });

  test('two identical pending sends remain distinct when only one is confirmed', () {
    final secondPending = message('temp-two');
    final visible = [message('native-one'), secondPending, message('temp-one')];
    final confirmed = message('native-one');

    expect(updateVisibleMessage(visible, confirmed, oldGuid: 'temp-one'), (updated: true, removedIndex: 0));
    expect(visible, [secondPending, confirmed]);
  });

  test('an update without a GUID cannot match an unrelated incomplete message', () {
    final incomplete = Message();
    final visible = [incomplete];

    expect(updateVisibleMessage(visible, Message()), (updated: false, removedIndex: null));
    expect(visible, [incomplete]);
  });

  for (final echoFirst in [true, false]) {
    for (final mutatePending in [false, true]) {
      testWidgets('keyed Sliver with loader coalesces ${echoFirst ? 'before' : 'after'} echo, mutated=$mutatePending', (
        tester,
      ) async {
        final listKey = GlobalKey<SliverAnimatedListState>();
        final messageKeys = <String, GlobalKey>{};
        final pending = message('temp-one', error: 1);
        final echo = message('native-one');
        final incoming = message('native-incoming', fromMe: false);
        final visible = echoFirst ? [echo, incoming, pending] : [pending, incoming, echo];
        await tester.pumpWidget(
          MaterialApp(
            home: CustomScrollView(
              slivers: [
                SliverAnimatedList(
                  key: listKey,
                  initialItemCount: visible.length + 1,
                  itemBuilder: (_, index, _) {
                    if (index == visible.length) return const Text('loading');
                    final guid = visible[index].guid!;
                    return Text(guid, key: messageKeys.putIfAbsent(guid, GlobalKey.new));
                  },
                ),
              ],
            ),
          ),
        );

        if (mutatePending) pending.guid = 'native-one';
        final update = updateVisibleMessage(visible, message('native-one'), oldGuid: 'temp-one');
        listKey.currentState!.removeItem(
          update.removedIndex!,
          (_, _) => const SizedBox.shrink(),
          duration: Duration.zero,
        );
        messageKeys.remove('temp-one');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('temp-one'), findsNothing);
        expect(find.text('native-one'), findsOneWidget);
        expect(find.text('native-incoming'), findsOneWidget);
        expect(find.byKey(messageKeys['native-one']!), findsOneWidget);
        expect(find.byKey(messageKeys['native-incoming']!), findsOneWidget);
        expect(find.text('loading'), findsOneWidget);
      });
    }
  }
}
