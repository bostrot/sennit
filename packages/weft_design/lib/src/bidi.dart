/// Resolving the direction of a piece of *content*, as opposed to the app's.
///
/// A messenger is the one kind of app where the ambient `Directionality` is
/// routinely the wrong answer for the words on screen. An English UI carries
/// Hebrew messages; an Arabic UI carries English ones, and pasted links and code
/// are Latin in every locale. Laying a Hebrew sentence out left-to-right does
/// not merely look wrong — it puts the trailing full stop on the wrong end and
/// reorders any run of digits or Latin inside it, which changes what a phone
/// number or an address says.
///
/// So each message resolves its own base direction from its own text, and
/// nothing else in the app does: chrome, labels and buttons follow the locale.
/// [textDirectionOf] is the resolution and [WeftDirectionality] is the widget
/// that applies it, deliberately separate so the direction can also be handed
/// to a `Text.textDirection` or a `TextPainter` without building a subtree.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show Bidi;

/// The base direction [text] asks for, or null when it does not ask for one.
///
/// This is the Unicode bidirectional algorithm's *first strong character* rule
/// (UAX #9, P2/P3): the direction of a paragraph is the direction of the first
/// character in it that has one, and characters with no direction of their own —
/// digits, punctuation, spaces, emoji — are skipped rather than counted. So
/// "שלום, how are you?" is right-to-left, because that is the sentence Hebrew
/// punctuation and an English clause inside it; "Hello שלום" is left-to-right
/// for the mirror-image reason.
///
/// Deliberately not `Bidi.detectRtlDirectionality`, which is intl's *other*
/// heuristic: it counts RTL words against LTR ones and takes the majority. That
/// is the right rule for a page of search results whose language you are
/// guessing at, and the wrong one for a sentence somebody typed — under it a
/// Hebrew message containing two English brand names flips to left-to-right,
/// and the same message flips back when it is edited.
///
/// Returns null — rather than guessing left-to-right — for text with no strong
/// character at all: "👍", "42", ":)". Those have no direction to get wrong, and
/// null lets the caller inherit the ambient one instead of pinning a bubble full
/// of emoji to LTR inside an Arabic conversation.
TextDirection? textDirectionOf(String text) {
  if (text.isEmpty) return null;
  // Astral characters are dropped before asking, and emoji is why. `Bidi`'s
  // strong-character classes are written over UTF-16 code units and its
  // left-to-right range spans the surrogate block, so *every* character above
  // the BMP — every emoji — reads as strong Latin. Unfiltered, "👍" answers
  // left-to-right and "👍 שלום" answers left-to-right as well, which is the
  // wrong answer twice: the first has no direction and the second is Hebrew.
  final bmp = String.fromCharCodes(text.runes.where((rune) => rune <= 0xFFFF));
  if (bmp.isEmpty) return null;

  if (Bidi.startsWithRtl(bmp)) return TextDirection.rtl;
  // `startsWithRtl` is false both for "starts with Latin" and for "has no
  // strong character anywhere", and those are not the same answer — hence the
  // second question rather than an else.
  if (Bidi.startsWithLtr(bmp)) return TextDirection.ltr;
  return null;
}

/// Whether [text] reads right-to-left. A convenience over [textDirectionOf] for
/// call sites that already have a fallback in hand.
bool isRtlText(String text) => textDirectionOf(text) == TextDirection.rtl;

/// Applies [text]'s own direction to [child], and nothing else.
///
/// Wraps as tightly as possible on purpose. A bubble's *side* of the screen, the
/// tail it grows and the row of ticks under it all follow the reader's locale —
/// a Hebrew message in an English conversation does not jump to the other side
/// of the thread. Only the paragraph inside flips, which is exactly what every
/// other messenger does and what the reader expects.
///
/// When [text] has no direction of its own the subtree simply inherits, so this
/// is safe to wrap around anything.
class WeftDirectionality extends StatelessWidget {
  const WeftDirectionality({
    super.key,
    required this.text,
    required this.child,
  });

  /// The content whose direction decides the subtree's.
  final String text;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final direction = textDirectionOf(text);
    if (direction == null) return child;
    return Directionality(textDirection: direction, child: child);
  }
}

/// An [Icon] that mirrors under RTL, for the glyphs the SDK forgot to.
///
/// Most of Material's directional icons carry `matchTextDirection: true` and
/// flip themselves — `reply`, `send`, `forward`, `chevron_right`, `arrow_back`
/// all do, and wrapping *those* would double-mirror them and point them the
/// wrong way. This is for the ones that do not: `login_rounded` and
/// `logout_rounded` are arrows through a doorway, they mean "in" and "out", and
/// left-to-right is half of how they say it.
///
/// A [Transform] rather than an [IconData] rebuilt with `matchTextDirection`,
/// which would be the tidier fix and cannot be used: a non-constant `IconData`
/// anywhere in the tree is what makes `flutter build --tree-shake-icons` refuse
/// the release build, and Weft ships the whole icon font at that point instead.
/// The transform is paint-only, so the glyph's box, its tap target and its
/// semantics are all untouched.
class WeftMirroredIcon extends StatelessWidget {
  const WeftMirroredIcon(this.icon, {super.key, this.size, this.color});

  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(icon, size: size, color: color);
    if (Directionality.of(context) != TextDirection.rtl) return glyph;
    return Transform.scale(scaleX: -1, child: glyph);
  }
}

/// Pins [child] to left-to-right regardless of the ambient direction.
///
/// For the two things in Weft that are not prose and never mirror: a code block,
/// where the indentation *is* the meaning and a right-aligned brace is a bug
/// report waiting to happen, and any horizontally scrolling view over it, whose
/// scroll axis Flutter derives from `Directionality` and would otherwise start
/// at the right-hand end of every line.
class WeftLtr extends StatelessWidget {
  const WeftLtr({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: TextDirection.ltr, child: child);
}
