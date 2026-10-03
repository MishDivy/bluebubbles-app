import 'package:bluebubbles/database/models.dart' hide Entity;
import 'package:bluebubbles/helpers/types/helpers/reaction_type.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';

export 'package:bluebubbles/helpers/types/helpers/reaction_type.dart';

/// Latest tapback per actor and message part, including removals. Work on a copy
/// so sorting and de-duplication never mutate an observable associated list.
List<Message> getUniqueReactionMessages(List<Message> messages) {
  final seenGuids = <String>{};
  final sorted = messages.toList()
    ..sort((a, b) {
      final byDate = (b.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        a.dateCreated ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
      if (byDate != 0) return byDate;
      // chat.db can give consecutive add/remove events the same timestamp.
      final byRow = (b.originalROWID ?? b.id ?? 0).compareTo(a.originalROWID ?? a.id ?? 0);
      if (byRow != 0) return byRow;
      // Prefer the hydrated echo if a partial and full payload race for a GUID.
      return (ReactionTypes.isCustom(b.associatedMessageType) ? 1 : 0).compareTo(
        ReactionTypes.isCustom(a.associatedMessageType) ? 1 : 0,
      );
    });
  final actors = <String>{};
  return sorted.where((msg) {
    if (StickerHelper.isUnconfirmedTargetedEvent(msg)) return false;
    if (msg.guid != null && !seenGuids.add(msg.guid!)) return false;
    final handle = msg.handleId != null && msg.handleId != 0 ? msg.handleId : msg.handleRelation.targetId;
    final actor = msg.isFromMe == true
        ? 'me'
        : handle != 0
        ? 'handle:$handle'
        : 'unknown:${msg.guid ?? identityHashCode(msg)}';
    final key = '${msg.associatedMessageGuid}:${msg.associatedMessagePart ?? 0}:$actor';
    return ReactionTypes.isReaction(msg.associatedMessageType) &&
        actors.add(key) &&
        !ReactionTypes.isRemoval(msg.associatedMessageType);
  }).toList();
}
