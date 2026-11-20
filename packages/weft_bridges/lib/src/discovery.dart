/// Where a homeserver says its bridges' provisioning APIs are.
///
/// Bridges do not advertise their provisioning URL — the `m.bridge` state they
/// stamp on rooms names the bot and the network, never an address — so a
/// client either has it typed in or is told. Being told is the only one of the
/// two a person who has never heard of a provisioning API can do, so a server
/// that publishes its bridges in `/.well-known/matrix/client` gets the guided
/// sign-in with nothing typed at all:
///
/// ```json
/// {
///   "m.homeserver": {"base_url": "https://matrix.example.org"},
///   "com.bostrot.sennit.bridges": {
///     "whatsapp": "https://matrix.example.org/_sennit/bridges/whatsapp",
///     "signal": {"provisioning_url": "/_sennit/bridges/signal"}
///   }
/// }
/// ```
///
/// Keys are network ids as `ChatNetwork.fromBridgeProtocol` reads them
/// (`whatsapp`, `signal`, `telegram`, `gmessages`, `instagram`…). A relative
/// URL is resolved against the homeserver, which is what a reverse proxy in
/// front of both usually wants.
library;

/// The well-known key, namespaced as the spec asks of custom keys.
const String kBridgesWellKnownKey = 'com.bostrot.sennit.bridges';

/// Reads [kBridgesWellKnownKey] out of a decoded `/.well-known/matrix/client`.
///
/// Tolerant by design: one malformed entry drops that entry, never the rest.
Map<String, Uri> parseBridgeWellKnown(
  Map<String, Object?> wellKnown, {
  required Uri homeserver,
}) {
  final section = wellKnown[kBridgesWellKnownKey];
  if (section is! Map) return const {};

  final found = <String, Uri>{};
  for (final MapEntry(:key, :value) in section.entries) {
    if (key is! String || key.isEmpty) continue;
    final raw = switch (value) {
      final String url => url,
      final Map<Object?, Object?> entry =>
        entry['provisioning_url'] as String? ?? entry['url'] as String?,
      _ => null,
    };
    if (raw == null || raw.trim().isEmpty) continue;
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) continue;
    final resolved = parsed.hasScheme ? parsed : homeserver.resolveUri(parsed);
    if (resolved.scheme != 'https' && resolved.scheme != 'http') continue;
    found[key.toLowerCase()] = resolved;
  }
  return found;
}
