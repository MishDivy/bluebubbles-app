import 'dart:math' as math;

enum NativeStickerOperation { placement, tapback, removeTapback }

class NativeStickerTarget {
  final String serverIdentity;
  final String chatGuid;
  final String messageGuid;
  final int partIndex;
  final NativeStickerOperation operation;
  final String? reactionGuid;

  NativeStickerTarget({
    required this.serverIdentity,
    required this.chatGuid,
    required this.messageGuid,
    required this.partIndex,
    required this.operation,
    this.reactionGuid,
  }) {
    if (serverIdentity.isEmpty ||
        chatGuid.isEmpty ||
        messageGuid.isEmpty ||
        messageGuid.startsWith('temp') ||
        messageGuid.startsWith('error') ||
        partIndex < 0 ||
        partIndex > 2147483647) {
      throw ArgumentError('Choose a sent message part as the sticker target.');
    }
    if (operation == NativeStickerOperation.removeTapback &&
        (reactionGuid == null ||
            reactionGuid!.isEmpty ||
            reactionGuid!.startsWith('temp') ||
            reactionGuid!.startsWith('error'))) {
      throw ArgumentError('Removing a sticker tapback requires its confirmed reaction GUID.');
    }
    if (operation != NativeStickerOperation.removeTapback && reactionGuid != null) {
      throw ArgumentError('Only sticker tapback removal accepts a reaction GUID.');
    }
  }

  String get capability => operation == NativeStickerOperation.placement ? 'stickerPlacement' : 'stickerReactions';
  String get endpoint => switch (operation) {
    NativeStickerOperation.placement => 'send-sticker-placement',
    NativeStickerOperation.tapback => 'send-sticker-tapback',
    NativeStickerOperation.removeTapback => 'remove-sticker-tapback',
  };

  Map<String, dynamic> toMap() => {
    'serverIdentity': serverIdentity,
    'chatGuid': chatGuid,
    'messageGuid': messageGuid,
    'partIndex': partIndex,
    'operation': operation.name,
    'reactionGuid': ?reactionGuid,
  };

  factory NativeStickerTarget.fromMap(Map data) => NativeStickerTarget(
    serverIdentity: data['serverIdentity'] as String,
    chatGuid: data['chatGuid'] as String,
    messageGuid: data['messageGuid'] as String,
    partIndex: data['partIndex'] as int,
    operation: NativeStickerOperation.values.byName(data['operation'] as String),
    reactionGuid: data['reactionGuid'] as String?,
  );
}

class StickerPlacement {
  final double x;
  final double y;
  final double scale;
  final double rotation;
  final double parentWidth;

  StickerPlacement({
    required this.x,
    required this.y,
    required this.scale,
    required this.rotation,
    required this.parentWidth,
  }) {
    if (!_inRange(x, -4, 4) ||
        !_inRange(y, -4, 4) ||
        !_inRange(scale, 0.01, 4) ||
        !_inRange(rotation, -2 * math.pi, 2 * math.pi) ||
        !_inRange(parentWidth, 1, 4096)) {
      throw ArgumentError('Sticker placement is outside the supported bounds.');
    }
  }

  static bool _inRange(double value, double min, double max) => value.isFinite && value >= min && value <= max;

  StickerPlacement copyWith({double? x, double? y, double? scale, double? rotation}) => StickerPlacement(
    x: x ?? this.x,
    y: y ?? this.y,
    scale: scale ?? this.scale,
    rotation: rotation ?? this.rotation,
    parentWidth: parentWidth,
  );

  Map<String, double> toMap() => {'x': x, 'y': y, 'scale': scale, 'rotation': rotation, 'parentWidth': parentWidth};
  factory StickerPlacement.fromMap(Map data) => StickerPlacement(
    x: (data['x'] as num).toDouble(),
    y: (data['y'] as num).toDouble(),
    scale: (data['scale'] as num).toDouble(),
    rotation: (data['rotation'] as num).toDouble(),
    parentWidth: (data['parentWidth'] as num).toDouble(),
  );
}
