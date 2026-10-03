import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Inline animation playback with native decoding, sizing and image-cache ownership.
/// The source file is never rewritten, even if it specifies a finite loop count.
class LoopingFileImage extends FileImage {
  const LoopingFileImage(super.file, {super.scale});

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return super.loadImage(key, (buffer, {getTargetSize}) async {
      final codec = await decode(buffer, getTargetSize: getTargetSize);
      return _LoopingCodec(codec);
    });
  }
}

class _LoopingCodec implements ui.Codec {
  _LoopingCodec(this._codec);

  final ui.Codec _codec;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => -1;

  @override
  Future<ui.FrameInfo> getNextFrame() => _codec.getNextFrame();

  @override
  void dispose() => _codec.dispose();
}
