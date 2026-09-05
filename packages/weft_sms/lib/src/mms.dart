import 'package:meta/meta.dart';
import 'package:weft_attachments/weft_attachments.dart';
import 'package:weft_domain/weft_domain.dart';

/// The size ceiling Weft plans against by default: 300 KB.
///
/// This is Android's own `MmsConfig` default `maxMessageSize`, and it is the
/// figure to plan against rather than the largest a carrier might allow, because
/// the failure mode is asymmetric. Under-sending costs a little quality; over-
/// sending is rejected by the MMSC **silently** — the message sits in the outbox
/// with no error the handset ever sees, and the user finds out when the reply
/// never comes.
const int kMmsDefaultMaxBytes = 300 * 1024;

/// Payload the message spends on things that are not the attachment.
///
/// MMS headers, the per-part `Content-Type` and `Content-Location` fields, and
/// the SMIL presentation part every receiving handset expects. Two kilobytes is
/// generous for one or two parts, and being generous here is the point: a plan
/// that fits by 40 bytes on paper is a plan that fails on the wire.
const int kMmsOverheadBytes = 2 * 1024;

/// What MMS can actually carry.
///
/// Not a guess at what a modern phone can decode — this is the intersection that
/// survives an MMSC transcoder and lands on a ten-year-old handset. Anything
/// outside it is turned away here rather than sent and lost.
const Set<String> kMmsSupportedMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/bmp',
  'video/3gpp',
  'video/3gpp2',
  'video/mp4',
  'audio/amr',
  'audio/3gpp',
  'audio/mpeg',
  'audio/mp4',
  'audio/aac',
  'audio/ogg',
  'text/plain',
  'text/x-vcard',
  'text/vcard',
  'text/x-vcalendar',
};

/// Why an attachment will not go out as MMS.
enum MmsRejectionReason {
  /// Nothing to send — a zero-byte file, or a size the picker never filled in.
  empty,

  /// Over the message budget once [kMmsOverheadBytes] and any sibling parts are
  /// accounted for. Re-encoding smaller and planning again is a valid response.
  tooLarge,

  /// A type MMS does not carry, whatever its size.
  unsupportedType,
}

/// The outcome of planning one attachment for MMS: an [MmsPart] or an
/// [MmsRejection].
///
/// Sealed, for the same reason [UploadDecision] is: a caller that forgets the
/// rejection branch should fail to compile rather than hand the platform a part
/// the carrier will drop.
@immutable
sealed class MmsDecision {
  const MmsDecision();
}

/// An attachment that will not be sent, with a reason fit to show the user.
@immutable
final class MmsRejection extends MmsDecision {
  const MmsRejection({
    required this.reason,
    required this.message,
    this.mimeType,
    this.sizeBytes,
    this.budgetBytes,
  });

  final MmsRejectionReason reason;

  /// An English sentence, kept for logs and for a caller with no translations
  /// of its own. The app words [reason] instead, using [mimeType],
  /// [sizeBytes] and [budgetBytes] where it needs the facts — see
  /// `docs/architecture/l10n-pipeline.md`, "Packages and their words".
  final String message;

  /// What the file turned out to be, for the sentence the app writes.
  final String? mimeType;

  /// The file's size, and what a text message could have carried.
  final int? sizeBytes;
  final int? budgetBytes;

  @override
  String toString() => 'MmsRejection(${reason.name}: $message)';
}

/// One attachment, sized and typed for the MMS the platform will assemble.
///
/// The Kotlin side builds the actual PDU; everything decided here — the sniffed
/// type, whether it fits, what the part is called — is a decision rather than
/// I/O, and therefore lives where it can be tested.
@immutable
final class MmsPart extends MmsDecision {
  const MmsPart({
    required this.source,
    required this.mimeType,
    required this.kind,
    required this.contentLocation,
  });

  /// The file this part carries.
  final AttachmentSource source;

  /// The **sniffed** type, which is not necessarily the declared one. Carriers
  /// transcode on the announced `Content-Type`, so announcing a JPEG that is
  /// really a HEIC produces a part every receiver renders as a broken image.
  final String mimeType;

  final MessageKind kind;

  /// The part's `Content-Location`, and the basis of its `Content-ID`.
  ///
  /// Receiving handsets show this as the saved filename, and the SMIL part
  /// references it — so it has to exist and be free of path separators.
  final String contentLocation;

  /// `<content-location>`, the form the SMIL layout and the part header use.
  String get contentId => '<$contentLocation>';

  int get sizeBytes => source.sizeBytes;

  @override
  String toString() => 'MmsPart($contentLocation, $mimeType, $sizeBytes bytes)';
}

/// Decides whether [source] can ride an MMS, and as what.
///
/// [maxMessageBytes] is the carrier's ceiling for the whole message, not for
/// this part. [reservedBytes] is what the rest of the message already spends —
/// the sibling parts of a multi-attachment MMS — so the same function plans one
/// attachment or five without a second type; pass the running total of the parts
/// already planned.
///
/// Total: every input produces a decision, never an exception.
MmsDecision planMmsPart(
  AttachmentSource source, {
  int maxMessageBytes = kMmsDefaultMaxBytes,
  int reservedBytes = 0,
}) {
  if (source.isEmpty) {
    return const MmsRejection(
      reason: MmsRejectionReason.empty,
      message: 'This file is empty, so there is nothing to send.',
    );
  }

  final mimeType = sniffMimeType(source);
  if (!kMmsSupportedMimeTypes.contains(mimeType)) {
    return MmsRejection(
      reason: MmsRejectionReason.unsupportedType,
      message:
          'Text messaging cannot carry a $mimeType file — only pictures, '
          'video, audio and contact cards travel over MMS. Sending this on '
          'another network in this conversation will work.',
      mimeType: mimeType,
    );
  }

  final budget = maxMessageBytes - kMmsOverheadBytes - reservedBytes;
  if (source.sizeBytes > budget) {
    return MmsRejection(
      reason: MmsRejectionReason.tooLarge,
      message:
          'This file is ${_kilobytes(source.sizeBytes)} KB, and a text message '
          'can carry about ${_kilobytes(budget < 0 ? 0 : budget)} KB. Carriers '
          'drop anything larger without telling either of you.',
      sizeBytes: source.sizeBytes,
      budgetBytes: budget < 0 ? 0 : budget,
    );
  }

  final name = source.basename.trim();
  if (name.isEmpty) {
    return const MmsRejection(
      reason: MmsRejectionReason.unsupportedType,
      message: 'This file has no name, so it cannot be sent as a text message.',
    );
  }

  return MmsPart(
    source: source,
    mimeType: mimeType,
    kind: messageKindFor(mimeType),
    contentLocation: name,
  );
}

/// Bytes as whole kilobytes, for a user-facing sentence. MMS budgets are small
/// enough that a decimal place would be noise.
String _kilobytes(int bytes) => (bytes / 1024).round().toString();
