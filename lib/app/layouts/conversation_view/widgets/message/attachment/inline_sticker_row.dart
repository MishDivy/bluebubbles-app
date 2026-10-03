import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/attachment/attachment_holder.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/text/text_bubble.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter/material.dart';

class InlineStickerRow extends StatelessWidget {
  final MessagePart part;
  const InlineStickerRow({super.key, required this.part});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (part.text?.isNotEmpty == true || part.subject?.isNotEmpty == true)
        TextBubble(
          message: MessagePart(
            part: part.part,
            text: part.text,
            subject: part.subject,
            mentions: part.mentions,
            shouldRedact: part.shouldRedact,
          ),
        ),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        children: part.attachments
            .map(
              (attachment) => SizedBox(
                key: ValueKey(attachment.guid),
                width: 100,
                height: 100,
                child: AttachmentHolder(
                  message: MessagePart(part: part.part, attachments: [attachment], isInlineSticker: true),
                  transparentBackground: true,
                ),
              ),
            )
            .toList(),
      ),
    ],
  );
}
