import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where a direct build buys Sennit Pro and checks a licence key.
///
/// Both can be replaced at build time, so a fork that sells its own builds
/// points them at its own shop: `--dart-define=BRAID_CHECKOUT_URL=…` and
/// `--dart-define=BRAID_LICENSE_API=…`.
abstract final class LicenseEndpoints {
  /// The checkout page the "Buy" button opens in the browser. Empty means
  /// there is none, and the Pro screen then only takes a key.
  static const checkout = String.fromEnvironment('BRAID_CHECKOUT_URL');

  /// The base of the licence service; `/validate` is appended.
  static const api = String.fromEnvironment(
    'BRAID_LICENSE_API',
    defaultValue: 'https://n8n.aachen.dev/webhook/braid',
  );
}

/// What the licence service said about a key.
enum LicenseVerdict {
  valid,

  /// The service answered, and the key is unknown or was deactivated.
  invalid,

  /// No answer worth trusting: offline, a timeout, a server error. Never
  /// treated as [invalid] — a licence that was accepted once must not stop
  /// working because a server is down.
  unreachable,
}

/// Licence keys look like `BRAID-XXXXX-XXXXX-XXXXX-XXXXX`. Typed keys arrive
/// in any case and with stray spaces; this is the one form that is sent and
/// stored. Null for anything that cannot be a key, so a typo costs no request.
String? normalizeLicenseKey(String input) {
  final key = input.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^BRAID(-[A-Z0-9]{5}){4}$').hasMatch(key) ? key : null;
}

/// Asks the licence service about a key.
///
/// The request carries the key and nothing else: no device id, no account,
/// no version. A licence covers every device its owner uses, so there is
/// nothing to count.
class LicenseClient {
  LicenseClient({Uri? api, http.Client? httpClient})
    : _api = api ?? Uri.parse(LicenseEndpoints.api),
      _http = httpClient ?? http.Client();

  final Uri _api;
  final http.Client _http;

  Future<LicenseVerdict> validate(String key) async {
    final uri = _api.replace(
      path: '${_api.path.replaceFirst(RegExp(r'/$'), '')}/validate',
      queryParameters: {'license': key},
    );
    try {
      final response = await _http
          .get(uri, headers: {'accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return LicenseVerdict.unreachable;
      final body = jsonDecode(response.body);
      if (body is! Map<String, Object?>) return LicenseVerdict.unreachable;
      return switch (body['valid']) {
        true => LicenseVerdict.valid,
        false => LicenseVerdict.invalid,
        _ => LicenseVerdict.unreachable,
      };
    } on Object {
      return LicenseVerdict.unreachable;
    }
  }
}
