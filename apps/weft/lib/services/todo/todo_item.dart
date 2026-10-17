import 'package:flutter/foundation.dart';

/// One entry on the user's to-do list.
///
/// Small on purpose: a title, an optional day it is due, whether it is done,
/// and — for the entries the assistant wrote — the conversation it came from,
/// so the list can say *why* something is on it and the assistant can be shown
/// only the open entries of the chat it is reading.
@immutable
class TodoItem {
  const TodoItem({
    required this.id,
    required this.title,
    required this.createdAt,
    this.due,
    this.done = false,
    this.doneAt,
    this.chatId,
    this.chatTitle,
    this.fromAi = false,
  });

  final String id;
  final String title;
  final DateTime createdAt;

  /// The day it is due, date only. Null for "whenever".
  final DateTime? due;

  final bool done;
  final DateTime? doneAt;

  /// The conversation the entry came from, when it came from one.
  final String? chatId;
  final String? chatTitle;

  /// Whether the assistant wrote it rather than the user.
  final bool fromAi;

  TodoItem copyWith({
    String? title,
    DateTime? due,
    bool clearDue = false,
    bool? done,
  }) {
    final nextDone = done ?? this.done;
    return TodoItem(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      due: clearDue ? null : (due ?? this.due),
      done: nextDone,
      // Stamped on the transition and dropped on the way back, so an entry
      // ticked by mistake does not keep a completion date it never earned.
      doneAt: nextDone ? (this.done ? doneAt : DateTime.now()) : null,
      chatId: chatId,
      chatTitle: chatTitle,
      fromAi: fromAi,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'created': createdAt.toUtc().toIso8601String(),
    if (due != null) 'due': formatTodoDate(due!),
    if (done) 'done': true,
    if (doneAt != null) 'done_at': doneAt!.toUtc().toIso8601String(),
    if (chatId != null) 'chat': chatId,
    if (chatTitle != null) 'chat_title': chatTitle,
    if (fromAi) 'ai': true,
  };

  /// Null for anything that is not an entry — never throws, so one bad row
  /// from a newer build costs that row rather than the list.
  static TodoItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
      return null;
    }
    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return TodoItem(
      id: id,
      title: title,
      createdAt: time(json['created']) ?? DateTime.now(),
      due: json['due'] is String ? parseTodoDate(json['due'] as String) : null,
      done: json['done'] == true,
      doneAt: time(json['done_at']),
      chatId: json['chat'] is String ? json['chat'] as String : null,
      chatTitle: json['chat_title'] is String
          ? json['chat_title'] as String
          : null,
      fromAi: json['ai'] == true,
    );
  }

  static List<TodoItem> listFromJson(Object? json) {
    if (json is! List) return const [];
    return [for (final entry in json) ?TodoItem.fromJson(entry)];
  }

  static List<Object?> listToJson(List<TodoItem> items) => [
    for (final item in items) item.toJson(),
  ];
}

/// `YYYY-MM-DD`, the one date format the list, the model and Home Assistant
/// all agree on.
String formatTodoDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// The inverse of [formatTodoDate], as a local midnight; null for anything
/// else, including a real-looking date that does not exist.
DateTime? parseTodoDate(String text) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text.trim());
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final date = DateTime(year, month, day);
  // DateTime rolls 2026-02-30 over into March; that is not what was meant.
  if (date.month != month || date.day != day) return null;
  return date;
}
