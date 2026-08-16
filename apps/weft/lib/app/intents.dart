import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  final String? mimeType;

  /// Platform content URIs. Their bytes are only reachable through
  /// [WeftIntents.readSharedFile] — a content:// grant cannot be turned into a
  /// file path.
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

/// Receives share-ins and deep links from the platform side.
///
/// Cold starts are handled by replay: the platform holds the launching intent
/// until Dart asks for it, because a share arriving via cold start fires
/// before any Dart code is listening.
class WeftIntents {
  WeftIntents({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.bostrot.weft/intents') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;

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

  /// Reads the bytes behind a shared content URI.
  Future<Uint8List?> readSharedFile(String uri) async {
    try {
      return await _channel.invokeMethod<Uint8List>('readSharedFile', {
        'uri': uri,
      });
    } on PlatformException {
      return null;
    }
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
