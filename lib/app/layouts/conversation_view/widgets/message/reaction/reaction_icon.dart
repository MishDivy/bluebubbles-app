import 'package:bluebubbles/helpers/types/helpers/reaction_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Only classic tapbacks have SVG assets. Custom and unknown reactions always
/// render text, including in the iOS skin and reaction details sheet.
class ReactionIcon extends StatelessWidget {
  const ReactionIcon({super.key, required this.type, required this.color, this.size = 18, this.classicAsSvg = false});

  final String? type;
  final Color color;
  final double size;
  final bool classicAsSvg;

  @override
  Widget build(BuildContext context) {
    if (classicAsSvg && ReactionTypes.isClassic(type)) {
      return SvgPicture.asset(
        'assets/reactions/${ReactionTypes.baseType(type)}-black.svg',
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    }
    return Center(
      child: Text(
        ReactionTypes.displayEmoji(type),
        style: TextStyle(fontSize: size, fontFamily: 'Apple Color Emoji', color: color),
        textAlign: TextAlign.center,
      ),
    );
  }
}
