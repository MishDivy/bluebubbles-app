import 'package:bluebubbles/helpers/types/helpers/reaction_type.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

/// Returns the actual emoji, or its removal form, through the existing send
/// queue. The caller checks the negotiated helper capability before opening.
Future<String?> showCustomReactionPicker(BuildContext context, {String? currentReaction}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ReactionTypes.isCustom(currentReaction))
              TextButton(
                onPressed: () => Navigator.of(context).pop('-$currentReaction'),
                child: Text('Remove ${ReactionTypes.displayEmoji(currentReaction)} reaction'),
              ),
            EmojiPicker(
              onEmojiSelected: (category, emoji) {
                if (!ReactionTypes.isEmoji(emoji.emoji)) return;
                Navigator.of(context).pop(currentReaction == emoji.emoji ? '-${emoji.emoji}' : emoji.emoji);
              },
              config: Config(
                height: 320,
                emojiViewConfig: EmojiViewConfig(columns: 8, backgroundColor: Theme.of(context).colorScheme.surface),
                bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
