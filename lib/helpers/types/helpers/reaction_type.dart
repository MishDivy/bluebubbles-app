import 'package:characters/characters.dart';
import 'package:unicode_emojis/unicode_emojis.dart';

/// Tapback identity shared by ingestion, persistence, previews, and rendering.
///
/// Like upstream BlueBubblesApp/bluebubbles-app#3162 (ZachGarcia42), custom
/// emojis use the existing type column, avoiding an ObjectBox schema change.
class ReactionTypes {
  // ignore: non_constant_identifier_names
  static const String LOVE = 'love';
  // ignore: non_constant_identifier_names
  static const String LIKE = 'like';
  // ignore: non_constant_identifier_names
  static const String DISLIKE = 'dislike';
  // ignore: non_constant_identifier_names
  static const String LAUGH = 'laugh';
  // ignore: non_constant_identifier_names
  static const String EMPHASIZE = 'emphasize';
  // ignore: non_constant_identifier_names
  static const String QUESTION = 'question';

  static List<String> toList() => [LOVE, LIKE, DISLIKE, LAUGH, EMPHASIZE, QUESTION];

  static final Map<String, String> reactionToVerb = {
    LOVE: 'loved',
    LIKE: 'liked',
    DISLIKE: 'disliked',
    LAUGH: 'laughed at',
    EMPHASIZE: 'emphasized',
    QUESTION: 'questioned',
    '-$LOVE': 'removed a heart from',
    '-$LIKE': 'removed a like from',
    '-$DISLIKE': 'removed a dislike from',
    '-$LAUGH': 'removed a laugh from',
    '-$EMPHASIZE': 'removed an exclamation from',
    '-$QUESTION': 'removed a question mark from',
  };

  static final Map<String, String> reactionToEmoji = {
    LOVE: '❤️',
    LIKE: '👍',
    DISLIKE: '👎',
    LAUGH: '😂',
    EMPHASIZE: '❗',
    QUESTION: '❓',
  };

  static final Map<String, String> emojiToReaction = {
    for (final entry in reactionToEmoji.entries) entry.value: entry.key,
  };

  static final Set<int> _emojiBases = {
    for (final emoji in UnicodeEmojis.allEmojis)
      if (emoji.emoji.replaceAll('\uFE0F', '').runes.length == 1) emoji.emoji.runes.first,
  };
  static final Set<int> _toneBases = {
    for (final emoji in UnicodeEmojis.allEmojis)
      if (emoji.skinVariations?.isNotEmpty == true) emoji.emoji.runes.first,
  };

  /// Validate a complete Unicode grapheme; never truncate ZWJ or tone sequences.
  static bool isEmoji(String? value) {
    if (value == null || value.isEmpty || value.length > 128 || value.characters.length != 1) return false;
    final runes = value.runes.toList();
    bool isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
    bool isTone(int r) => r >= 0x1F3FB && r <= 0x1F3FF;
    if (runes.every(isRegional)) return runes.length == 2;
    if (RegExp(r'^[#*0-9]\uFE0F?\u20E3$').hasMatch(value)) return true;
    // Subdivision flags use tag letters terminated by CANCEL TAG.
    if (runes.first == 0x1F3F4 &&
        runes.length > 2 &&
        runes.last == 0xE007F &&
        runes.sublist(1, runes.length - 1).every((r) => r >= 0xE0061 && r <= 0xE007A))
      return true;
    for (final component in value.split('\u200D')) {
      final part = component.runes.toList();
      if (part.isEmpty || isTone(part.first) || isRegional(part.first)) return false;
      // Accept new pictographs even before the picker's Unicode catalog updates.
      final base = part.first;
      if (!_emojiBases.contains(base) && !(base >= 0x1F300 && base <= 0x1FAFF)) return false;
      int index = 1;
      if (index < part.length && part[index] == 0xFE0F) index++;
      if (index < part.length && isTone(part[index])) {
        if (!_toneBases.contains(base)) return false;
        index++;
      }
      if (index != part.length) return false;
    }
    return true;
  }

  static String baseType(String? type) => type?.replaceFirst(RegExp(r'^-'), '') ?? '';
  static bool isRemoval(String? type) => type?.startsWith('-') == true;
  static bool isClassic(String? type) => toList().contains(baseType(type));
  static bool isCustom(String? type) => isEmoji(baseType(type));

  // Unknown associated events are retained by the model, but only actual
  // tapbacks (including an emoji whose payload is missing) belong in the row.
  static bool isReaction(String? type) => isClassic(type) || isCustom(type) || baseType(type) == 'emoji';

  /// Normalize both server metadata and already-normalized cached messages.
  static String? fromServer(dynamic type, dynamic emoji) {
    if (type == null) return null;
    String value = type.toString();
    final numeric = int.tryParse(value);
    if (numeric != null) {
      if (numeric >= 2000 && numeric <= 2005) value = toList()[numeric - 2000];
      if (numeric >= 3000 && numeric <= 3005) value = '-${toList()[numeric - 3000]}';
      if (numeric == 2006) value = 'emoji';
      if (numeric == 3006) value = '-emoji';
    }
    if (baseType(value) == 'emoji' && emoji is String && isEmoji(emoji)) {
      return '${isRemoval(value) ? '-' : ''}$emoji';
    }
    return value;
  }

  static String displayEmoji(String? type) {
    final value = baseType(type);
    return reactionToEmoji[value] ?? (isEmoji(value) ? value : '💬');
  }

  static String verb(String? type) {
    if (reactionToVerb.containsKey(type)) return reactionToVerb[type]!;
    if (isCustom(type)) {
      return isRemoval(type) ? 'removed ${baseType(type)} from' : 'reacted with ${baseType(type)} to';
    }
    if (baseType(type) == 'sticker') return 'added a sticker to';
    return isRemoval(type) ? 'removed a reaction from' : 'reacted to';
  }
}
