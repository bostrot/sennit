import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

import '../todo/todo_item.dart' show formatTodoDate;

/// Talks to the user's own Home Assistant instance.
///
/// Two things, deliberately few. Sennit *fires an event* (`weft_message`) on
/// the HA bus, and everything else — lights, TTS, notifications on the wall
/// tablet — is an automation the user writes against that event. And when the
/// user asks for it, Sennit mirrors its to-do list into one of HA's `todo`
/// entities through the `todo.add_item` and `todo.update_item` actions, which
/// every to-do integration (Local To-do, Shopping List, CalDAV, Todoist, …)
/// implements. The reverse direction needs no client at all: Home Assistant
/// reaches Sennit through the MCP server's `send_message` tool with a
/// `rest_command`.
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

  /// The `todo.*` entities, for the picker. Sorted by name.
  Future<List<HomeAssistantTodoList>> todoLists() async {
    final response = await _http
        .get(_api('/api/states'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HomeAssistantException(
        'Home Assistant answered ${response.statusCode}.',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) return const [];
    final lists = <HomeAssistantTodoList>[];
    for (final state in decoded) {
      if (state is! Map) continue;
      final entityId = state['entity_id'];
      if (entityId is! String || !entityId.startsWith('todo.')) continue;
      final attributes = state['attributes'];
      final name = attributes is Map && attributes['friendly_name'] is String
          ? attributes['friendly_name'] as String
          : entityId;
      lists.add(HomeAssistantTodoList(entityId: entityId, name: name));
    }
    lists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return lists;
  }

  /// Adds [item] to the to-do list [entityId].
  ///
  /// [due] is sent as `due_date` — but not every list has due dates (HA's own
  /// Shopping List does not) and HA refuses the whole call with a 400 when a
  /// field is unsupported. So a refusal is retried once with the title alone:
  /// an entry without its date beats no entry.
  Future<void> addTodoItem(
    String entityId,
    String item, {
    DateTime? due,
  }) async {
    Future<int> post(Map<String, Object?> data) => _service('add_item', data);

    final base = {'entity_id': entityId, 'item': item};
    var status = due == null
        ? await post(base)
        : await post({...base, 'due_date': formatTodoDate(due)});
    if (status == 400 && due != null) status = await post(base);
    if (status != 200) {
      throw HomeAssistantException('Home Assistant answered $status.');
    }
  }

  /// Marks [item] — matched by its title, which is how HA looks entries up —
  /// completed or back to needs-action on the list [entityId].
  Future<void> setTodoItemDone(
    String entityId,
    String item, {
    required bool done,
  }) async {
    final status = await _service('update_item', {
      'entity_id': entityId,
      'item': item,
      'status': done ? 'completed' : 'needs_action',
    });
    if (status != 200) {
      throw HomeAssistantException('Home Assistant answered $status.');
    }
  }

  Future<int> _service(String action, Map<String, Object?> data) async {
    final response = await _http
        .post(
          _api('/api/services/todo/$action'),
          headers: _headers,
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 15));
    return response.statusCode;
  }

  void dispose() => _http.close();
}

/// One of Home Assistant's to-do lists.
@immutable
class HomeAssistantTodoList {
  const HomeAssistantTodoList({required this.entityId, required this.name});

  final String entityId;
  final String name;
}

class HomeAssistantException implements Exception {
  const HomeAssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}
