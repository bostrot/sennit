import 'package:flutter/material.dart';

/// A text field whose name is stated in words, on the field's own node.
///
/// Every text field in Weft is named by its hint, and a hint stops being read
/// the moment a character is typed — so a reader who started a reply and then
/// typed had nothing left telling them what the field was. The fix everywhere
/// was the same annotation:
///
/// ```dart
/// Semantics(label: 'Message via Signal', textField: true, child: TextField(…))
/// ```
///
/// which is wrong in a way no widget test catches and TalkBack shows in one
/// swipe. A [Semantics] with the default `container: false` does not make a
/// node — it merges its label and its flags **upwards**, into the nearest
/// enclosing node. Around a field that sits at the bottom of a screen, the
/// nearest enclosing node is the screen: on a device, the chat view exported
/// the whole conversation — the app bar's sibling, every bubble, the scroll
/// view — as one edit box called "Message via Signal". Touch exploration
/// anywhere in the thread landed on it.
///
/// `container: true` is what stops the leak: it makes the annotation a node of
/// its own, bounded by the field it wraps, so there is nothing left to merge
/// upwards into.
///
/// [MergeSemantics] is the tempting alternative and it is wrong here. It folds
/// the annotation, the field's own hint *and* anything in the decoration into
/// one node — which for the two fields that carry an [IconButton] in their
/// `suffixIcon` means a node announced as "Search chats, Search chats, Clear
/// search, edit box", with the button's tooltip stuck to the field. A container
/// leaves the field and its decoration as the separate controls they are.
///
/// Use it for every labelled field. The wrapper is deliberately not optional
/// and deliberately not a helper function: the shape that leaks is the shape
/// someone reaches for by default, and it was the shape at all seven call sites
/// before this existed. How much damage it did depended only on what enclosed
/// it — in a dialog or an app bar the nearest ancestor node is about the size
/// of the field anyway, which is why the leak was invisible everywhere except
/// the one screen with a whole conversation above the field.
class WeftLabelledField extends StatelessWidget {
  const WeftLabelledField({
    super.key,
    required this.label,
    required this.child,
  });

  /// What the field is for, said whether or not it is empty.
  final String label;

  /// The field itself — a [TextField], or something wrapping one.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: label,
      textField: true,
      child: child,
    );
  }
}
