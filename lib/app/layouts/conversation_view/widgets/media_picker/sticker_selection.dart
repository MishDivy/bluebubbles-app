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
            Text(selected.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Row(
              children: [
                Checkbox(
                  value: !controller.nativeSticker.value,
                  onChanged: controller.busy.value ? null : (value) => controller.nativeSticker.value = value != true,
                ),
                const Expanded(child: Text('Send as normal image')),
                FilledButton(
                  onPressed: controller.busy.value || (controller.nativeSticker.value && !controller.supported.value)
                      ? null
                      : controller.send,
                  child: Text(controller.nativeSticker.value ? 'Send sticker' : 'Send image'),
                ),
              ],
            ),
            const Text('Sends separately from your draft and reply. Up to 500 KiB and 618 × 618 per file.'),
          ],
        ),
      ),
    );
  });
}
