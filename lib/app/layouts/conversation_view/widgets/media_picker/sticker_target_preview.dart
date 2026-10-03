import 'dart:typed_data';
import 'package:flutter/widgets.dart';

class StickerTargetPreview {
  final Uint8List bytes;
  final Size size;
  StickerTargetPreview(Uint8List bytes, this.size) : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 1 ||
        size.width > 4096 ||
        size.height < 1 ||
        size.height > 4096 ||
        bytes.isEmpty ||
        bytes.length > 4 * 1024 * 1024) {
      throw ArgumentError('The target message cannot be previewed within the supported bounds.');
    }
  }
}
