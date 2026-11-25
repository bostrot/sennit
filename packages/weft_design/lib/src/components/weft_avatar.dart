import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:weft_domain/weft_domain.dart';

import '../semantics.dart';
import '../theme.dart';
import 'network_glyph.dart';

/// Where avatar pictures come from when not straight from the network.
///
/// Sennit Web sets this: the browser has no homeserver credentials, so it asks
/// the phone for each picture over the encrypted link instead. Null — the
/// default everywhere else — means a [NetworkImage] with the given headers.
ImageProvider Function(String url)? weftAvatarImageOverride;

/// The picture behind an avatar [url].
///
/// A `data:` url is a picture the user chose themselves and is decoded in
/// place, before [weftAvatarImageOverride]: there is nothing to fetch. One
/// [MemoryImage] per url, kept, because a fresh one per build is a fresh image
/// cache key per build and the picture would be decoded again every frame.
ImageProvider weftAvatarImage(String url, {Map<String, String>? headers}) {
  if (url.startsWith('data:')) {
    final cached = _inlineAvatars.remove(url);
    final image = cached ?? MemoryImage(_inlineBytes(url));
    _inlineAvatars[url] = image;
    if (_inlineAvatars.length > 64) {
      _inlineAvatars.remove(_inlineAvatars.keys.first);
    }
    return image;
  }
  return weftAvatarImageOverride?.call(url) ??
      NetworkImage(url, headers: headers);
}

final Map<String, MemoryImage> _inlineAvatars = {};

Uint8List _inlineBytes(String url) {
  try {
    return UriData.parse(url).contentAsBytes();
  } on FormatException {
    // Undecodable: the image fails, and the initials underneath stay.
    return Uint8List(0);
  }
}

/// Avatar for a contact or chat.
///
/// Three states matter, and each is visually distinct at a glance:
/// a plain chat shows a single network badge; a **merged** chat shows a
/// gradient ring built from its networks' colours; a group shows neither.
class WeftAvatar extends StatelessWidget {
  const WeftAvatar({
    super.key,
    required this.label,
    this.imageUrl,
    this.imageHeaders,
    this.size = 48,
    this.networks = const [],
    this.showNetworkBadge = true,
    this.online = false,
    this.semanticsLabel,
  });

  final String label;
  final String? imageUrl;

  /// Sent with the image request. Matrix media is authenticated, so avatar
  /// fetches need the access token or every avatar silently 401s back to
  /// initials.
  final Map<String, String>? imageHeaders;
  final double size;

  /// Networks backing this chat. More than one draws the merged ring.
  final List<ChatNetwork> networks;

  final bool showNetworkBadge;
  final bool online;

  /// Overrides what a screen reader hears, or hides the avatar from one when
  /// it is empty.
  ///
  /// An avatar inside a row that already names the person — an inbox tile, a
  /// search result — is decoration, and the row's own merged node is the label.
  /// Passing `''` there is what stops the same name being announced twice.
  final String? semanticsLabel;

  bool get _isMerged => networks.length > 1;

  /// The person, and everything the picture says about them that the row
  /// around it may not.
  ///
  /// The merge is signalled three ways for a sighted user — the ring, the glyph
  /// strip, the label — and was signalled zero ways for a reader, who heard the
  /// *initials* instead, because the fallback `Text` was never excluded.
  String get _label => semanticsSentence([
    label,
    if (_isMerged)
      'merged across ${networks.length} networks: '
          '${networks.map((n) => n.label).join(', ')}'
    else if (showNetworkBadge && networks.length == 1)
      'on ${networks.single.label}',
    if (online) 'online',
  ]);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ringWidth = _isMerged ? size * 0.055 : 0.0;
    final inner = size - ringWidth * 2;

