import 'package:flutter/material.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';
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
  AttachmentPicker picker, {
  bool paperless = false,
}) {
  final l10n = context.l10n;
  final rows = [
    (
      source: AttachmentPickSource.media,
      icon: Icons.photo_library_rounded,
      label: l10n.attachSourceMedia,
    ),
    (
      source: AttachmentPickSource.files,
      icon: Icons.attach_file_rounded,
      label: l10n.attachSourceFiles,
    ),
    (
      source: AttachmentPickSource.camera,
      icon: Icons.photo_camera_rounded,
      label: l10n.attachSourceCamera,
    ),
    (
      source: AttachmentPickSource.location,
      icon: Icons.location_on_outlined,
      label: l10n.attachSourceLocation,
    ),
    (
      source: AttachmentPickSource.poll,
      icon: Icons.poll_outlined,
      label: l10n.attachSourcePoll,
    ),
    (
      source: AttachmentPickSource.calendar,
      icon: Icons.event_outlined,
      label: l10n.attachSourceCalendar,
    ),
    if (paperless)
      (
        source: AttachmentPickSource.paperless,
        icon: Icons.description_outlined,
        label: l10n.attachSourcePaperless,
      ),
  ];

  return showWeftPanel<AttachmentPickSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      // Scrollable now that the list has grown past three rows: on a short
      // screen (or a large text scale) the fixed column overflowed.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: WeftSpace.xl,
                vertical: WeftSpace.xs,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  l10n.attachSheetTitle,
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
    ),
  );
}
