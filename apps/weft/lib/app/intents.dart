import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_attachments/weft_attachments.dart';

import '../services/attachments/attachment_picker.dart';

/// A deep link, resolved to what Weft should do with it.
@immutable
sealed class WeftLink {
  const WeftLink();

  /// Parses `weft://…` and `https://weft.bostrot.com/…` into an action.
  ///
  /// Recognised shapes, identical across both schemes so a shared web link and
  /// the app's own scheme behave the same:
  ///
  ///   `/chat/{roomOrChatId}`   → open that conversation
  ///   `/user/{matrixUserId}`   → open or create a DM
  ///   `/search?q={query}`      → open search pre-filled
  ///
  /// Returns null for anything unrecognised — an unknown link must not crash
  /// the router, because links arrive from outside the app's control.
  static WeftLink? parse(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;

    final isCustomScheme = uri.scheme == 'weft';
    final isAppLink =
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host == 'weft.bostrot.com';
    if (!isCustomScheme && !isAppLink) return null;

    // weft://chat/x parses `chat` as the host; https puts it in the path.
    final segments = [
      if (isCustomScheme && uri.host.isNotEmpty) uri.host,
      ...uri.pathSegments,
    ];
    if (segments.isEmpty) return const OpenInboxLink();

    switch (segments.first) {
      case 'chat':
        if (segments.length < 2 || segments[1].isEmpty) return null;
        // Room ids contain `!` and `:` which arrive percent-encoded.
        return OpenChatLink(Uri.decodeComponent(segments[1]));
      case 'user':
        if (segments.length < 2 || segments[1].isEmpty) return null;
        return OpenUserLink(Uri.decodeComponent(segments[1]));
      case 'search':
        return OpenSearchLink(uri.queryParameters['q'] ?? '');
      default:
        return null;
    }
  }
}

class OpenInboxLink extends WeftLink {
  const OpenInboxLink();
}

class OpenChatLink extends WeftLink {
  const OpenChatLink(this.chatId);

  final String chatId;
}

class OpenUserLink extends WeftLink {
  const OpenUserLink(this.userId);

  final String userId;
}

class OpenSearchLink extends WeftLink {
  const OpenSearchLink(this.query);

  final String query;
}

/// Content another app shared into Weft.
@immutable
class SharedPayload {
  const SharedPayload({this.text, this.mimeType, this.uris = const []});

  final String? text;

  /// The type the *intent* declared, which describes the batch rather than any
  /// one file — a share of a photo and a PDF together arrives as `*/*`. Kept as
  /// the fallback hint for a URI whose own provider says nothing; the sniffer
  /// treats it as the guess it is.
  final String? mimeType;

  /// Platform content URIs. Their bytes are only reachable through
  /// [WeftIntents.stageSharedFile] — a content:// grant cannot be turned into a
  /// file path, and the grant itself dies with the activity.
  final List<String> uris;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && uris.isEmpty;

  static SharedPayload fromMap(Map<Object?, Object?> map) => SharedPayload(
    text: map['text'] as String?,
    mimeType: map['mimeType'] as String?,
    uris: [
      for (final uri in (map['uris'] as List?) ?? const [])
        if (uri is String) uri,
    ],
  );
}

/// Largest file Weft will take from a share intent.
///
/// The composer has no such cap — it opens the file the user picked where it
/// already is, and lets the homeserver be the one to say no. A share cannot:
/// the `content://` grant it arrives as has to be *copied* into the app's cache
/// before it can be read twice, and a phone with 3 GB free is not the place to
/// make a second copy of a two-hour video. 100 MiB is twice Synapse's default
/// `max_upload_size`, so nearly everything refused here would have been refused
/// by the server a minute later anyway — but refused after the copy, and with a
/// less useful sentence.
const int kMaxSharedFileBytes = 100 * 1024 * 1024;

/// What a content provider says about a shared file before it is opened.
@immutable
class SharedFileMeta {
  const SharedFileMeta({required this.name, this.sizeBytes, this.mimeType});

  /// The provider's display name — `IMG_4021.jpg`, not the row id in the URI.
  final String name;

  /// Null when the provider does not report one, which is legal and common for
  /// a stream with no backing file. Not zero: "unknown" and "empty" lead to
  /// opposite decisions.
  final int? sizeBytes;

