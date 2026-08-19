import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:weft_domain/weft_domain.dart';

import '../theme.dart';
import '../tokens.dart';

/// A network's mark: a rounded-square chip carrying its logo.
///
/// Logos come from Simple Icons, whose glyphs are CC0, so the rail is scannable
/// at a glance without vendoring anyone's trademarked art files. A network with
/// no icon in the set falls back to a lettermark rather than a blank chip.
class NetworkGlyph extends StatelessWidget {
  const NetworkGlyph({
    super.key,
    required this.network,
    this.size = 24,
    this.selected = false,
    this.showLabel = false,
  });

  final ChatNetwork network;
  final double size;
  final bool selected;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = palette.networkColor(network);
    // White on a harmonised brand colour is 1.9:1 for half the set on a light
    // theme; the ink that reads on this particular chip comes from the token
    // layer, which computed it against both ends of the gradient below.
    final ink = palette.networkInk;
    final radius = size * 0.32;

    final chip = AnimatedContainer(
      duration: context.motion.fast,
      curve: context.motion.standard,
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.22)!],
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: selected ? WeftShadow.glow(color) : null,
      ),
      alignment: Alignment.center,
      child: _brandIcon == null
          // A lettermark is a logo standing in for a logo, sized from the chip
          // that holds it — so like the avatar's initials it opts out of text
          // scaling rather than overflowing a container that cannot grow. The
          // network's name reaches a reader from the label, not from "Gc".
          ? MediaQuery.withNoTextScaling(
              child: Text(
                _initial,
                style: TextStyle(
                  // Two-character marks shrink to stay inside the chip.
                  fontSize: size * (_initial.length > 1 ? 0.36 : 0.5),
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: ink,
                  letterSpacing: -0.5,
                ),
              ),
            )
          : Icon(_brandIcon, size: size * 0.58, color: ink),
    );

    if (!showLabel) return chip;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip,
        const SizedBox(height: WeftSpace.xs),
        Text(
          network.label,
          style: context.text.labelSmall,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// The brand glyph, or null when Simple Icons has none for this network.
  IconData? get _brandIcon => switch (network) {
    ChatNetwork.whatsapp => SimpleIcons.whatsapp,
    ChatNetwork.signal => SimpleIcons.signal,
    ChatNetwork.telegram => SimpleIcons.telegram,
    ChatNetwork.instagram => SimpleIcons.instagram,
    ChatNetwork.messenger => SimpleIcons.messenger,
    ChatNetwork.discord => SimpleIcons.discord,
    ChatNetwork.imessage => SimpleIcons.imessage,
    ChatNetwork.googlechat => SimpleIcons.googlechat,
    ChatNetwork.gmessages => SimpleIcons.googlemessages,
    ChatNetwork.twitter => SimpleIcons.x,
    ChatNetwork.bluesky => SimpleIcons.bluesky,
    ChatNetwork.matrix => SimpleIcons.matrix,
    // Slack and LinkedIn asked to be removed from Simple Icons over trademark
    // policy, so those keep their lettermark.
    ChatNetwork.slack ||
    ChatNetwork.linkedin ||
    ChatNetwork.sms ||
    ChatNetwork.email ||
    ChatNetwork.unknown => null,
  };

  /// Single letters read best at rail size, but several networks share a first
  /// letter — Signal/Slack, Instagram/iMessage, Telegram/Twitter — so those get
  /// a disambiguating second character rather than relying on colour alone.
  String get _initial => switch (network) {
    ChatNetwork.signal => 'S',
    ChatNetwork.slack => 'Sl',
    ChatNetwork.sms => 'Sm',
    ChatNetwork.instagram => 'Ig',
    ChatNetwork.imessage => 'iM',
    ChatNetwork.telegram => 'T',
    ChatNetwork.twitter => 'X',
    ChatNetwork.googlechat => 'Gc',
    ChatNetwork.gmessages => 'Gm',
    ChatNetwork.messenger => 'M',
    ChatNetwork.matrix => 'Mx',
    ChatNetwork.whatsapp => 'W',
    ChatNetwork.discord => 'D',
    ChatNetwork.bluesky => 'B',
    ChatNetwork.linkedin => 'In',
    ChatNetwork.email => 'E',
    ChatNetwork.unknown => '?',
  };
}
