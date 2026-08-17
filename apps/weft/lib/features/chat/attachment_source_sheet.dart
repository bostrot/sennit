import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../services/attachments/attachment_picker.dart';

/// Asks where the attachment is coming from.
///
/// A sheet rather than opening a picker straight away because "attach" means
/// three different platform dialogs, and only one of them is the photo library.
/// Rows the platform cannot honour are not shown at all — a camera row on a Mac
/// mini is a button that can only disappoint.
///
/// Returns null when the user dismissed it.
Future<AttachmentPickSource?> showAttachmentSourceSheet(
  BuildContext context,
  AttachmentPicker picker,
) {
  const rows = [
    (
      source: AttachmentPickSource.media,
      icon: Icons.photo_library_rounded,
      label: 'Photo or video',
    ),
    (
      source: AttachmentPickSource.files,
      icon: Icons.attach_file_rounded,
      label: 'File',
    ),
    (
      source: AttachmentPickSource.camera,
      icon: Icons.photo_camera_rounded,
      label: 'Camera',
    ),
  ];

  return showModalBottomSheet<AttachmentPickSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.xl,
              vertical: WeftSpace.xs,
            ),
            child: Text(
              'Attach',
              style: context.text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final row in rows)
            if (picker.supports(row.source))
              ListTile(
                leading: Icon(row.icon),
                title: Text(row.label),
                onTap: () => Navigator.of(context).pop(row.source),
              ),
          const SizedBox(height: WeftSpace.sm),
        ],
      ),
    ),
  );
}
