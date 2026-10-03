import 'dart:async';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/looping_image.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';

class StickerAssetController extends StatefulController {
  static int _nextId = 0;
  late final String tag = 'sticker-artwork:${_nextId++}';
  final Attachment attachment;
  final path = RxnString();
  bool _closed = false;
  StickerAssetController(this.attachment);

  Future<void> load() async {
    if (attachment.bytes != null) return;
    try {
      if (await FileSystemEntity.type(attachment.path) == FileSystemEntityType.notFound) {
        if (_closed) return;
        AttachmentDownloader.startDownload(attachment, onComplete: (_) async => prepare());
      } else {
        await prepare();
      }
    } catch (_) {
      // Leave a visible placeholder when the original is unavailable.
    }
  }

  Future<void> prepare() async {
    if (_closed) return;
    try {
      final compatible = await AttachmentsSvc.ensureImageCompatibility(attachment);
      if (!_closed) path.value = compatible;
    } catch (_) {
      // A missing attachment does not invalidate its parent bubble.
    }
  }

  @override
  void onClose() {
    _closed = true;
    updateWidgetFunctions.clear();
    super.onClose();
  }
}

/// Original sticker artwork for contexts without an AttachmentState scope.
class StickerAssetImage extends CustomStateful<StickerAssetController> {
  StickerAssetImage({super.key, required Attachment attachment})
    : super(parentController: StickerAssetController(attachment));
  @override
  State<StickerAssetImage> createState() => _StickerAssetImageState();
}

class _StickerAssetImageState extends CustomState<StickerAssetImage, void, StickerAssetController> {
  late final StickerAssetController _ownedController = widget.parentController;
  @override
  StickerAssetController get controller => _ownedController;

  @override
  void initState() {
    super.initState();
    tag = controller.tag;
    Get.put(controller, tag: controller.tag);
    unawaited(controller.load());
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final bytes = controller.attachment.bytes;
    final file = controller.path.value;
    if (bytes == null && file == null) return const Icon(Icons.image_outlined);
    final ImageProvider provider = bytes != null ? LoopingMemoryImage(bytes) : LoopingFileImage(File(file!));
    return Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
  });
}
