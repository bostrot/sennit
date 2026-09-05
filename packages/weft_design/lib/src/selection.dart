import 'package:flutter/material.dart';
// `SelectedContent` lives in the rendering layer and is not re-exported by
// `material.dart`.
import 'package:flutter/rendering.dart' show SelectedContent;

/// A region that copies as its own line when text is dragged across it.
///
/// [SelectionArea] concatenates its children with nothing between them. That is
/// right inside a sentence — a mention pill is a widget in the middle of a
/// paragraph, and a newline around "Anna" would be nonsense — and wrong
/// everywhere a line break is part of what the reader can see. Dragging across
/// two messages copies `Hello thereSee you at six`; a message with a paragraph
/// above a code block copies the two run together; a quote copies welded to the
/// line under it. The words are right and the shape is gone, which for a
/// conversation excerpt pasted into a mail is the whole of it.
///
/// So the break is stated where it belongs, by the widget that *is* a line.
/// Wrap a message, a paragraph, a code block; do not wrap a span inside one.
///
/// A no-op with no [SelectionArea] above it — on a phone, and in the previews
/// and sheets that render message bodies outside the timeline — where it adds
/// one inherited-widget lookup and no other cost.
class WeftSelectionLine extends StatefulWidget {
  const WeftSelectionLine({super.key, required this.child});

  final Widget child;

  @override
  State<WeftSelectionLine> createState() => _WeftSelectionLineState();
}

class _WeftSelectionLineState extends State<WeftSelectionLine> {
  /// Built lazily and kept, because a [SelectionContainer] whose delegate
  /// changes identity between builds tears down and re-registers everything
  /// under it — mid-drag, that is the selection disappearing under the cursor.
  _LineDelegate? _delegate;

  @override
  void dispose() {
    _delegate?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing above is collecting selections, so there is nothing to punctuate.
    if (SelectionContainer.maybeOf(context) == null) return widget.child;
    return SelectionContainer(
      delegate: _delegate ??= _LineDelegate(),
      child: widget.child,
    );
  }
}

/// Everything a region does, plus a trailing newline.
///
/// [StaticSelectionContainerDelegate] is the same delegate [SelectableRegion]
/// runs on its own subtree, so the geometry, the handles and the synthesised
/// edge events are the framework's and not a reimplementation of them. Only the
/// projection to text is ours.
class _LineDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final content = super.getSelectedContent();
    if (content == null) return null;
    final text = content.plainText;
    // Only when there is not one already: these nest — a message wraps its
    // blocks and each block wraps itself — and adding a break per level would
    // put a blank line between every two messages.
    if (text.isEmpty || text.endsWith('\n')) return content;
    return SelectedContent(plainText: '$text\n');
  }
}
