import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_thumbnail.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:flutter/material.dart';

class DraftStickerThumbnail extends StatelessWidget {
  final StickerFolderEntry? entry;
  final StickerFolderService folders;
  final VoidCallback onSelect;
  final VoidCallback onRemove;
  const DraftStickerThumbnail({
    super.key,
    required this.entry,
    required this.folders,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 44,
    child: entry == null
        ? const Icon(Icons.broken_image_outlined)
        : Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: onSelect,
                  child: StickerThumbnail(entry: entry!, folders: folders),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: 'Remove sticker',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(18, 18),
                    maximumSize: const Size(18, 18),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 18, height: 18),
                  iconSize: 14,
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ),
            ],
          ),
  );
}
