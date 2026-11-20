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
  ///   `/compose?recipient={name}&text={text}`
  ///                            → a new message to whoever the name means,
  ///                              from an Android App Action (Assistant or
  ///                              Gemini on the phone)
  ///
  /// Plus the four telephony schemes — `sms:`, `smsto:`, `mms:`, `mmsto:` —
  /// which are not Sennit's own links at all: they are what the dialer, the
  /// contacts app and a `sms:` link on a web page send, and handling them is
  /// required of the default SMS app.
  ///
  /// Returns null for anything unrecognised — an unknown link must not crash
  /// the router, because links arrive from outside the app's control.
  static WeftLink? parse(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;

    if (_smsSchemes.contains(uri.scheme)) return ComposeSmsLink.fromUri(uri);

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

    // `Uri.pathSegments` is *already* percent-decoded, so `!abc%3Aexample.org`
    // arrives here as `!abc:example.org`. Decoding a second time was harmless
    // for every id Sennit generates — room ids are ASCII, contact ids are
    // `contact_<micros>_<n>`, and neither leaves a `%` behind for the second
    // pass to find — but it threw `ArgumentError` out of a method whose whole
    // contract is that an unknown link must not crash the router, for any id
    // carrying a literal `%` or a non-ASCII character. Links arrive from
    // outside the app's control; one decode is the right number.
    switch (segments.first) {
      case 'chat':
        if (segments.length < 2 || segments[1].isEmpty) return null;
        return OpenChatLink(segments[1]);
      case 'user':
        if (segments.length < 2 || segments[1].isEmpty) return null;
        return OpenUserLink(segments[1]);
      case 'search':
        return OpenSearchLink(uri.queryParameters['q'] ?? '');
      case 'compose':
        return ComposeMessageLink(
          recipient: (uri.queryParameters['recipient'] ?? '').trim(),
          text: (uri.queryParameters['text'] ?? '').trim(),
        );
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

/// "Send a message to Anna on Sennit", from a voice assistant.
///
/// What the `actions.intent.CREATE_MESSAGE` capability in `shortcuts.xml`
/// opens: the assistant fills in the spoken name and, when it heard one, the
/// message. Both may be empty — "Send a message on Sennit" names nobody — and
/// the name is whatever the recogniser heard, so it is resolved against the
/// inbox (`resolveMessageRecipient`) rather than trusted as an id. Nothing is
/// sent from here: the text lands in the composer and the user sends it.
class ComposeMessageLink extends WeftLink {
  const ComposeMessageLink({this.recipient = '', this.text = ''});

  final String recipient;
  final String text;
}

/// The four schemes an "message this number" intent arrives under.
///
/// Not synonyms to the intent resolver, and callers are inconsistent about
/// which they pick: `sms:`/`mms:` mean "the conversation with", `smsto:`/
/// `mmsto:` mean "compose to". Weft treats all four the same — the distinction
/// only matters to an app that keeps SMS and MMS in separate places, which no
/// user has ever wanted.
const Set<String> _smsSchemes = {'sms', 'smsto', 'mms', 'mmsto'};

/// "Send a message to this number", from outside Weft.
///
/// Produced by an `ACTION_SENDTO` intent — the dialer's message button, a
/// contact card, a `sms:` link in a browser. Declaring the filter is one of the
/// conditions Android checks before offering an app the default-SMS role, and
/// an app that is handed the intent and does nothing with it is worse than one
/// that never claimed it.
class ComposeSmsLink extends WeftLink {
  const ComposeSmsLink({this.addresses = const [], this.body});

  /// Recipients, exactly as the caller wrote them — national format, spaces,
  /// short code and all.
  ///
  /// Deliberately not normalised here. `PhoneNumberParser` needs the device's
  /// region to read `01234 567890`, this parser has no business knowing it, and
  /// a number that fails to normalise is still the number the user typed and
  /// still what the composer should show.
  ///
  /// Usually one. `sms:+441234567890,+441234567891` is a group MMS, and empty
  /// is legal: `sms:` with no recipient means "start a new message".
  final List<String> addresses;

  /// Prefilled text from the URI's `body` parameter, when the caller set one.
  final String? body;

  /// Reads a `sms:`/`smsto:`/`mms:`/`mmsto:` URI.
  ///
  /// The number can be in either of two places, because both spellings occur in
  /// the wild: `sms:+44…` puts it in the path, `sms://+44…` in the authority.
  /// `Uri.path` keeps its percent-encoding — `mmsto:%2B44…` is a real intent
  /// from at least one dialer — so it is decoded here, once.
  static ComposeSmsLink fromUri(Uri uri) {
    final raw = uri.path.isNotEmpty ? uri.path : uri.host;
    final addresses = <String>[];
    for (final part in raw.split(RegExp('[,;]'))) {
      final address = _decode(part).trim();
      if (address.isNotEmpty) addresses.add(address);
    }
    final body = uri.queryParameters['body']?.trim();
    return ComposeSmsLink(
      addresses: addresses,
      body: body == null || body.isEmpty ? null : body,
    );
  }

  /// Percent-decoding that cannot throw.
  ///
  /// The same trap `WeftLink.parse` already documents one layer up: a URI from
  /// another app can contain a bare `%`, and `Uri.decodeComponent` answers that
  /// with an `ArgumentError` out of a method whose contract is not to crash.
  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }
}

/// Content another app shared into Sennit.
@immutable
class SharedPayload {
  const SharedPayload({
    this.text,
    this.mimeType,
    this.uris = const [],
    this.targetChatId,
  });

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

  /// The conversation the user already chose, when they chose one outside the
  /// app.
  ///
  /// A `Chat.id`, not a shortcut id — the platform resolves the sanitised id it
  /// was handed back into the chat it was published for, because the sanitising
  /// is lossy. Set by an Android Direct Share tap (`EXTRA_SHORTCUT_ID`) and, on
  /// iOS, by the Share Extension's own picker via `StagedShare.targetChatId`.
  ///
  /// Null is the ordinary case and means "ask": a plain share, or a shortcut
  /// published by an older build that the platform can no longer resolve.
  /// Guessing would send someone's photo to the wrong person, so an
  /// unresolvable target is the same as no target.
  final String? targetChatId;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && uris.isEmpty;

  static SharedPayload fromMap(Map<Object?, Object?> map) => SharedPayload(
    text: map['text'] as String?,
    mimeType: map['mimeType'] as String?,
    uris: [
      for (final uri in (map['uris'] as List?) ?? const [])
        if (uri is String) uri,
    ],
    // Blank is treated as absent: the platform sends null, but a hand-written
    // caller sending "" means the same thing and must not pre-select a chat
    // whose id is the empty string. Not trimmed when it is kept — a chat id is
    // matched exactly, and quietly editing one would fail to match with no
    // sign of why.
    targetChatId: switch (map['targetChatId']) {
      final String id when id.trim().isNotEmpty => id,
      _ => null,
    },
  );
}

/// Largest file Sennit will take from a share intent.
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

/// Where a ranked list of conversations goes to become share targets.
///
/// A seam for the same reason [SharedFileResolver] is one: behind it is a
/// method channel, and `ShareShortcutService` is worth testing without a
/// launcher — the diff, the cap and the logout clear are all decisions, and
/// none of them needs a device to be wrong. The real implementation is
/// [WeftIntents]; the test's is a list.
abstract interface class ShareTargetPublisher {
  Future<int> publishShareTargets(List<Map<String, Object?>> slots);

  Future<void> clearShareTargets();
}

/// Receives share-ins and deep links from the platform side.
///
/// Cold starts are handled by replay: the platform holds the launching intent
/// until Dart asks for it, because a share arriving via cold start fires
/// before any Dart code is listening.
class WeftIntents implements SharedFileResolver, ShareTargetPublisher {
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

  /// Copies the bytes behind [uri] into a file Sennit can open later, returning
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

  /// Publishes [slots] as the device's Direct Share targets, replacing the set.
  ///
  /// Each map is a `ShareTargetSlot.toJson()` with one key added: `iconPath`,
  /// the avatar already resolved to a file the platform can decode. That key is
  /// not on the slot itself because the slot carries an `mxc://` URI and this
  /// package cannot fetch one — resolving it is the caller's job, and on iOS it
  /// resolves to something else entirely.
  ///
  /// On the `/intents` channel rather than a channel of its own. Phase 03 made
  /// that call for `publishChatShortcut` and wrote down why — "a second channel
  /// would be a second front door onto the same activity" — and this is the same
  /// activity, the same `ShareShortcuts` object and the same shortcut ids. Two
  /// channels publishing one shortcut set is exactly the arrangement where a
  /// notification stops bubbling because the other front door removed its
  /// shortcut.
  ///
  /// Returns how many the platform actually published, which can be fewer than
  /// asked for: the per-activity shortcut cap is a device property, and pushing
  /// past it throws rather than truncating. Zero on a platform with no such
  /// channel, which is every platform except Android.
  @override
  Future<int> publishShareTargets(List<Map<String, Object?>> slots) async {
    try {
      return await _channel.invokeMethod<int>('publishShareTargets', {
            'slots': slots,
          }) ??
          0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      // A launcher that refuses shortcuts. The share sheet still works; it just
      // shows the app icon instead of faces.
      return 0;
    }
  }

  /// Removes every published share target.
  ///
  /// Called on logout. A signed-out device still offering contact names in
  /// every app's share sheet has leaked them to whoever picks the phone up, and
  /// a long-lived shortcut is long-lived precisely because nothing else will
  /// clean it up.
  @override
  Future<void> clearShareTargets() async {
    try {
      await _channel.invokeMethod<bool>('clearShareTargets');
    } on MissingPluginException {
      // Nothing was ever published here.
    } on PlatformException {
      // Nothing useful to do; the next publish will try the removal again.
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
  ///
  /// Two kinds of URI arrive here. A `content://` from an Android intent has to
  /// be asked about and then copied, because its grant dies with the activity.
  /// A `file://` is already a file on disk — that is what an iOS staged share
  /// becomes once `StagedShareReader` has moved it out of the App Group
  /// container — and needs neither call. Both end as an [AttachmentSource] the
  /// upload path can open, which is the only thing the sheet below knows about.
  @override
  Future<ResolvedShare> resolveSharedFiles(SharedPayload payload) async {
    final sources = <AttachmentSource>[];
    final problems = <String>[];

    for (final uri in payload.uris) {
      final localPath = _localPath(uri);
      if (localPath != null) {
        final problem = await _addLocalFile(
          localPath,
          payload.mimeType,
          sources,
        );
        if (problem != null) problems.add(problem);
        continue;
      }

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

  /// Adds the file already sitting at [path], or says why it cannot be sent.
  ///
  /// No `readSharedFileMeta` and no `stageSharedFile`: this file is on the app's
  /// own disk, put there by the staged-share drain, and both of those calls
  /// exist to get a `content://` grant into exactly this state. Asking a channel
  /// that only Android implements would fail on the one platform this branch
  /// runs on.
  ///
  /// The cap is applied here too. The extension checks it twice before writing
  /// anything, so this is the third look at the same number — and the only one
  /// that is not in a process the app cannot see the source of. [_maxFileBytes]
  /// is what the sheet's own error sentence quotes, so a file that got past the
  /// others is refused in the same words as any other oversized share.
  Future<String?> _addLocalFile(
    String path,
    String? declaredMimeType,
    List<AttachmentSource> sources,
  ) async {
    final name = _basename(path);
    try {
      final length = await File(path).length();
      if (length > _maxFileBytes) return _tooLarge(name, length);
      sources.add(
        await attachmentSourceForFile(
          XFile(path, mimeType: declaredMimeType, name: name),
        ),
      );
      return null;
    } on Object catch (error) {
      // Deliberately Object, as in the branch below: a staged file that is
      // missing, unreadable or truncated is one sentence to the user, and the
      // reasons differ only in the log.
      debugPrint('weft: staged file $name could not be read: $error');
      return '$name could not be read.';
    }
  }

  /// [uri] as a path on this device's disk, or null when it is not one.
  ///
  /// Only `file://`. A `content://` is not a path and never becomes one — the
  /// whole reason [stageSharedFile] exists — so anything else falls through to
  /// the platform branch.
  static String? _localPath(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme != 'file') return null;
    try {
      return parsed.toFilePath();
    } on UnsupportedError {
      // A `file://host/path` URI, which names a file on another machine. Not
      // something Weft writes, and not something to guess at.
      return null;
    }
  }

  static String _basename(String path) {
    final cut = path.lastIndexOf('/');
    final name = cut >= 0 ? path.substring(cut + 1) : path;
    return name.isEmpty ? 'Shared file' : name;
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

/// How the shortcut service reaches the launcher.
///
/// The app's is [WeftIntents], so publishing rides the same channel — and the
/// same `ShareShortcuts` object — the notification path's single-shortcut
/// publish does. A test overrides this with a recorder.
final shareTargetPublisherProvider = Provider<ShareTargetPublisher>(
  (ref) => ref.watch(weftIntentsProvider),
);
