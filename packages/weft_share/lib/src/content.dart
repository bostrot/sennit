import 'package:meta/meta.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

/// One file a share is carrying, described by the two facts a *target* has to
/// be judged against.
///
/// Deliberately not an [AttachmentSource]: that type carries a header slice so
/// the pipeline can sniff and probe it, and ranking happens in two places where
/// no bytes are available at all — the launcher shortcut publisher, which runs
/// with no share in flight, and the iOS extension's picker, which is given a
/// slot list written before the share existed. What survives into both is the
/// resolved mime type and the length, so those are what this holds.
///
/// [ShareItem.fromSource] is the bridge for the case where bytes *are* to hand,
/// and it goes through [sniffMimeType] rather than the declared type on
/// purpose — a share intent that calls a 90 MB video `application/octet-stream`
/// must still be recognised as a video, or the capability filter below judges
/// it as a document and offers networks that will refuse it.
@immutable
class ShareItem {
  const ShareItem({
    required this.mimeType,
    required this.sizeBytes,
    this.filename,
  });

  /// Everything known about [source], resolved the way the pipeline resolves it.
  factory ShareItem.fromSource(AttachmentSource source) => ShareItem(
    mimeType: sniffMimeType(source),
    sizeBytes: source.sizeBytes,
    filename: source.basename,
  );

  /// The resolved type, not the declared one.
  final String mimeType;

  /// Length of the whole file.
  final int sizeBytes;

  /// Display name, when one is known. Ranking never reads it; it is here so a
  /// [ShareItem] can round-trip through the staging container without the file
  /// losing its name.
  final String? filename;

  /// What Weft would send this as.
  ///
  /// Voice notes are not distinguishable here — nothing shares a voice note
  /// *into* Weft — so this never returns [MessageKind.voice]. Capability tables
  /// still list it, because a forward from inside the app can be one.
  MessageKind get kind => messageKindFor(mimeType);

  @override
  bool operator ==(Object other) =>
      other is ShareItem &&
      other.mimeType == mimeType &&
      other.sizeBytes == sizeBytes &&
      other.filename == filename;

  @override
  int get hashCode => Object.hash(mimeType, sizeBytes, filename);

  @override
  String toString() => 'ShareItem($mimeType, $sizeBytes bytes)';
}

/// What a share is made of, as the ranker needs to see it.
///
/// Text and files are not exclusive: sharing a link from a browser with a
/// screenshot attached is one share with both. An empty [ShareContent] — the
/// default — means "nothing in flight", which is the state the Android shortcut
/// publisher is always in, and in which no capability filtering applies.
@immutable
class ShareContent {
  const ShareContent({this.text, this.items = const []});

  /// A share that is only a string: a URL, a selection, a note to self.
  const ShareContent.text(String this.text) : items = const [];

  /// A share of files, with no accompanying text.
  const ShareContent.files(this.items) : text = null;

  final String? text;
  final List<ShareItem> items;

  bool get isEmpty =>
      (text == null || text!.trim().isEmpty) && items.isEmpty;

  /// True when there is nothing to upload, so every target can take it.
  ///
  /// Every network Weft surfaces carries text. There is no such thing as a
  /// conversation that can be opened but not written to, so a text-only share
  /// never narrows the target list.
  bool get isTextOnly => items.isEmpty;

  /// The largest single file, which is what a per-attachment size cap applies
  /// to. Zero when there are no files.
  int get largestItemBytes =>
      items.fold(0, (max, item) => item.sizeBytes > max ? item.sizeBytes : max);

  /// Every kind present, so a capability check is one set comparison rather
  /// than a scan per item.
  Set<MessageKind> get kinds => {for (final item in items) item.kind};

  @override
  String toString() =>
      'ShareContent(${text == null ? 'no text' : '"${text!}"'}, '
      '${items.length} files)';
}
