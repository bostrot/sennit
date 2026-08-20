import 'dart:convert';

import 'package:http/http.dart' as http;

/// Talks to the user's own Home Assistant instance.
///
/// One verb, deliberately: Weft *fires an event* (`weft_message`) on the HA
/// bus, and everything else — lights, TTS, notifications on the wall tablet —
/// is an automation the user writes against that event. The reverse direction
/// needs no client at all: Home Assistant reaches Weft through the MCP
/// server's `send_message` tool with a `rest_command`.
class HomeAssistantClient {
  HomeAssistantClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String token;
  final http.Client _http;

  Map<String, String> get _headers => {
    'authorization': 'Bearer $token',
    'content-type': 'application/json',
  };

  Uri _api(String path) => baseUrl.replace(
    path: '${baseUrl.path.replaceFirst(RegExp(r'/$'), '')}$path',
  );

  /// `GET /api/` — the cheapest authenticated call HA has.
  Future<bool> probe() async {
    try {
      final response = await _http
          .get(_api('/api/'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// Fires `weft_message` with [payload] as the event data.
  Future<void> fireMessageEvent(Map<String, Object?> payload) async {
    final response = await _http
        .post(
          _api('/api/events/weft_message'),
          headers: _headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HomeAssistantException(
        'Home Assistant answered ${response.statusCode}.',
      );
    }
  }

  void dispose() => _http.close();
}

class HomeAssistantException implements Exception {
  const HomeAssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}
