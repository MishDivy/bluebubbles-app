import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:get/get.dart';

class StickerGrid extends StatelessWidget {
  final StickerBrowserController controller;
  const StickerGrid({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => Obx(
    () => GridView.builder(
      padding: const EdgeInsets.all(12),
      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, childAspectRatio: 0.9),
      itemCount: controller.entries.length + (controller.hasMore.value ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == controller.entries.length) {
          return Obx(
            () => TextButton(
              onPressed: controller.loading.value || controller.busy.value ? null : () => controller.load(),
              child: const Text('Load more'),
            ),
          );
        }
        final entry = controller.entries[index];
        return Obx(
          () => InkWell(
            onTap: controller.busy.value || controller.loading.value || controller.submitted.value ? null : () => controller.select(entry),
            child: Card(
              color: controller.selection.any((item) => item.uri == entry.uri)
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              child: Column(
                children: [
                  Expanded(
                    child: entry.directory
                        ? const Icon(Icons.folder, size: 48)
                        : StickerThumbnail(key: ValueKey(entry.uri), entry: entry, folders: controller.folders),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
