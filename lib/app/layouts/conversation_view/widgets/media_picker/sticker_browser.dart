import 'dart:async';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_grid.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_selection.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_target_preview.dart';
import 'package:bluebubbles/app/wrappers/bb_app_bar.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class StickerBrowser extends CustomStateful<StickerBrowserController> {
  StickerBrowser({
    super.key,
    required Chat chat,
    StickerFolderService folders = const StickerFolderService(),
    NativeStickerTarget? target,
    StickerTargetPreview? targetPreview,
    bool Function()? isTargetCurrent,
    void Function(StickerFolderEntry)? insertIntoDraft,
  }) : super(
         parentController: StickerBrowserController(
           chat,
           folders,
           target: target,
           targetPreview: targetPreview,
           isTargetCurrent: isTargetCurrent,
           insertIntoDraft: insertIntoDraft,
         ),
       );

  @override
  State<StickerBrowser> createState() => _StickerBrowserState();
}

class _StickerBrowserState extends CustomState<StickerBrowser, void, StickerBrowserController> {
  @override
  void initState() {
    super.initState();
    tag = controller.tag;
    Get.put(controller, tag: controller.tag);
    unawaited(controller.initialize());
  }

  @override
  Widget build(BuildContext context) => BBScaffold(
    extendBodyBehindAppBar: false,
    appBar: BBAppBar(
      titleText: controller.target?.operation == NativeStickerOperation.placement
          ? 'Place sticker'
          : controller.target != null
          ? 'Sticker tapback'
          : 'Stickers',
      automaticallyImplyLeading: true,
      actions: [
        Obx(
          () => IconButton(
            tooltip: 'Refresh support and folder',
            icon: const Icon(Icons.refresh),
            onPressed: controller.busy.value || controller.loading.value
                ? null
                : () async {
                    await controller.checkCapability();
                    await controller.load(reset: true);
                  },
          ),
        ),
        Obx(
          () => IconButton(
            tooltip: 'Choose sticker folder',
            icon: const Icon(Icons.folder_open),
            onPressed: controller.busy.value ? null : controller.choose,
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        if (controller.insertIntoDraft != null)
          const Padding(padding: EdgeInsets.all(12), child: Text('Tap a sticker to insert it at the composer cursor. Rows and text with stickers currently support static PNG only. Animated stickers can be sent alone. Send from the conversation when your draft is ready.')),
        if (controller.target != null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('This sticker targets the selected message part. Your draft and reply stay unchanged.'),
          ),
        Obx(
          () => controller.folder.value != null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text(
                        'Choose a phone folder containing PNG, APNG, GIF or JPEG stickers. Subfolders stay separate.',
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: controller.busy.value ? null : controller.choose,
                        child: const Text('Choose sticker folder'),
                      ),
                    ],
                  ),
                ),
        ),
        Obx(
          () => controller.parents.isEmpty
              ? const SizedBox.shrink()
              : ListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: Text(controller.parents.last.name),
                  subtitle: const Text('Back to parent folder'),
                  onTap: controller.busy.value || controller.loading.value ? null : controller.up,
                ),
        ),
        Obx(
          () => controller.capabilityReason.value == null
              ? const SizedBox.shrink()
              : Padding(padding: const EdgeInsets.all(12), child: Text(controller.capabilityReason.value!)),
        ),
        Obx(
          () => controller.error.value == null
              ? const SizedBox.shrink()
              : Padding(padding: const EdgeInsets.all(12), child: Text(controller.error.value!)),
        ),
        Obx(() => controller.loading.value ? const LinearProgressIndicator() : const SizedBox.shrink()),
        Expanded(child: StickerGrid(controller: controller)),
        if (controller.insertIntoDraft == null) StickerSelection(controller: controller),
      ],
    ),
  );
}
