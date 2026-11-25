import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' as picker;
import 'package:image_picker_android/image_picker_android.dart'
    show ImagePickerAndroid;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../app/nickname_providers.dart';
import '../../app/providers.dart';

/// Picks a picture and returns its bytes, or null when the user backed out.
typedef NicknamePhotoPicker = Future<Uint8List?> Function();

/// Lets the user call [chat] something else, with a picture of their own —
/// for themselves only.
///
/// [original] is what the networks call the conversation, shown as the field's
/// hint so clearing the field visibly brings it back.
Future<void> showNicknameDialog(
  BuildContext context, {
  required Chat chat,
  required String original,
  NicknamePhotoPicker? pickPhoto,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _NicknameDialog(
      chat: chat,
      original: original,
      pickPhoto: pickPhoto ?? _pickPhoto,
    ),
  );
}

class _NicknameDialog extends ConsumerStatefulWidget {
  const _NicknameDialog({
    required this.chat,
    required this.original,
    required this.pickPhoto,
  });

  final Chat chat;
  final String original;
  final NicknamePhotoPicker pickPhoto;

  @override
  ConsumerState<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends ConsumerState<_NicknameDialog> {
  late final ChatNicknames _saved = ref.read(chatNicknamesProvider);
  late final TextEditingController _name = TextEditingController(
    text: _saved.nameFor(widget.chat) ?? '',
  );
  late String? _photo = _saved.photoFor(widget.chat);
  bool _picking = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto() async {
    setState(() => _picking = true);
    String? photo;
    try {
      final bytes = await widget.pickPhoto();
      if (bytes != null) photo = await avatarDataUri(bytes);
      if (bytes != null && photo == null && mounted) {
        showWeftMessage(context, context.l10n.nicknamePhotoFailed);
      }
    } on Object catch (error) {
      debugPrint('weft: nickname photo failed: $error');
      if (mounted) showWeftMessage(context, context.l10n.nicknamePhotoFailed);
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (photo != null) _photo = photo;
    });
  }

  void _save() {
    setChatNickname(ref, widget.chat, _name.text);
    setChatNicknamePhoto(ref, widget.chat, _photo);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shownName = _name.text.trim().isEmpty
        ? widget.original
        : _name.text.trim();
    return AlertDialog(
      title: Text(l10n.nicknameTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WeftAvatar(
              label: shownName,
              // Without a picture of their own the network's one shows, which
              // is the one "Remove photo" goes back to.
              imageUrl: _photo ?? _originalPhoto,
              imageHeaders: ref.watch(mediaHeadersProvider),
              size: 72,
              showNetworkBadge: false,
            ),
            const SizedBox(height: WeftSpace.sm),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: WeftSpace.sm,
              children: [
                TextButton.icon(
                  onPressed: _picking ? null : _choosePhoto,
                  icon: const Icon(Icons.photo_outlined),
                  label: Text(l10n.nicknameChoosePhoto),
                ),
                if (_photo != null)
                  TextButton.icon(
                    onPressed: () => setState(() => _photo = null),
                    icon: const Icon(Icons.hide_image_outlined),
                    label: Text(l10n.nicknameRemovePhoto),
                  ),
              ],
            ),
            const SizedBox(height: WeftSpace.sm),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: l10n.nicknameField,
                hintText: widget.original,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: WeftSpace.md),
            Text(
              l10n.nicknamePrivacy,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
      ],
    );
  }

  /// The picture the network gives this conversation, under any of ours.
  String? get _originalPhoto {
    final url = widget.chat.avatarUrl;
    return url == null || url.startsWith('data:') ? null : url;
  }
}

/// Edge of the square a nickname picture is stored at. Small on purpose:
/// it travels inside the device-sync document, and the largest place it is
/// drawn is the 96dp circle at the top of a profile.
const int kNicknamePhotoSize = 160;

/// [bytes], centre-cropped to a square and shrunk to [size], as a PNG `data:`
/// uri — or null when they are not a picture this platform can decode.
Future<String?> avatarDataUri(
  Uint8List bytes, {
  int size = kNicknamePhotoSize,
}) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } on Object {
    return null;
  }
  final source = (await codec.getNextFrame()).image;
  codec.dispose();

  final side = source.width < source.height ? source.width : source.height;
  final crop = ui.Rect.fromLTWH(
    (source.width - side) / 2,
    (source.height - side) / 2,
    side.toDouble(),
    side.toDouble(),
  );
  final edge = side < size ? side : size;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    source,
    crop,
    ui.Rect.fromLTWH(0, 0, edge.toDouble(), edge.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final shrunk = await recorder.endRecording().toImage(edge, edge);
  source.dispose();
  final png = await shrunk.toByteData(format: ui.ImageByteFormat.png);
  shrunk.dispose();
  if (png == null) return null;
  return 'data:image/png;base64,'
      '${base64Encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes))}';
}

Future<Uint8List?> _pickPhoto() async {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  // The system photo picker rather than the documents browser; see
  // `PlatformAttachmentPicker`.
  final implementation = ImagePickerPlatform.instance;
  if (implementation is ImagePickerAndroid) {
    implementation.useAndroidPhotoPicker = true;
  }
  final file = mobile
      ? await picker.ImagePicker().pickImage(
          source: picker.ImageSource.gallery,
          // The platform shrinks it on the way out; the rest is done above.
          maxWidth: 512,
          maxHeight: 512,
        )
      : await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: weftPlatformL10n().messageKindPhoto,
              extensions: const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'],
              mimeTypes: const ['image/*'],
              uniformTypeIdentifiers: const ['public.image'],
            ),
          ],
        );
  return file?.readAsBytes();
}
