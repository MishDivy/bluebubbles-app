import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class StickerSelection extends StatelessWidget {
  final StickerBrowserController controller;
  const StickerSelection({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => Obx(() {
    final selected = controller.selected.value;
    if (selected == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              controller.selection.length > 1
                  ? '${controller.selection.length} stickers, in selection order'
                  : selected.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Checkbox(
                  value: !controller.nativeSticker.value,
                  onChanged: controller.busy.value || controller.selection.length > 1
                      ? null
                      : (value) => controller.nativeSticker.value = value != true,
                ),
                const Expanded(child: Text('Send as normal image')),
                FilledButton(
                  onPressed: controller.busy.value || (controller.nativeSticker.value && !controller.canSendNative)
                      ? null
                      : controller.send,
                  child: Text(
                    controller.selection.length > 1
                        ? 'Send row'
                        : controller.nativeSticker.value
                        ? 'Send sticker'
                        : 'Send image',
                  ),
                ),
              ],
            ),
            const Text('Sends separately from your draft and reply. Up to 500 KiB and 618 × 618 per file.'),
            if (controller.selection.length > 1) const Text('Normal image sending is available with one selection.'),
            if (controller.selection.length > 1 && !controller.rowSupported.value)
              const Text('The connected helper has not enabled native sticker rows.'),
          ],
        ),
      ),
    );
  });
}
