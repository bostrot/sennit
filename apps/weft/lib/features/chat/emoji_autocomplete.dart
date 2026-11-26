import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import '../../app/a11y.dart';
import '../../app/localisation.dart';
import 'emoji_picker_sheet.dart';
import 'emoji_shortcodes.dart';

/// How many rows the popup shows before it scrolls.
const int kEmojiPopupVisibleRows = 8;

const double _rowHeight = 32;
const double _popupWidth = 280;

/// `:thumbs` → 👍 in the composer, the way Slack, Teams and Mattermost do it.
///
/// Wraps the composer's field. Typing a colon and two characters opens a list
/// of matching emoji above the caret; ↑/↓ move through it, Return or Tab puts
/// the selected one in place of the `:query`, Escape closes it, and closing
/// the colon on an exact name converts without the list. While the list is
/// open it owns Return, so the key that picks an emoji never also sends.
///
/// The keys are taken here, *inside* the composer's own `Shortcuts`: a key
/// event travels from the focused field outwards, so this handler sees Return
/// before the binding that would send, and passes everything on untouched when
/// the list is closed.
///
/// Off with [enabled] false — on a phone, where the soft keyboard has its own
/// emoji and a popup would sit on top of it.
class EmojiShortcodeAutocomplete extends ConsumerStatefulWidget {
  const EmojiShortcodeAutocomplete({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.child,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;

  /// The field. Has to contain the `EditableText` [controller] drives, which
  /// is how the popup finds the caret.
  final Widget child;

  @override
  ConsumerState<EmojiShortcodeAutocomplete> createState() =>
      _EmojiShortcodeAutocompleteState();
}

class _EmojiShortcodeAutocompleteState
    extends ConsumerState<EmojiShortcodeAutocomplete> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _scroll = ScrollController();

  late TextEditingValue _last;
  ShortcodeQuery? _query;
  List<EmojiSuggestion> _suggestions = const [];
  int _selected = 0;

  /// Where the colon was when Escape closed the list. It stays closed for
  /// that `:query` however much more is typed, and opens again for the next.
  int? _dismissedAt;

  bool get _open => _query != null && _suggestions.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _last = widget.controller.value;
    widget.controller.addListener(_onText);
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(EmojiShortcodeAutocomplete old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _last = widget.controller.value;
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    if (!widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focusNode.removeListener(_onFocus);
    _scroll.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!widget.focusNode.hasFocus) _close();
  }

  void _onText() {
    final value = widget.controller.value;
    final previous = _last;
    _last = value;
    if (!widget.enabled) return;

    // A colon just typed after an exact name: convert in place.
    if (_typedColon(previous, value)) {
      final converted = convertClosedShortcode(
        value,
        skinTone: ref.read(reactionSkinToneProvider),
      );
      if (converted != null) {
        _last = converted;
        _close();
        // Re-enters this listener with `_last` already matching.
        widget.controller.value = converted;
        return;
      }
    }

    final query = shortcodeQueryAt(value);
    if (query == null || query.start == _dismissedAt) {
      if (query == null) _dismissedAt = null;
      _close();
      return;
    }
    if (query == _query) return;
    final suggestions = searchEmojiShortcodes(
      query.text,
      recents: ref.read(reactionRecentsProvider),
      // The tone chosen in the reaction picker, so 👍 comes out the same
      // whether it was picked there or typed here.
      skinTone: ref.read(reactionSkinToneProvider),
    );
    setState(() {
      _query = query;
      _suggestions = suggestions;
      _selected = 0;
    });
    if (_open) {
      _portal.show();
      _jumpToSelected();
      _announceSelected();
    } else {
      _portal.hide();
    }
  }

  static bool _typedColon(TextEditingValue before, TextEditingValue after) {
    final caret = after.selection.baseOffset;
    return after.selection.isCollapsed &&
        caret > 0 &&
        after.text.length == before.text.length + 1 &&
        after.text[caret - 1] == ':' &&
        before.selection.isCollapsed &&
        before.selection.baseOffset == caret - 1;
  }

  void _close() {
    if (_query == null && _suggestions.isEmpty) return;
    if (mounted) {
      setState(() {
        _query = null;
        _suggestions = const [];
        _selected = 0;
      });
    }
    _portal.hide();
  }

  void _insert(int index) {
    final query = _query;
    if (query == null || index >= _suggestions.length) return;
    final emoji = _suggestions[index].emoji;
    _close();
    final next = insertEmojiForQuery(widget.controller.value, query, emoji);
    _last = next;
    widget.controller.value = next;
    // Shared with the reaction picker's "Recent" row: an emoji typed is an
    // emoji reached for, and the next `:th` should find it first.
    ref.read(reactionRecentsProvider.notifier).note(emoji);
    widget.focusNode.requestFocus();
  }

  void _move(int delta) {
    final count = _suggestions.length;
    setState(() => _selected = (_selected + delta) % count);
    _jumpToSelected();
    _announceSelected();
  }

  void _jumpToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final top = _selected * _rowHeight;
      final bottom = top + _rowHeight;
      final view = _scroll.position.viewportDimension;
      final offset = _scroll.offset;
      if (top < offset) {
        _scroll.jumpTo(top);
      } else if (bottom > offset + view) {
        _scroll.jumpTo(bottom - view);
      }
    });
  }

  void _announceSelected() {
    if (!_open) return;
    final s = _suggestions[_selected];
    announce(
      context,
      context.l10n.emojiSuggestionAnnouncement(
        s.emoji,
        ':${s.name}:',
        _selected + 1,
        _suggestions.length,
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_open || event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final plain =
        !keys.isShiftPressed &&
        !keys.isControlPressed &&
        !keys.isMetaPressed &&
        !keys.isAltPressed;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (plain &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.tab)) {
      if (event is KeyDownEvent) _insert(_selected);
    } else if (key == LogicalKeyboardKey.escape) {
      _dismissedAt = _query?.start;
      _close();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// The caret at the query's colon, relative to this widget — so the list
  /// opens over what is being typed rather than at the start of a wide field.
  double _caretX(double width) {
    final box = context.findRenderObject();
    final query = _query;
    if (box is! RenderBox || query == null) return 0;
    RenderEditable? editable;
    void visit(RenderObject child) {
      if (editable != null) return;
      if (child is RenderEditable) {
        editable = child;
      } else {
        child.visitChildren(visit);
      }
    }

    box.visitChildren(visit);
    final found = editable;
    if (found == null || !found.attached) return 0;
    final caret = found.getLocalRectForCaret(TextPosition(offset: query.start));
    final x = box.globalToLocal(found.localToGlobal(caret.topLeft)).dx;
    return x.isFinite ? x : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildPopup,
          child: widget.child,
        ),
      ),
    );
  }

  Widget _buildPopup(BuildContext overlayContext) {
    if (!_open) return const SizedBox.shrink();
    final box = context.findRenderObject();
    final width = box is RenderBox && box.hasSize
        ? box.size.width
        : _popupWidth;
    final popupWidth = width < _popupWidth ? width : _popupWidth;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final caret = _caretX(width);
    // Starts at the caret and runs with the reading direction, held inside
    // the field so it never hangs off the window's edge.
    final dx = (rtl ? caret - popupWidth : caret).clamp(
      0.0,
      width - popupWidth,
    );
    final rows = _suggestions.length < kEmojiPopupVisibleRows
        ? _suggestions.length
        : kEmojiPopupVisibleRows;

    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: Offset(dx, -WeftSpace.xs),
      // The overlay hands its child the whole screen; the follower's bottom
      // left is the anchor, so the list sits in that corner whichever way the
      // text runs — `dx` already accounts for the direction.
      child: Align(
        alignment: Alignment.bottomLeft,
        // Part of the field's tap region: a click on a row is not a click
        // "outside" that would take focus from the composer first.
        child: TextFieldTapRegion(
          child: SizedBox(
            width: popupWidth,
            height: rows * _rowHeight + WeftSpace.xs * 2,
            child: Semantics(
              container: true,
              label: context.l10n.emojiSuggestionsLabel,
              explicitChildNodes: true,
              child: Material(
                color: context.colors.surfaceContainerHigh,
                elevation: 6,
                borderRadius: WeftRadius.allSm,
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: WeftSpace.xs),
                  itemExtent: _rowHeight,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, i) => _SuggestionRow(
                    suggestion: _suggestions[i],
                    selected: i == _selected,
                    onTap: () => _insert(i),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.selected,
    required this.onTap,
  });

  final EmojiSuggestion suggestion;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        // Never focusable: focus stays in the composer, which is where the
        // arrow keys and the next character have to keep going.
        canRequestFocus: false,
        onTap: onTap,
        child: Container(
          color: selected ? colors.secondaryContainer : null,
          padding: const EdgeInsets.symmetric(horizontal: WeftSpace.md),
          child: Row(
            children: [
              Text(suggestion.emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: WeftSpace.sm),
              Expanded(
                child: Text(
                  // l10n-ignore: an emoji shortcode, the same name in every language, as Slack and GitHub use it.
                  ':${suggestion.name}:',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Names are ASCII and read left to right in any locale,
                  // but sit against the emoji on whichever side that is.
                  textDirection: TextDirection.ltr,
                  textAlign: Directionality.of(context) == TextDirection.rtl
                      ? TextAlign.right
                      : TextAlign.left,
                  style: context.text.bodyMedium?.copyWith(
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
