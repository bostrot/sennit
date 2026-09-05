import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import '../../services/integrations/paperless.dart';
import '../settings/integrations_screen.dart';

/// Searches the user's paperless-ngx archive and stages one document for
/// sending. Pops the staged [AttachmentSource], or null.
Future<AttachmentSource?> showPaperlessPickerSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final client = ref.read(paperlessProvider);
  if (client == null) return Future.value();
  return showWeftPanel<AttachmentSource>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _PaperlessPicker(client: client),
  );
}

class _PaperlessPicker extends StatefulWidget {
  const _PaperlessPicker({required this.client});

  final PaperlessClient client;

  @override
  State<_PaperlessPicker> createState() => _PaperlessPickerState();
}

class _PaperlessPickerState extends State<_PaperlessPicker> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<PaperlessDocument> _documents = const [];
  bool _loading = true;
  bool _staging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final documents = await widget.client.search(_query.text);
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _pick(PaperlessDocument document) async {
    setState(() => _staging = true);
    try {
      final source = await widget.client.stage(document);
      if (mounted) Navigator.of(context).pop(source);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _staging = false);
        showWeftMessage(context, context.l10n.paperlessFetchFailed('$error'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.paperlessSheetTitle,
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: WeftSpace.sm),
                WeftLabelledField(
                  label: context.l10n.paperlessSearchLabel,
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    onChanged: (_) {
                      _debounce?.cancel();
                      _debounce = Timer(
                        const Duration(milliseconds: 350),
                        _search,
                      );
                    },
                    decoration: InputDecoration(
                      hintText: context.l10n.paperlessSearchHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: WeftSpace.sm),
          if (_staging) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(WeftSpace.xl),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: controller,
                    itemCount: _documents.length,
                    itemBuilder: (context, index) {
                      final document = _documents[index];
                      return ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(document.title),
                        subtitle: Text(
                          [
                            ?document.correspondent,
                            if (document.created != null)
                              '${document.created!.year}-'
                                  '${document.created!.month.toString().padLeft(2, '0')}-'
                                  '${document.created!.day.toString().padLeft(2, '0')}',
                          ].join(' · '),
                        ),
                        enabled: !_staging,
                        onTap: () => _pick(document),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
