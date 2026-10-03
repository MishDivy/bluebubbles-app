import 'dart:async';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/looping_image.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class StickerThumbnail extends StatefulWidget {
  final StickerFolderEntry entry;
  final StickerFolderService folders;
  const StickerThumbnail({super.key, required this.entry, required this.folders});
  @override
  State<StickerThumbnail> createState() => _StickerThumbnailState();
}

class _StickerThumbnailState extends State<StickerThumbnail> {
  static int _nextId = 0;
  late final String _requestId = 'thumbnail:${_nextId++}';
  late final Future<Uint8List> _bytes;
  ImageProvider? _provider;
  @override
  void initState() {
    super.initState();
    _bytes = widget.folders.read(widget.entry, requestId: _requestId);
  }

  @override
  void dispose() {
    _provider?.evict();
    unawaited(widget.folders.cancelRead(_requestId));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const Icon(Icons.broken_image_outlined);
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      _provider ??= ResizeImage(LoopingMemoryImage(snapshot.data!), width: 128);
      return Image(
        image: _provider!,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const Icon(Icons.broken_image_outlined),
      );
    },
  );
}
