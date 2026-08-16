import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_search/weft_search.dart';

import '../../app/providers.dart';
import '../../app/search_providers.dart';
import '../chat/chat_view.dart';

/// Search across every conversation.
///
/// Results state which method found them — a semantic hit can contain none of
/// the typed words, and without the label that reads as a bug rather than the
/// feature it is.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  /// Pre-filled by `weft://search?q=…` deep links.
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final _controller = TextEditingController(
    text: widget.initialQuery ?? '',
  );

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery?.trim().isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Timer? _debounce;
  List<SearchResult> _results = const [];
  Set<ChatNetwork> _networkFilter = const {};
  bool _searching = false;
  bool _searchedOnce = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    // Debounced so every keystroke doesn't hit FTS5 and (worse) the embedding
    // endpoint, which may be remote and metered.
    _debounce = Timer(const Duration(milliseconds: 250), _run);
  }

  Future<void> _run() async {
    final text = _controller.text;
    if (text.trim().isEmpty && _networkFilter.isEmpty) {
      setState(() {
        _results = const [];
        _searchedOnce = false;
      });
      return;
    }

    setState(() => _searching = true);
    final results = await ref
        .read(searchEngineProvider)
        .search(SearchQuery(text: text, networks: _networkFilter));
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searchedOnce = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(chatRepositoryProvider);
    final semanticAvailable = ref.watch(searchEngineProvider).semanticAvailable;
    final backfill = ref.watch(embeddingBackfillProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
            filled: false,
          ),
        ),
        actions: [
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(WeftSpace.lg),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WeftSpace.lg,
              vertical: WeftSpace.sm,
            ),
            child: Wrap(
              spacing: WeftSpace.sm,
              children: [
                for (final network in repository.availableNetworks)
                  FilterChip(
                    avatar: NetworkGlyph(network: network, size: 16),
                    label: Text(network.label),
                    selected: _networkFilter.contains(network),
                    onSelected: (_) {
                      setState(() {
                        final next = {..._networkFilter};
                        if (!next.remove(network)) next.add(network);
                        _networkFilter = next;
                      });
                      _run();
                    },
                  ),
              ],
            ),
          ),
          if (!semanticAvailable)
            _Notice(
              icon: Icons.psychology_outlined,
              text:
                  'Keyword search only. Configure an embedding endpoint in '
                  'Settings to also search by meaning.',
            )
          else if (backfill != null && backfill.pending > 0)
            _Notice(
              icon: Icons.sync_rounded,
              text:
                  '${backfill.pending} messages still being embedded — '
                  'semantic results may be incomplete.',
              action: TextButton(
                onPressed: () async {
                  await backfill.drainAll(
                    onProgress: (_) {
                      if (mounted) setState(() {});
                    },
                  );
                },
                child: const Text('Backfill now'),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_results.isEmpty) {
      return Center(
        child: Text(
          _searchedOnce
              ? 'Nothing matched.'
              : 'Messages become searchable as their chats are opened.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: context.palette.divider),
      itemBuilder: (context, i) {
        final result = _results[i];
        return ListTile(
          leading: NetworkGlyph(network: result.network, size: 28),
          title: Text(
            result.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Row(
            children: [
              Text(DateFormat.yMMMd().add_Hm().format(result.timestamp)),
              const SizedBox(width: WeftSpace.sm),
              if (result.matchedSemantic && !result.matchedKeyword)
                _MethodTag(
                  label: 'meaning',
                  color: context.palette.mergedAccent,
                ),
              if (result.matchedKeyword && result.matchedSemantic)
                _MethodTag(label: 'both', color: context.colors.primary),
            ],
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatView(
                  chatId: result.chatId,
                  initialEventId: result.eventId,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _MethodTag extends StatelessWidget {
  const _MethodTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: WeftRadius.pill,
      ),
      child: Text(
        label,
        style: context.text.labelSmall?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: WeftSpace.lg),
      padding: const EdgeInsets.all(WeftSpace.md),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHigh,
        borderRadius: WeftRadius.allMd,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: WeftSpace.sm),
          Expanded(child: Text(text, style: context.text.bodySmall)),
          ?action,
        ],
      ),
    );
  }
}
