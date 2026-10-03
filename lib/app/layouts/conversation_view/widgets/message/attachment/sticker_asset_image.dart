import 'dart:async';
import 'dart:typed_data';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/looping_image.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/sticker_preview_cache.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';
import 'package:get_it/get_it.dart';

class StickerAssetController extends StatefulController {
  static int _nextId = 0;
  late final String tag = 'sticker-artwork:${_nextId++}';
  final Attachment attachment;
  final path = RxnString();
  final preview = Rxn<Uint8List>();
  final error = RxnString();
  final loading = false.obs;
  StickerPreviewLease? _previewLease;
  bool get nativePreview => StickerHelper.requiresNativePreview(attachment);
  bool _closed = false;
  StickerAssetController(this.attachment);

  Future<void> load() async {
    if (nativePreview) return loadPreview();
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

  Future<void> loadPreview({bool retry = false}) async {
    if (_closed || loading.value) return;
    final origin = HttpSvc.origin;
    loading.value = true;
    error.value = null;
    if (retry) preview.value = null;
    final guid = attachment.guid;
    if (guid == null || guid.startsWith('temp') || guid.startsWith('error')) {
      loading.value = false;
      error.value = 'This sticker has no confirmed artwork transfer.';
      return;
    }
    final lease = AttachmentsSvc.stickerPreviews.acquire(origin, guid, HttpSvc.attachment, retry: retry);
    _previewLease = lease;
    try {
      final bytes = await lease.future;
      if (!_closed && HttpSvc.origin == origin) preview.value = bytes;
      if (!_closed && HttpSvc.origin != origin) error.value = 'The server changed. Open the sticker again.';
    } on StateError catch (failure) {
      if (!_closed) error.value = '${failure.message} The original is unchanged.';
    } catch (_) {
      if (!_closed) error.value = 'This server cannot preview the sticker. The original is unchanged.';
    } finally {
      lease.release();
      if (identical(_previewLease, lease)) _previewLease = null;
      if (!_closed) loading.value = false;
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
    _previewLease?.release();
    _previewLease = null;
    updateWidgetFunctions.clear();
    super.onClose();
  }
}

/// Original sticker artwork for contexts without an AttachmentState scope.
class StickerAssetImage extends CustomStateful<StickerAssetController> {
  final Widget Function(BuildContext, ImageProvider, Widget)? imageBuilder;
  StickerAssetImage({Key? key, required Attachment attachment, this.imageBuilder})
    : super(
        key: ValueKey((
          key,
          GetIt.I.isRegistered<HttpService>() ? HttpSvc.origin : '',
          attachment.guid ?? identityHashCode(attachment),
        )),
        parentController: StickerAssetController(attachment),
      );
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
  void dispose() {
    _ownedController.updateWidgetFunctions[StickerAssetImage]?.remove(updateWidget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final bytes = controller.nativePreview ? controller.preview.value : controller.attachment.bytes;
    final file = controller.path.value;
    if (controller.nativePreview && bytes == null) {
      if (controller.loading.value) {
        return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
      }
      return _previewUnavailable();
    }
    if (bytes == null && file == null) return const Icon(Icons.image_outlined);
    final ImageProvider provider = bytes != null ? LoopingMemoryImage(bytes) : LoopingFileImage(File(file!));
    if (widget.imageBuilder != null) return widget.imageBuilder!(context, provider, _previewUnavailable());
    return Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          controller.nativePreview ? _previewUnavailable() : const Icon(Icons.broken_image_outlined),
    );
  });

  Widget _previewUnavailable() => LayoutBuilder(
    builder: (context, constraints) {
      final reason = controller.error.value ?? 'The sticker preview could not be displayed. The original is unchanged.';
      void retry() => unawaited(controller.loadPreview(retry: true));
      if (constraints.maxWidth < 96 || constraints.maxHeight < 80) {
        return Tooltip(
          message: '$reason Tap to retry the preview.',
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            iconSize: 18,
            onPressed: retry,
            icon: const Icon(Icons.image_not_supported_outlined),
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Tooltip(
                message: reason,
                child: Text(reason, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
            ),
            TextButton(onPressed: retry, child: const Text('Retry preview')),
          ],
        ),
      );
    },
  );
}
