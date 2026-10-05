import 'package:bluebubbles/database/models.dart';

/// Applies an update to the visible list, coalescing an explicit GUID swap.
({bool updated, int? removedIndex}) updateVisibleMessage(
  List<Message> messages,
  Message replacement, {
  String? oldGuid,
}) {
  if (replacement.guid == null) return (updated: false, removedIndex: null);
  var index = messages.indexWhere((message) => message.guid == (oldGuid ?? replacement.guid));
  if (index == -1) index = messages.indexWhere((message) => message.guid == replacement.guid);
  if (index == -1) return (updated: false, removedIndex: null);

  int? removedIndex;
  if (oldGuid != null && oldGuid != replacement.guid) {
    var collision = -1;
    for (var i = 0; i < messages.length; i++) {
      if (i != index && messages[i].guid == replacement.guid) {
        collision = i;
        break;
      }
    }
    if (collision != -1) {
      messages.removeAt(collision);
      removedIndex = collision;
      if (collision < index) index--;
    }
  }
  messages[index] = replacement;
  return (updated: true, removedIndex: removedIndex);
}
