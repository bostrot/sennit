import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/localisation.dart';

/// What can be done with one link in a message: the sheet a long-press on any
/// link opens, and the one a tap on a phone number opens.
///
/// A phone number gets a sheet even for a tap because there is no single
/// right answer for it — call, text, or keep it for later are all as likely —
/// and dialling a number someone sent the moment it is touched is the one
/// guess that costs money when wrong.
///
/// [onOpen] is the caller's way of opening a web or mail link, so that the
/// label check it does before following a disguised link still runs; a phone
/// number is handed to the dialler or the messaging app from here.
Future<void> showLinkActions(
  BuildContext context, {
  required String url,
  required String label,
  required VoidCallback onOpen,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        _LinkActionsSheet(uri: uri, label: label, onOpen: onOpen),
  );
}

class _LinkActionsSheet extends StatelessWidget {
  const _LinkActionsSheet({
    required this.uri,
    required this.label,
    required this.onOpen,
  });

  final Uri uri;
  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = uri.scheme.toLowerCase();
    // What the reader would paste: the number or address as written, the url
    // as it resolves.
    final copyText = switch (scheme) {
      'tel' || 'mailto' => uri.path,
      _ => uri.toString(),
    };

    void close() => Navigator.of(context).pop();

    Future<void> copy() async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      close();
      await Clipboard.setData(ClipboardData(text: copyText));
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.chatCopiedToClipboard)),
      );
    }

    void launch(Uri target) {
      close();
      unawaited(
        launchUrl(
          target,
          mode: LaunchMode.externalApplication,
        ).onError((_, _) => false),
      );
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              WeftSpace.lg,
              0,
              WeftSpace.lg,
              WeftSpace.sm,
            ),
            child: Text(
              label.trim().isEmpty ? copyText : label.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.titleSmall,
            ),
          ),
          ...switch (scheme) {
            'tel' => [
              ListTile(
                leading: const Icon(Icons.call_rounded),
                title: Text(l10n.linkActionCall),
                onTap: () => launch(uri),
              ),
              ListTile(
                leading: const Icon(Icons.sms_outlined),
                title: Text(l10n.linkActionSendSms),
                onTap: () => launch(Uri(scheme: 'sms', path: uri.path)),
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(l10n.linkActionCopyNumber),
                onTap: copy,
              ),
            ],
            'mailto' => [
              ListTile(
                leading: const Icon(Icons.mail_outline_rounded),
                title: Text(l10n.linkActionWriteEmail),
                onTap: () {
                  close();
                  onOpen();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(l10n.linkActionCopyAddress),
                onTap: copy,
              ),
            ],
            _ => [
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: Text(l10n.linkActionOpen),
                onTap: () {
                  close();
                  onOpen();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(l10n.linkActionCopyLink),
                onTap: copy,
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text(l10n.commonShare),
                onTap: () {
                  close();
                  unawaited(SharePlus.instance.share(ShareParams(uri: uri)));
                },
              ),
            ],
          },
        ],
      ),
    );
  }
}
