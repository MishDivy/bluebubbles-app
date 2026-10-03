import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/sticker_asset_image.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class StickerHolder extends StatelessWidget {
  const StickerHolder({super.key, required this.stickerMessages, required this.controller});
  final Iterable<Message> stickerMessages;
  final ConversationViewController controller;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: NavigationSvc.width(context) * 0.6),
    child: Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final message in stickerMessages)
          for (final attachment in message.dbAttachments)
            _StickerPlacementTile(
              key: ValueKey('${message.guid}:${attachment.guid}'),
              placementGuid: message.guid,
              attachment: attachment,
              chatGuid: controller.chat.guid,
            ),
      ],
    ),
  );
}

class _StickerPlacementController extends StatefulController {
  static int _nextId = 0;
  late final String tag = 'sticker-placement:${_nextId++}';
  final String? placementGuid;
  final String chatGuid;
  late final String serverIdentity = HttpSvc.origin;
  final hidden = false.obs;
  final visible = true.obs;
  _StickerPlacementController(this.placementGuid, this.chatGuid);

  @override
  void onInit() {
    super.onInit();
    final guid = placementGuid;
    hidden.value = guid != null && PrefsSvc.messaging.isStickerPlacementHidden(serverIdentity, chatGuid, guid);
  }

  Future<void> hideLocally() async {
    final guid = placementGuid;
    if (guid == null) return;
    await PrefsSvc.messaging.hideStickerPlacement(serverIdentity, chatGuid, guid);
    if (!isClosed) hidden.value = true;
  }

  @override
  void onClose() {
    updateWidgetFunctions.clear();
    super.onClose();
  }
}

class _StickerPlacementTile extends CustomStateful<_StickerPlacementController> {
  final Attachment attachment;
  _StickerPlacementTile({super.key, required String? placementGuid, required this.attachment, required String chatGuid})
    : super(parentController: _StickerPlacementController(placementGuid, chatGuid));
  @override
  State<_StickerPlacementTile> createState() => _StickerPlacementTileState();
}

class _StickerPlacementTileState extends CustomState<_StickerPlacementTile, void, _StickerPlacementController> {
  late final _StickerPlacementController _ownedController = widget.parentController;
  @override
  _StickerPlacementController get controller => _ownedController;

  @override
  void initState() {
    super.initState();
    tag = controller.tag;
    Get.put(controller, tag: controller.tag);
  }

  Future<void> showDetails() async {
    final sticker = widget.attachment.metadata?['sticker'];
    final metadata = sticker is Map ? sticker : const {};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final key in ['accessibilityLabel', 'packName', 'sourceBundleId', 'packId'])
              if (metadata[key] is String && (metadata[key] as String).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(metadata[key] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
            ListTile(
              title: const Text('Hide this sticker on this device'),
              subtitle: const Text('This does not remove the sticker for anyone else.'),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await controller.hideLocally();
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save sticker visibility.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    if (controller.hidden.value) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => controller.visible.toggle(),
      onLongPress: showDetails,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: controller.visible.value ? 1 : 0.25,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 100, maxHeight: 100),
          child: StickerAssetImage(key: ValueKey(widget.attachment.guid), attachment: widget.attachment),
        ),
      ),
    );
  });
}
