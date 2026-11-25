import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../services/ai/translate_message.dart';

/// A message translated by the user's own model, with the language to put it
/// into one tap away.
///
/// [translate] asks the model; [onLanguage] remembers a language the user
/// picked, which is the one the next translation starts in. The original is
/// shown above the translation, cut short, so the sheet says what it is a
/// translation *of*.
Future<void> showTranslationSheet(
  BuildContext context, {
  required String text,
  required String language,
  required Future<TranslationResult> Function(String language) translate,
  required void Function(String language) onLanguage,
}) {
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _TranslationSheet(
      text: text,
      language: language,
      translate: translate,
      onLanguage: onLanguage,
    ),
  );
}

class _TranslationSheet extends StatefulWidget {
  const _TranslationSheet({
    required this.text,
    required this.language,
    required this.translate,
    required this.onLanguage,
  });

  final String text;
  final String language;
  final Future<TranslationResult> Function(String language) translate;
  final void Function(String language) onLanguage;

  @override
  State<_TranslationSheet> createState() => _TranslationSheetState();
}

class _TranslationSheetState extends State<_TranslationSheet> {
  late String _language = widget.language;
  TranslationResult? _result;

  /// Which request the sheet is showing, so a slow answer for a language the
  /// user has since moved away from does not replace the newer one.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final request = ++_request;
    setState(() => _result = null);
    final result = await widget.translate(_language);
    if (!mounted || request != _request) return;
    setState(() => _result = result);
    final text = result.text;
    if (text != null) announce(context, text);
  }

  void _pick(String? language) {
    if (language == null || language == _language) return;
    _language = language;
    widget.onLanguage(language);
    _run();
  }

  String _failure(TranslationFailure failure) => switch (failure) {
    TranslationFailure.timedOut => context.l10n.translationTimedOut,
    TranslationFailure.unreachable => context.l10n.translationUnreachable,
    TranslationFailure.empty => context.l10n.translationEmpty,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final result = _result;
    final translated = result?.text;
    final failure = result?.failure;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.translationTitle,
                      style: context.text.titleMedium,
                    ),
                  ),
                ),
                // Read as what it sets, not as a bare language name.
                Semantics(
                  label: l10n.translationLanguage,
                  child: DropdownButton<String>(
                    value: _language,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final MapEntry(:key, :value)
                          in kTranslationLanguages.entries)
                        DropdownMenuItem(value: key, child: Text(value)),
                    ],
                    onChanged: _pick,
                  ),
                ),
              ],
            ),
            const SizedBox(height: WeftSpace.sm),
            Text(
              widget.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            Divider(color: context.palette.divider, height: WeftSpace.xl),
            if (result == null)
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: WeftSpace.md),
                    Text(l10n.translationWorking),
                  ],
                ),
              )
            else if (translated != null) ...[
              SelectableText(translated, style: context.text.bodyLarge),
              const SizedBox(height: WeftSpace.md),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(l10n.commonCopy),
                  onPressed: () async {
                    final copied = l10n.chatCopiedToClipboard;
                    await Clipboard.setData(ClipboardData(text: translated));
                    if (context.mounted) showWeftMessage(context, copied);
                  },
                ),
              ),
            ] else ...[
              Text(
                _failure(failure ?? TranslationFailure.empty),
                style: TextStyle(color: context.colors.error),
              ),
              const SizedBox(height: WeftSpace.md),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _run,
                  child: Text(l10n.commonRetry),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