  final String? mimeType;

  static SharedFileMeta? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final name = (map['name'] as String?)?.trim();
    if (name == null || name.isEmpty) return null;
    final size = map['size'];
    return SharedFileMeta(
      name: name,
      sizeBytes: size is int && size >= 0 ? size : null,
      mimeType: map['mimeType'] as String?,
    );
  }
}

/// A share intent's files, after the ones that cannot be sent were set aside.
@immutable
class ResolvedShare {
  const ResolvedShare({this.sources = const [], this.problems = const []});

  /// Ready to hand to `sendAttachment`, in the order they were shared.
  final List<AttachmentSource> sources;

  /// One user-facing sentence per file that will not be sent. Already written
  /// for the user and shown as-is, in the same register as an
  /// `AttachmentRejectedException`'s message.
  final List<String> problems;

  bool get isEmpty => sources.isEmpty && problems.isEmpty;
}

/// Turns a share intent's URIs into files that can be sent.
///
/// An interface for the same reason [AttachmentPicker] is one, and with the same
/// consequence: behind it are a method channel *and* a read of the file the
/// platform has just written, and a widget test's clock is fake while its
/// filesystem is not. Without the seam the share sheet — the thumbnails, the
/// summary line, the send — would be unreachable from `flutter test`, and only
/// the resolution itself would be covered. The real implementation is
/// [WeftIntents], tested against real files where a real event loop exists.
abstract interface class SharedFileResolver {
  Future<ResolvedShare> resolveSharedFiles(SharedPayload payload);
}

/// Receives share-ins and deep links from the platform side.
///
/// Cold starts are handled by replay: the platform holds the launching intent
/// until Dart asks for it, because a share arriving via cold start fires
/// before any Dart code is listening.
class WeftIntents implements SharedFileResolver {
  WeftIntents({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting int maxFileBytes = kMaxSharedFileBytes,
  }) : _channel = channel ?? const MethodChannel('com.bostrot.weft/intents'),
       _maxFileBytes = maxFileBytes {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

  /// Always [kMaxSharedFileBytes] in the app. Lowered only by tests, so the
  /// branch where a provider under-reports a size — caught by the staged copy —
  /// can be exercised without writing a hundred megabytes to a disk.
  final int _maxFileBytes;

  void Function(WeftLink link)? onLink;
  void Function(SharedPayload payload)? onShare;

  /// Fetches and dispatches the intent that launched the app, if any.
  Future<void> deliverInitialIntent() async {
    try {
      final initial = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getInitialIntent',
      );
      if (initial != null) _dispatch(initial);
    } on MissingPluginException {
      // Desktop platforms have no intent channel; links arrive differently.
    } on PlatformException {
      // A malformed launching intent must not break startup.
    }
  }

