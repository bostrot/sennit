/// The chat networks Weft can surface, independent of how they are bridged.
///
/// Weft never hosts bridges. Every network here reaches the user's homeserver
/// through a bridge the user runs themselves, so this enum describes *what a
/// conversation is*, not *who operates the plumbing*.
enum ChatNetwork {
  matrix('matrix', 'Matrix', 0xFF0DBD8B),
  whatsapp('whatsapp', 'WhatsApp', 0xFF25D366),
  signal('signal', 'Signal', 0xFF3A76F0),
  telegram('telegram', 'Telegram', 0xFF2AABEE),
  instagram('instagram', 'Instagram', 0xFFE1306C),
  messenger('facebook', 'Messenger', 0xFF0084FF),
  discord('discord', 'Discord', 0xFF5865F2),
  slack('slack', 'Slack', 0xFF611F69),
  imessage('imessage', 'iMessage', 0xFF34DA50),
  linkedin('linkedin', 'LinkedIn', 0xFF0A66C2),
  googlechat('googlechat', 'Google Chat', 0xFF1A73E8),
  gmessages('gmessages', 'Google Messages', 0xFF1B72E8),
  twitter('twitter', 'X', 0xFF1D9BF0),
  bluesky('bluesky', 'Bluesky', 0xFF0085FF),
  // SMS has no brand to borrow a colour from, so this one is chosen rather
  // than copied. It used to be the same grey as [unknown], which made a chat
  // whose network could not be resolved and a chat that is genuinely SMS the
  // same swatch — the one distinction a merged conversation's per-message
  // glyphs exist to draw. Amber is the only free hue in the palette (green,
  // blue, purple, pink and teal are all taken by real brands) and it reads as
  // the caution the network deserves: SMS is the one leg of a merged chat that
  // travels in plaintext.
  sms('sms', 'SMS', 0xFFB0742A),
  email('email', 'Email', 0xFF8E8E93),
  unknown('unknown', 'Unknown', 0xFF7C8794);

  const ChatNetwork(this.id, this.label, this.brandColor);

  /// Stable identifier used in storage and on the wire. Matches the mautrix
  /// bridge protocol name where one exists, so [fromBridgeProtocol] is mostly
  /// an identity mapping.
  final String id;

  /// Human-facing name.
  final String label;

  /// Brand colour as 0xAARRGGBB. Held as an `int` so this package stays
  /// Flutter-free; `weft_design` converts it to a `Color`.
  final int brandColor;

  static final Map<String, ChatNetwork> _byId = {
    for (final n in ChatNetwork.values) n.id: n,
  };

  /// Extra spellings seen in the wild from bridge `m.bridge` state events and
  /// bot localparts, mapped onto the canonical value.
  static const Map<String, ChatNetwork> _aliases = {
    'whatsappgo': ChatNetwork.whatsapp,
    'signalgo': ChatNetwork.signal,
    'telegramgo': ChatNetwork.telegram,
    'meta': ChatNetwork.messenger,
    'facebookgo': ChatNetwork.messenger,
    'instagramgo': ChatNetwork.instagram,
    'discordgo': ChatNetwork.discord,
    'slackgo': ChatNetwork.slack,
    'imessagego': ChatNetwork.imessage,
    'bluebubbles': ChatNetwork.imessage,
    'googlemessages': ChatNetwork.gmessages,
    'gvoice': ChatNetwork.sms,
    'x': ChatNetwork.twitter,
    'twitterx': ChatNetwork.twitter,
  };

  /// Resolves a bridge protocol identifier to a network.
  ///
  /// Accepts the forms bridges actually emit — `whatsapp`, `mautrix-whatsapp`,
  /// `WhatsApp`, `sh.puppet.whatsapp` — and falls back to [unknown] rather than
  /// throwing, because an unrecognised bridge should still show its chats.
  static ChatNetwork fromBridgeProtocol(String? raw) {
    if (raw == null || raw.isEmpty) return ChatNetwork.unknown;
    var key = raw.toLowerCase().trim();
    if (key.contains('.')) key = key.split('.').last;
    key = key.replaceFirst(RegExp(r'^(mautrix|matrix)[-_]'), '');
    key = key.replaceAll(RegExp(r'[-_\s]'), '');
    return _byId[key] ?? _aliases[key] ?? ChatNetwork.unknown;
  }

  /// Parses a stored [id] back into a network.
  static ChatNetwork fromId(String id) => _byId[id] ?? ChatNetwork.unknown;
}
