import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'parse.dart';
import 'span.dart';

/// The line a bridge writes under buttons it could not carry across.
///
/// A business on WhatsApp can put buttons under a message: quick replies, a
/// link, a call. Matrix has no buttons, so the bridge writes them as a line of
/// text — `<Pick up> - <Deliver> - [Track](https://…)` — followed by this
/// sentence, verbatim and in English whatever the reader's language. Nothing
/// else in the event says the buttons were there: the content carries the kind
/// of business message and the template id, not the buttons, and there is no
/// way to send a button reply back. Reading them off the text is therefore the
/// only way to show them as buttons rather than as angle brackets.
const Set<String> bridgeButtonsMarkers = {
  'Use the WhatsApp app to click buttons',
};

/// One button a bridged business message carried.
@immutable
class BridgeButton {
  const BridgeButton({required this.label, this.url});

  final String label;

  /// Where the button goes, for a link or call button. Null for a quick reply,
  /// which can only be answered in the network's own app.
  final String? url;

  bool get answersInApp => url == null;

  @override
  bool operator ==(Object other) =>
      other is BridgeButton && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);

  @override
  String toString() => 'BridgeButton($label${url == null ? '' : ', $url'})';
}

/// A message as a bubble shows it: the words, and the buttons under them.
@immutable
class MessageContent {
  const MessageContent(this.document, {this.buttons = const []});

  final RichDocument document;

  /// Buttons read off a bridge's text fallback; see [splitBridgeButtons].
  final List<BridgeButton> buttons;
}

/// [parseMessageDocument] with any bridged buttons lifted out of the text.
MessageContent parseMessageContent({
  required String body,
  String? formattedBody,
}) => splitBridgeButtons(
  parseMessageDocument(body: body, formattedBody: formattedBody),
);

/// Takes the buttons line and its [bridgeButtonsMarkers] sentence out of
/// [document] and returns them as [BridgeButton]s.
///
/// Only a line made entirely of buttons is taken: every ` - `-separated piece
/// is either `<label>` or a link, and the very next line is the marker. A
/// message that merely quotes the sentence keeps it. Whatever followed the
/// marker — a template's footer — stays where it was.
MessageContent splitBridgeButtons(RichDocument document) {
  final top = _split(document.children);
  if (top != null) return MessageContent(RichDocument(top.$1), buttons: top.$2);

  final children = document.children;
  for (var i = 0; i < children.length; i++) {
    final block = children[i];
    if (block is! RichBlock || block.kind != RichBlockKind.paragraph) continue;
    final inner = _split(block.children);
    if (inner == null) continue;
    return MessageContent(
      RichDocument([
        ...children.take(i),
        if (inner.$1.isNotEmpty)
          RichBlock(kind: block.kind, children: inner.$1),
        ...children.skip(i + 1),
      ]),
      buttons: inner.$2,
    );
  }
  return MessageContent(document);
}

(List<RichSpan>, List<BridgeButton>)? _split(List<RichSpan> spans) {
  final lines = <List<RichSpan>>[[]];
  for (final span in spans) {
    if (span is RichLineBreak) {
      lines.add([]);
    } else {
      lines.last.add(span);
    }
  }

  final marker = lines.lastIndexWhere(
    (line) => bridgeButtonsMarkers.contains(_text(line).trim()),
  );
  if (marker < 1) return null;
  final buttons = _buttons(lines[marker - 1]);
  if (buttons == null) return null;

  final kept = [...lines.take(marker - 1), ...lines.skip(marker + 1)];
  // The bridge set the buttons off with a blank line on each side; with them
  // gone, the two blanks would meet as one tall gap.
  final at = marker - 1;
  if (at > 0 && at < kept.length && _blank(kept[at - 1]) && _blank(kept[at])) {
    kept.removeAt(at);
  }
  while (kept.isNotEmpty && _blank(kept.first)) {
    kept.removeAt(0);
  }
  while (kept.isNotEmpty && _blank(kept.last)) {
    kept.removeLast();
  }

  final out = <RichSpan>[];
  for (var i = 0; i < kept.length; i++) {
    if (i > 0) out.add(const RichLineBreak());
    out.addAll(kept[i]);
  }
  return (out, buttons);
}

final RegExp _quickReply = RegExp(r'^<([^<>]+)>$');

List<BridgeButton>? _buttons(List<RichSpan> line) {
  final links = line.whereType<RichLink>().toList();
  final pieces = _text(line).trim().split(' - ');
  final buttons = <BridgeButton>[];
  for (final raw in pieces) {
    final piece = raw.trim();
    final quick = _quickReply.firstMatch(piece);
    if (quick != null) {
      buttons.add(BridgeButton(label: quick.group(1)!.trim()));
      continue;
    }
    final link = links.firstWhereOrNull((l) => l.plainText.trim() == piece);
    if (link == null || piece.isEmpty) return null;
    buttons.add(BridgeButton(label: piece, url: link.url));
  }
  return buttons.isEmpty ? null : buttons;
}

String _text(List<RichSpan> line) => line.map((s) => s.plainText).join();

bool _blank(List<RichSpan> line) => _text(line).trim().isEmpty;