    // Initials are always painted; the picture covers them once it loads.
    //
    // A `NetworkImage` with [headers]: Matrix media is authenticated, so
    // without the access token every avatar request 401s and silently falls
    // back to initials — which is exactly what it looked like. The decode is
    // bounded too, not just the layout: a 1024px avatar decoded at full size
    // for a 48dp circle is wasted work the scroll thread pays for, once per
    // tile, on every rebuild after eviction.
    Widget avatar = Container(
      width: inner,
      height: inner,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: _initialsGradient(context),
      ),
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The initials are a *mark*, not text: their size is derived from
          // the circle around them, so letting the text scaler grow them
          // pushes them straight out of a container that cannot grow with
          // them. At 2.0× the avatar would show half of one letter.
          //
          // Opting out is safe because nothing here is reading material — the
          // person's name reaches a screen reader through this widget's
          // semantics label, and a sighted user gets the name from the row the
          // avatar sits in. A scale-aware measurement is the right answer for
          // text; for a glyph, no scaling is.
          MediaQuery.withNoTextScaling(
            child: Text(
              _initials,
              style: TextStyle(
                fontSize: inner * 0.36,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1,
              ),
            ),
          ),
          if (imageUrl != null)
            ClipOval(
              child: Image(
                image: ResizeImage.resizeIfNeeded(
                  (inner * 3).round(),
                  null,
                  weftAvatarImage(imageUrl!, headers: imageHeaders),
                ),
                width: inner,
                height: inner,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) {
                  debugPrint('weft: avatar failed for $imageUrl — $error');
                  return const SizedBox.shrink();
                },
              ),
            ),
        ],
      ),
    );

    if (_isMerged) {
      // The ring is the merge signature: one arc per network, in the same
      // colours as the rail, so the connection is obvious without a legend.
      avatar = Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(ringWidth),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [
              ...networks.map(palette.networkColor),
              palette.networkColor(networks.first),
            ],
            stops: _evenStops(networks.length + 1),
          ),
        ),
        child: avatar,
      );
    }

    final described = semanticsLabel ?? _label;

    // `excludeSemantics` rather than a label beside the children: what a reader
    // actually heard here was the initials — "AB" — because the fallback `Text`
    // under the picture is a semantics node like any other.
    return Semantics(
      label: described,
      image: imageUrl != null,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(child: avatar),
            // Both badges hang off the avatar's *trailing* corner, which is the
            // one furthest from the row's text in either direction: in an RTL
            // list the avatar is on the right and the badge belongs on its left,
            // where it does not sit between the picture and the name.
            if (showNetworkBadge && networks.length == 1)
              PositionedDirectional(
                end: -1,
                bottom: -1,
                child: _Badged(
                  size: size,
                  child: NetworkGlyph(
                    network: networks.single,
                    size: size * 0.36,
                  ),
                ),
              ),
            if (online)
              PositionedDirectional(
                end: 0,
                top: 0,
                child: _Badged(
                  size: size,
                  child: Container(
                    width: size * 0.24,
                    height: size * 0.24,
                    decoration: BoxDecoration(
                      color: palette.online,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static List<double> _evenStops(int count) => [
    for (var i = 0; i < count; i++) i / (count - 1),
  ];

  LinearGradient _initialsGradient(BuildContext context) {
    // Stable per-label hue so the same person keeps the same colour forever.
    final hue = (label.hashCode % 360).abs().toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.45, 0.48).toColor();
    return LinearGradient(
      begin: AlignmentDirectional.topStart,
      end: AlignmentDirectional.bottomEnd,
      colors: [base, Color.lerp(base, Colors.black, 0.3)!],
    );
  }

  String get _initials {
    final words = label.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.characters.first.toUpperCase();
    }
    return (words.first.characters.first + words.last.characters.first)
        .toUpperCase();
  }
}

/// Wraps a badge in a ring of the surface colour so it reads cleanly against
/// whatever the avatar happens to be.
class _Badged extends StatelessWidget {
  const _Badged({required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(size * 0.035),
      decoration: BoxDecoration(
        color: context.colors.surface,
        shape: BoxShape.circle,
      ),
      child: child,
    );
  }
}
