import 'package:weft_domain/weft_domain.dart';

/// Where [handle] can be opened in its network's own app, or null when there
/// is no link for it.
///
/// For what a bridge cannot do — a call, a status, a sticker pack — the
/// network's own app is the way out. Each link opens the person, not just the
/// app: the conversation with that number in WhatsApp, the profile in
/// Discord. A network that can only be reached by a username Sennit never
/// learns (Instagram, LinkedIn…) gets no link rather than a wrong one.
Uri? nativeAppLink(NetworkHandle handle) {
  final phone = handle.phoneE164;
  final digits = phone?.replaceAll(RegExp(r'[^0-9]'), '');
  final id = handle.remoteId;
  final numericId = RegExp(r'^[0-9]+$').hasMatch(id) ? id : null;
  switch (handle.network) {
    case ChatNetwork.whatsapp:
      final number = digits ?? numericId;
      if (number == null || number.isEmpty) return null;
      return Uri.parse('https://wa.me/$number');
    case ChatNetwork.signal:
      // Signal ids are account UUIDs; only a phone number opens a chat.
      if (digits == null || digits.isEmpty) return null;
      return Uri.parse('https://signal.me/#p/+$digits');
    case ChatNetwork.telegram:
      if (digits != null && digits.isNotEmpty) {
        return Uri.parse('https://t.me/+$digits');
      }
      if (numericId == null) return null;
      return Uri.parse('tg://user?id=$numericId');
    case ChatNetwork.messenger:
      if (numericId == null) return null;
      return Uri.parse('https://m.me/$numericId');
    case ChatNetwork.discord:
      if (numericId == null) return null;
      return Uri.parse('https://discord.com/users/$numericId');
    case ChatNetwork.twitter:
      if (numericId == null) return null;
      return Uri.parse('https://x.com/i/user/$numericId');
    case ChatNetwork.sms || ChatNetwork.gmessages || ChatNetwork.imessage:
      final number = phone ?? (id.startsWith('+') ? id : null);
      if (number == null || number.isEmpty) return null;
      return Uri(scheme: 'sms', path: number);
    case ChatNetwork.email:
      final address = handle.email ?? (id.contains('@') ? id : null);
      if (address == null) return null;
      return Uri(scheme: 'mailto', path: address);
    default:
      // Matrix is Sennit itself; the rest have no public link by id.
      return null;
  }
}
