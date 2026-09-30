import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:universal_io/io.dart';

class StickerHolder extends StatefulWidget {
  const StickerHolder({super.key, required this.stickerMessages, required this.controller});
  final Iterable<Message> stickerMessages;
  final ConversationViewController controller;

  @override
  State<StickerHolder> createState() => _StickerHolderState();
}

class _StickerHolderState extends State<StickerHolder> {
  Iterable<Message> get messages => widget.stickerMessages;

  bool _visible = true;
  bool _dismissed = false;
  final Map<String, String> _stickerPaths = {};

  @override
  void initState() {
    super.initState();
    loadStickers();
  }

  Future<void> loadStickers() async {
    for (Message msg in messages) {
      for (Attachment attachment in msg.dbAttachments) {
        final pathName = attachment.path;
        if (_stickerPaths.containsKey(pathName)) continue;

        if (await FileSystemEntity.type(pathName) == FileSystemEntityType.notFound) {
          AttachmentDownloader.startDownload(
            attachment,
            onComplete: (_) async {
              await _prepareSticker(attachment);
            },
          );
        } else {
          await _prepareSticker(attachment);
        }
      }
    }
  }

  Future<void> _prepareSticker(Attachment attachment) async {
    final compatible = await AttachmentsSvc.ensureImageCompatibility(attachment);
    if (mounted && compatible != null) setState(() => _stickerPaths[attachment.path] = compatible);
  }

  @override
  Widget build(BuildContext context) {
    if (_stickerPaths.isEmpty || _dismissed) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => setState(() => _visible = !_visible),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        setState(() => _dismissed = true);
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _visible ? 1.0 : 0.25,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: NavigationSvc.width(context) * 0.6),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: _stickerPaths.values
                .map(
                  (path) => ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100, maxHeight: 100),
                    child: Image.file(
                      File(path),
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.none,
                      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded) return child;
                        return AnimatedOpacity(
                          opacity: frame == null ? 0.0 : 1.0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                          child: child,
                        );
                      },
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}