  /// What the content provider says about [uri], without opening it.
  ///
  /// Asked *before* anything is read because the answer decides whether reading
  /// is worth starting at all: a 2 GB video from the gallery has to be turned
  /// away with a sentence, not by copying two gigabytes into the cache first and
  /// discovering the problem afterwards.
  ///
  /// Null when the provider will not answer — which is not a failure, only a
  /// reason to fall back to what the URI itself says.
  Future<SharedFileMeta?> sharedFileMeta(String uri) async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'readSharedFileMeta',
        {'uri': uri},
      );
      return SharedFileMeta.fromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Copies the bytes behind [uri] into a file Weft can open later, returning
  /// its path.
  ///
  /// A path rather than the bytes, which is what this used to hand back. Two
  /// reasons, and the second is the one that matters: the upload path opens
  /// [AttachmentSource.filename] once *per attempt*, so bytes over the channel
  /// would have to be written to a file here anyway — and to get there they
  /// would first sit in memory whole, on both sides of the channel at once. A
  /// 200 MB video does not survive that on a phone. The platform side streams.
  ///
  /// The copy is also what makes the grant durable: a `content://` permission is
  /// scoped to the activity that received the intent, so a share left in the
  /// upload queue while the user does something else would otherwise fail on a
  /// retry with no way to recover it.
  Future<String?> stageSharedFile(String uri) async {
    try {
      return await _channel.invokeMethod<String>('stageSharedFile', {
        'uri': uri,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Turns a share intent's URIs into files that can actually be sent.
  ///
  /// The whole point of the pass: everything downstream of here — the preview,
  /// the plan, the upload, the bubble — is written against [AttachmentSource]
  /// and knows nothing about intents. Once the URIs are resolved, a share is
  /// simply the composer's send path with the picker skipped.
  ///
  /// Never throws and never partially fails: a file that cannot be staged
  /// becomes a sentence in [ResolvedShare.problems] while the rest of the batch
  /// goes through. Sharing eight photos and losing all eight because the ninth
  /// was a broken cloud-storage stub would be the worse trade.
  @override
  Future<ResolvedShare> resolveSharedFiles(SharedPayload payload) async {
    final sources = <AttachmentSource>[];
    final problems = <String>[];

    for (final uri in payload.uris) {
      final meta = await sharedFileMeta(uri);
      final name = meta?.name ?? _nameFromUri(uri);

      // Announced size first: this is the check that exists to happen before a
      // single byte moves.
      final announced = meta?.sizeBytes;
      if (announced != null && announced > _maxFileBytes) {
        problems.add(_tooLarge(name, announced));
        continue;
      }

      final path = await stageSharedFile(uri);
      if (path == null) {
        problems.add('$name could not be read.');
        continue;
      }

      try {
        final source = await attachmentSourceForFile(
          // The per-file type from the content resolver beats the intent's,
          // which describes the whole batch; both are hints and `sniffMimeType`
          // prefers the bytes over either.
          XFile(path, mimeType: meta?.mimeType ?? payload.mimeType, name: name),
        );
        // The provider is allowed not to know a size, and some lie. The staged
        // copy is the first authority on the question, so the cap is applied a
        // second time — and the copy is thrown away rather than left in the
        // cache for a file that will not be sent.
        if (source.sizeBytes > _maxFileBytes) {
          await _discardStaged(path);
          problems.add(_tooLarge(name, source.sizeBytes));
          continue;
        }
        sources.add(source);
      } on Object catch (error) {
        // Deliberately Object: this reads a file the platform has just written,
        // and every way that fails is the same answer to the user.
        debugPrint('weft: shared file $name could not be read: $error');
        problems.add('$name could not be read.');
      }
    }

    return ResolvedShare(sources: sources, problems: problems);
  }

  static Future<void> _discardStaged(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // The cache is the platform's to reclaim; a copy left behind is untidy,
      // not broken.
    }
  }

  String _tooLarge(String name, int sizeBytes) =>
      '$name is ${formatAttachmentSize(sizeBytes)}, which is too large to '
      'share — the limit is ${formatAttachmentSize(_maxFileBytes)}.';

  /// A last-resort name for a URI whose provider offered none.
  ///
  /// A `content://` URI's last segment is usually an opaque row id, which makes
  /// a poor filename but a better one than nothing: it is what the send would
  /// otherwise be rejected for.
  static String _nameFromUri(String uri) {
    final segments = Uri.tryParse(uri)?.pathSegments ?? const [];
    final last = segments.isEmpty ? '' : segments.last.trim();
    return last.isEmpty ? 'Shared file' : last;
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'onIntent' && call.arguments is Map) {
      _dispatch((call.arguments as Map).cast<Object?, Object?>());
    }
    return null;
  }

  void _dispatch(Map<Object?, Object?> payload) {
    switch (payload['type']) {
      case 'link':
        final link = WeftLink.parse(payload['url'] as String? ?? '');
        if (link != null) onLink?.call(link);
      case 'share':
        final shared = SharedPayload.fromMap(payload);
        if (!shared.isEmpty) onShare?.call(shared);
    }
  }
}

/// The app's one [WeftIntents].
///
/// One, and through a provider, for two reasons that pull the same way:
/// constructing a second would install a second handler on the same channel and
/// the first would stop hearing anything, and the share sheet needs the same
/// instance the app started with in order to stage the files it is about to
/// send. A test overrides this with an instance over its own channel.
final weftIntentsProvider = Provider<WeftIntents>((ref) => WeftIntents());

/// How the share sheet turns `content://` URIs into sendable files.
///
/// The app's is [WeftIntents]; a widget test overrides this with a fake, which
/// is what puts the sheet itself — and not merely the resolution below it —
/// under test.
final sharedFileResolverProvider = Provider<SharedFileResolver>(
  (ref) => ref.watch(weftIntentsProvider),
);
