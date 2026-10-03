import 'dart:math' as math;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_browser_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class StickerPlacementEditor extends StatelessWidget {
  final StickerBrowserController controller;
  const StickerPlacementEditor({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => Obx(() {
    final placement = controller.placement.value;
    final target = controller.targetPreview;
    final entry = controller.selected.value;
    if (placement == null || target == null || entry == null) {
      return const Text('A measured preview of this message part is required to place a sticker.');
    }
    final disabled = controller.busy.value || controller.submitted.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite || constraints.maxWidth <= 160) {
          return const Text('Widen the preview to edit placement.');
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Drag the sticker on the preview. Native sticker sizing may differ.'),
            SizedBox(
              height: 170,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!constraints.maxWidth.isFinite || constraints.maxWidth <= 32) return const SizedBox.shrink();
                  final ratio = math.min(
                    1.0,
                    math.min((constraints.maxWidth - 32) / target.size.width, 138 / target.size.height),
                  );
                  final width = target.size.width * ratio;
                  final height = target.size.height * ratio;
                  final left = (constraints.maxWidth - width) / 2;
                  final top = (170 - height) / 2;
                  final side = 100 * placement.scale * ratio;
                  return GestureDetector(
                    onPanUpdate: disabled
                        ? null
                        : (details) => controller.placement.value = controller.placement.value!.copyWith(
                            x: (controller.placement.value!.x + details.delta.dx / width).clamp(-4.0, 4.0),
                            y: (controller.placement.value!.y + details.delta.dy / height).clamp(-4.0, 4.0),
                          ),
                    child: ClipRect(
                      child: Stack(
                        children: [
                          Positioned(
                            left: left,
                            top: top,
                            width: width,
                            height: height,
                            child: Image.memory(target.bytes, fit: BoxFit.fill, semanticLabel: 'Selected message part'),
                          ),
                          Positioned(
                            left: left + placement.x * width - side / 2,
                            top: top + placement.y * height - side / 2,
                            width: side,
                            height: side,
                            child: Transform.rotate(
                              angle: placement.rotation,
                              child: StickerThumbnail(
                                key: ValueKey(entry.uri),
                                entry: entry,
                                folders: controller.folders,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            _PlacementSlider(
              label: 'Size ${placement.scale.toStringAsFixed(2)}×',
              value: placement.scale,
              min: 0.01,
              max: 4,
              onChanged: disabled ? null : (value) => controller.placement.value = placement.copyWith(scale: value),
            ),
            _PlacementSlider(
              label: 'Rotation ${(placement.rotation * 180 / math.pi).round()}°',
              value: placement.rotation,
              min: -2 * math.pi,
              max: 2 * math.pi,
              onChanged: disabled ? null : (value) => controller.placement.value = placement.copyWith(rotation: value),
            ),
            ExpansionTile(
              title: const Text('Position relative to the message'),
              children: [
                _PlacementSlider(
                  label: 'Horizontal ${placement.x.toStringAsFixed(2)}',
                  value: placement.x,
                  min: -4,
                  max: 4,
                  onChanged: disabled ? null : (value) => controller.placement.value = placement.copyWith(x: value),
                ),
                _PlacementSlider(
                  label: 'Vertical ${placement.y.toStringAsFixed(2)}',
                  value: placement.y,
                  min: -4,
                  max: 4,
                  onChanged: disabled ? null : (value) => controller.placement.value = placement.copyWith(y: value),
                ),
              ],
            ),
          ],
        );
      },
    );
  });
}

class _PlacementSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  const _PlacementSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 100, child: Text(label)),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    ],
  );
}
