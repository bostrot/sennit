import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:weft_domain/weft_domain.dart';

import 'llm_budget.dart';
import 'llm_request.dart';

/// What the user has noted for the AI features, and what Sennit learned on its
/// own, in two layers.
///
/// * **Chat memory** — detailed, one per conversation, groups included: what
///   is going on, plans, the tone used *in this chat*, the in-jokes. Filed
///   under the chat's rooms, `room:<id>` (see [chatMemoryKeys]).
/// * **Person memory** — a few lines per person, used in every chat they are
///   in: what they like to be called, relationship, birthday, du or Sie,
///   language, the facts that matter everywhere. Filed under the person's
///   network handles, `handle:<id>`, or `dm:<room>` / `user:<mxid>` for a
///   person Sennit has no handle for (see [personMemoryKeys]).
///
/// Each layer has the user's own note, which the model never touches, and the
/// [learned] facts it keeps up to date by itself (see [applyLearning]) — each
/// with when it was learned, and pinned once the user edits it, after which
/// the model leaves it alone too. The last automatic update can be undone
/// ([undo]). [suggestions] are facts an older version offered for a yes or a
/// no; nothing adds to them any more, and those still waiting are shown until
/// answered.
///
/// One book for both, keyed by those prefixes, because the operations are the
/// same and so is where it is kept. A person is whatever set of handles Sennit
/// has merged into one contact, so a note written while Anna's WhatsApp and
/// Signal were two chats is found under both once they are merged, and stays
/// on each if they are split again. [noteFor] joins what the keys hold, and
/// [withNote] writes the one note back to every key — which is how two notes
/// for one person become one the first time it is edited.
///
/// Stored as one blob in the keychain (`SecretStore.personMemory`), never in
/// the database beside the messages, and never in a log: the `toString` says
/// how many, not what.
@immutable
class MemoryBook {
  const MemoryBook({
    this.notes = const {},
    this.learned = const {},
    this.suggestions = const {},
    this.dismissed = const {},
    this.undo,
  });

  static const MemoryBook empty = MemoryBook();

  /// The note under each key, Markdown as the user typed it.
  final Map<String, String> notes;

  /// What the model learned under each key, oldest first.
  final Map<String, List<LearnedFact>> learned;

  /// Facts the model proposed and the user has not answered yet.
  final Map<String, List<String>> suggestions;

  /// Facts the user said no to — dismissed, deleted, or undone — so the model
  /// is not let learn them again. Bounded per key by
  /// [kPersonMemoryDismissedLimit].
  final Map<String, List<String>> dismissed;

  /// The last automatic update, for undoing it; null when there is none, or
  /// it was undone.
  final MemoryUndo? undo;

  /// The note for a person filed under [keys]: the distinct notes the keys
  /// hold, in key order, joined by a blank line. Empty when there is none.
  String noteFor(Iterable<String> keys) {
    final seen = <String>{};
    final parts = <String>[];
    for (final key in keys) {
      final note = notes[key]?.trim() ?? '';
      if (note.isNotEmpty && seen.add(note)) parts.add(note);
    }
    return parts.join('\n\n');
  }

  /// The facts waiting for an answer for [keys], without duplicates.
  List<String> suggestionsFor(Iterable<String> keys) =>
      _union(suggestions, keys);

  /// The facts learned for [keys], oldest first, without duplicates.
  List<LearnedFact> learnedFor(Iterable<String> keys) {
    final seen = <String>{};
    return [
      for (final key in keys)
        for (final fact in learned[key] ?? const <LearnedFact>[])
          if (seen.add(factKey(fact.text))) fact,
    ];
  }

  /// Everything known about [keys], as a prompt is told it: the user's note,
  /// then the learned facts it does not already say, as a list.
  String memoryFor(Iterable<String> keys) {
    final keyList = keys.toList();
    final note = noteFor(keyList);
    final facts = [
      for (final fact in learnedFor(keyList))
        if (!_noteSays(note, fact.text)) '- ${fact.text}',
    ];
    return [
      if (note.isNotEmpty) note,
      if (facts.isNotEmpty) facts.join('\n'),
    ].join('\n\n');
  }

  /// Whether the last automatic update touched any of [keys].
  bool undoTouches(Iterable<String> keys) =>
      undo != null && keys.any(undo!.before.containsKey);

  List<String> _dismissedFor(Iterable<String> keys) => _union(dismissed, keys);

  static List<String> _union(
    Map<String, List<String>> map,
    Iterable<String> keys,
  ) {
    final seen = <String>{};
    return [
      for (final key in keys)
        for (final fact in map[key] ?? const <String>[])
          if (seen.add(factKey(fact))) fact,
    ];
  }

  /// [note] as the note for every one of [keys]. An empty note removes it.
  MemoryBook withNote(Iterable<String> keys, String note) {
    final text = note.trim();
    return _copy(
      notes: {...notes, for (final key in keys) key: text}
        ..removeWhere((_, v) => v.isEmpty),
    );
  }

  /// Adds what the model [proposed] to the facts waiting for [keys] — minus
  /// anything already in the note, already waiting, or once dismissed. See
  /// [mergeFactSuggestions].
  MemoryBook withProposals(Iterable<String> keys, List<String> proposed) {
    final keyList = keys.toList();
    if (keyList.isEmpty) return this;
    final merged = mergeFactSuggestions(
      note: noteFor(keyList),
      pending: suggestionsFor(keyList),
      dismissed: _dismissedFor(keyList),
      proposed: proposed,
    );
    return _copy(suggestions: _setAll(suggestions, keyList, merged));
  }

  /// [fact] written into the note as a bullet, and no longer waiting.
  MemoryBook accept(Iterable<String> keys, String fact) {
    final keyList = keys.toList();
    final note = noteFor(keyList);
    final line = '- ${fact.trim()}';
    final next = withNote(keyList, note.isEmpty ? line : '$note\n$line');
    return next._copy(
      suggestions: _setAll(next.suggestions, keyList, [
        for (final s in next.suggestionsFor(keyList))
          if (factKey(s) != factKey(fact)) s,
      ]),
    );
  }

  /// [fact] written into the person memory under [personKeys] instead of the
  /// chat's, and no longer waiting under [chatKeys] — "Add to profile".
  MemoryBook promote(
    Iterable<String> chatKeys,
    Iterable<String> personKeys,
    String fact,
  ) {
    final chatList = chatKeys.toList();
    final personList = personKeys.toList();
    final note = noteFor(personList);
    final line = '- ${fact.trim()}';
    final next = withNote(personList, note.isEmpty ? line : '$note\n$line');
    return next._copy(
      suggestions: _setAll(next.suggestions, chatList, [
        for (final s in next.suggestionsFor(chatList))
          if (factKey(s) != factKey(fact)) s,
      ]),
    );
  }

  /// [fact] no longer waiting, and remembered as unwanted.
  MemoryBook dismiss(Iterable<String> keys, String fact) {
    final keyList = keys.toList();
    final no = [..._dismissedFor(keyList), fact];
    return _copy(
      suggestions: _setAll(suggestions, keyList, [
        for (final s in suggestionsFor(keyList))
          if (factKey(s) != factKey(fact)) s,
      ]),
      dismissed: _setAll(
        dismissed,
        keyList,
        no.length > kPersonMemoryDismissedLimit
            ? no.sublist(no.length - kPersonMemoryDismissedLimit)
            : no,
      ),
    );
  }

  /// Everything about the person filed under [keys] gone: note, waiting facts
  /// and dismissals.
  MemoryBook forget(Iterable<String> keys) {
    final keySet = keys.toSet();
    bool drop(String key, Object? _) => keySet.contains(key);
    final before = {...?undo?.before}..removeWhere(drop);
    return MemoryBook(
      notes: {...notes}..removeWhere(drop),
      learned: {...learned}..removeWhere(drop),
      suggestions: {...suggestions}..removeWhere(drop),
      dismissed: {...dismissed}..removeWhere(drop),
      undo: before.isEmpty ? null : undo!._only(before),
    );
  }

  /// [other]'s notes and learned facts added under the keys this book has
  /// none for — the restore rule every table in a backup follows: what is
  /// here wins.
  MemoryBook mergedWith(MemoryBook other) => _copy(
    notes: {...other.notes, ...notes},
    learned: {...other.learned, ...learned},
  );

  /// The note for every key, learned facts included — what a backup carries.
  /// Restored, the facts come back as part of the note: the user's from then
  /// on.
  Map<String, String> get notesWithLearned => {
    for (final key in {...notes.keys, ...learned.keys})
      if (memoryFor([key]) case final memory when memory.isNotEmpty)
        key: memory,
  };

  bool get isEmpty =>
      notes.isEmpty &&
      learned.isEmpty &&
      suggestions.isEmpty &&
      dismissed.isEmpty;

  /// [fact] under [keys] changed to [text] by the user, and pinned: the model
  /// never changes or drops it again. An empty [text] deletes it.
  MemoryBook editLearned(
    Iterable<String> keys,
    LearnedFact fact,
    String text, {
    required DateTime now,
  }) {
    final words = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (words.isEmpty) return deleteLearned(keys, fact);
    if (words == fact.text) return pinLearned(keys, fact, pinned: true);
    final keyList = keys.toList();
    return _copy(
      learned: _setAllFacts(learned, keyList, [
        for (final f in learnedFor(keyList))
          if (_same(f, fact))
            LearnedFact(words, at: now, pinned: true, edited: true)
          else
            f,
      ]),
    );
  }

  /// [fact] pinned — kept as it is whatever the model learns — or let go.
  MemoryBook pinLearned(
    Iterable<String> keys,
    LearnedFact fact, {
    required bool pinned,
  }) {
    final keyList = keys.toList();
    return _copy(
      learned: _setAllFacts(learned, keyList, [
        for (final f in learnedFor(keyList))
          _same(f, fact) ? f.copyWith(pinned: pinned) : f,
      ]),
    );
  }

  /// [fact] gone from [keys], and remembered as unwanted so it is not learned
  /// straight back.
  MemoryBook deleteLearned(Iterable<String> keys, LearnedFact fact) {
    final keyList = keys.toList();
    return _copy(
      learned: _setAllFacts(learned, keyList, [
        for (final f in learnedFor(keyList))
          if (!_same(f, fact)) f,
      ]),
      dismissed: _withDismissed(dismissed, keyList, [fact.text]),
    );
  }

  /// [update] applied to the learned facts of the chat filed under [chatKeys]
  /// and of its [people], as the automatic update it is: the user's notes and
  /// every pinned fact left as they are, what the update replaced kept for
  /// [undoAutomatic].
  ///
  /// [numbered] is what the ids in [update] point at, as [numberedFacts] gave
  /// them to the prompt. A new fact is filed under the person it is
  /// [MemoryAddition.about] when that names one of [people], else under the
  /// chat; it is left out when the note there already says it, the user once
  /// deleted it, or a learned fact says it already — and when it says more
  /// than a learned one, it takes that one's place. Each layer then keeps its
  /// newest [kChatLearnedLimit] or [kPersonLearnedLimit] facts, pinned ones
  /// always.
  ({MemoryBook book, int added, int updated, int dropped}) applyLearning(
    MemoryUpdate update, {
    required List<String> chatKeys,
    required List<MemoryPerson> people,
    required List<NumberedFact> numbered,
    required DateTime now,
  }) {
    // Every layer the update may touch, as lists to change in place.
    final layers = <String, ({List<String> keys, List<LearnedFact> facts})>{};
    ({List<String> keys, List<LearnedFact> facts}) layer(List<String> keys) =>
        layers.putIfAbsent(
          keys.join('\u0000'),
          () => (keys: keys, facts: learnedFor(keys).toList()),
        );
    var added = 0;
    var updated = 0;
    var dropped = 0;
    final addedTexts = <String, List<String>>{};
    void remember(List<String> keys, String text) =>
        (addedTexts[keys.join('\u0000')] ??= []).add(text);

    for (final change in update.updates) {
      if (change.id < 1 || change.id > numbered.length) continue;
      final target = numbered[change.id - 1];
      final facts = layer(target.keys).facts;
      final i = facts.indexWhere(
        (f) => factKey(f.text) == factKey(target.text),
      );
      if (i < 0 || facts[i].pinned) continue;
      final text = _cleanFact(change.fact);
      if (text == null) continue;
      if (factKey(text) == factKey(facts[i].text)) continue;
      facts[i] = LearnedFact(text, at: now);
      remember(target.keys, text);
      updated++;
    }
    for (final id in update.drops) {
      if (id < 1 || id > numbered.length) continue;
      final target = numbered[id - 1];
      final facts = layer(target.keys).facts;
      final before = facts.length;
      facts.removeWhere(
        (f) => !f.pinned && factKey(f.text) == factKey(target.text),
      );
      dropped += before - facts.length;
    }
    for (final addition in update.adds) {
      final text = _cleanFact(addition.fact);
      if (text == null) continue;
      final person = _personNamed(people, addition.about);
      final keys = person?.keys ?? chatKeys;
      if (keys.isEmpty) continue;
      final key = factKey(text);
      if (_dismissedFor(keys).any((d) => factKey(d) == key)) continue;
      if (_noteSays(noteFor(keys), text)) continue;
      // Said in the chat's memory already counts for a person's fact too.
      if (person != null && _noteSays(noteFor(chatKeys), text)) continue;
      final facts = layer(keys).facts;
      if (facts.any((f) => factKey(f.text).contains(key))) continue;
      // More than an unpinned fact said: it takes that one's place.
      final i = facts.indexWhere(
        (f) => !f.pinned && key.contains(factKey(f.text)),
      );
      if (i >= 0) {
        facts[i] = LearnedFact(text, at: now);
        updated++;
      } else {
        facts.add(LearnedFact(text, at: now));
        added++;
      }
      remember(keys, text);
    }
    if (added + updated + dropped == 0) {
      return (book: this, added: 0, updated: 0, dropped: 0);
    }

    var next = learned;
    final before = <String, List<LearnedFact>>{};
    final addedByKey = <String, List<String>>{};
    for (final MapEntry(key: id, value: (:keys, :facts)) in layers.entries) {
      for (final key in keys) {
        before[key] = learned[key] ?? const [];
        if (addedTexts[id] case final texts?) addedByKey[key] = texts;
      }
      final limit = id == chatKeys.join('\u0000')
          ? kChatLearnedLimit
          : kPersonLearnedLimit;
      next = _setAllFacts(next, keys, _keepNewest(facts, limit));
    }
    return (
      book: _copy(
        learned: next,
        undo: MemoryUndo(at: now, before: before, added: addedByKey),
      ),
      added: added,
      updated: updated,
      dropped: dropped,
    );
  }

  /// The last automatic update taken back: the learned facts it changed as
  /// they were before, minus what the user pinned since, and what it added
  /// remembered as unwanted. This book itself when there is nothing to undo.
  MemoryBook undoAutomatic() {
    final last = undo;
    if (last == null) return this;
    final next = {...learned};
    var no = dismissed;
    for (final MapEntry(:key, value: was) in last.before.entries) {
      final since = [
        for (final f in learned[key] ?? const <LearnedFact>[])
          if (f.pinned &&
              f.at.isAfter(last.at) &&
              !was.any((w) => factKey(w.text) == factKey(f.text)))
            f,
      ];
      final restored = [...was, ...since];
      if (restored.isEmpty) {
        next.remove(key);
      } else {
        next[key] = List.unmodifiable(restored);
      }
      if (last.added[key] case final texts?) {
        no = _withDismissed(no, [key], texts);
      }
    }
    return MemoryBook(
      notes: notes,
      learned: next,
      suggestions: suggestions,
      dismissed: no,
    );
  }

  /// The learned facts of the chat under [chatKeys] and of its [people] that
  /// the model may change, numbered from 1 in the order returned — pinned ones
  /// are not among them. At most [maxChars] of them in all, the chat's first.
  List<NumberedFact> numberedFacts(
    List<String> chatKeys,
    List<MemoryPerson> people, {
    int maxChars = 6000,
  }) {
    final result = <NumberedFact>[];
    var used = 0;
    for (final (keys, about) in [
      (chatKeys, null),
      for (final p in people) (p.keys, p.name),
    ]) {
      for (final fact in learnedFor(keys)) {
        if (fact.pinned) continue;
        used += fact.text.length + 12;
        if (used > maxChars) return result;
        result.add((keys: keys, about: about, text: fact.text));
      }
    }
    return result;
  }

  static bool _same(LearnedFact a, LearnedFact b) =>
      factKey(a.text) == factKey(b.text);

  static MemoryPerson? _personNamed(List<MemoryPerson> people, String? name) {
    final wanted = name?.trim().toLowerCase() ?? '';
    if (wanted.isEmpty || wanted == 'chat') return null;
    return people
            .where((p) => p.name.trim().toLowerCase() == wanted)
            .firstOrNull ??
        // "Anna" for a chat titled "Anna Schmidt".
        people
            .where(
              (p) =>
                  p.name.trim().toLowerCase().split(RegExp(r'\s+')).first ==
                  wanted.split(RegExp(r'\s+')).first,
            )
            .firstOrNull;
  }

  static String? _cleanFact(String raw) {
    final text = raw
        .replaceAll(RegExp(r'^\s*[-*•]\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (factKey(text).isEmpty || text.length > kPersonFactMaxChars) {
      return null;
    }
    return text;
  }

  /// [facts] cut to the newest [limit], every pinned one kept, in the order
  /// they were.
  static List<LearnedFact> _keepNewest(List<LearnedFact> facts, int limit) {
    if (facts.length <= limit) return facts;
    final unpinned = [
      for (final f in facts)
        if (!f.pinned) f,
    ]..sort((a, b) => b.at.compareTo(a.at));
    final room = math.max(0, limit - (facts.length - unpinned.length));
    final keep = unpinned.take(room).toSet();
    return [
      for (final f in facts)
        if (f.pinned || keep.contains(f)) f,
    ];
  }

  static Map<String, List<LearnedFact>> _setAllFacts(
    Map<String, List<LearnedFact>> map,
    List<String> keys,
    List<LearnedFact> value,
  ) =>
      {...map, for (final key in keys) key: List.unmodifiable(value)}
        ..removeWhere((_, v) => v.isEmpty);

  static Map<String, List<String>> _withDismissed(
    Map<String, List<String>> map,
    List<String> keys,
    List<String> facts,
  ) {
    final no = [..._union(map, keys), ...facts];
    return _setAll(
      map,
      keys,
      no.length > kPersonMemoryDismissedLimit
          ? no.sublist(no.length - kPersonMemoryDismissedLimit)
          : no,
    );
  }

  static Map<String, List<String>> _setAll(
    Map<String, List<String>> map,
    List<String> keys,
    List<String> value,
  ) =>
      {...map, for (final key in keys) key: List.unmodifiable(value)}
        ..removeWhere((_, v) => v.isEmpty);

  MemoryBook _copy({
    Map<String, String>? notes,
    Map<String, List<LearnedFact>>? learned,
    Map<String, List<String>>? suggestions,
    Map<String, List<String>>? dismissed,
    MemoryUndo? undo,
  }) => MemoryBook(
    notes: notes ?? this.notes,
    learned: learned ?? this.learned,
    suggestions: suggestions ?? this.suggestions,
    dismissed: dismissed ?? this.dismissed,
    undo: undo ?? this.undo,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'notes': notes,
    if (learned.isNotEmpty) 'learned': _factsJson(learned),
    if (suggestions.isNotEmpty) 'suggestions': suggestions,
    if (dismissed.isNotEmpty) 'dismissed': dismissed,
    if (undo != null) 'undo': undo!.toJson(),
  };

  static Map<String, Object?> _factsJson(Map<String, List<LearnedFact>> map) =>
      {
        for (final MapEntry(:key, :value) in map.entries)
          key: [for (final f in value) f.toJson()],
      };

  static Map<String, List<LearnedFact>> _factsFromJson(Object? raw) => {
    if (raw is Map)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key is String && value is List)
          key: List<LearnedFact>.unmodifiable(
            value.map(LearnedFact.fromJson).whereType<LearnedFact>(),
          ),
  }..removeWhere((_, v) => v.isEmpty);

  /// Never throws: anything unreadable is dropped, the rest kept.
  static MemoryBook fromJson(Object? json) {
    if (json is! Map) return empty;
    Map<String, String> strings(Object? raw) => {
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is String && value.trim().isNotEmpty)
            key: value,
    };
    Map<String, List<String>> lists(Object? raw) => {
      if (raw is Map)
        for (final MapEntry(:key, :value) in raw.entries)
          if (key is String && value is List)
            key: List.unmodifiable(value.whereType<String>()),
    }..removeWhere((_, v) => v.isEmpty);
    return MemoryBook(
      notes: strings(json['notes']),
      learned: _factsFromJson(json['learned']),
      suggestions: lists(json['suggestions']),
      dismissed: lists(json['dismissed']),
      undo: MemoryUndo.fromJson(json['undo']),
    );
  }

  /// The blob in the keychain, or [empty] for none or for one that is not
  /// JSON.
  static MemoryBook decode(String? blob) {
    if (blob == null || blob.isEmpty) return empty;
    try {
      return fromJson(jsonDecode(blob));
    } on FormatException {
      return empty;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  String toString() =>
      'MemoryBook(${notes.length} notes, ${learned.length} learned, '
      '${suggestions.length} with suggestions)';
}

/// Whether a line of [note] says [fact] already, compared through [factKey].
bool _noteSays(String note, String fact) {
  final key = factKey(fact);
  if (key.isEmpty) return false;
  return note.split('\n').any((line) => factKey(line).contains(key));
}

/// A fact the model learned on its own, or one the user changed since.
@immutable
class LearnedFact {
  const LearnedFact(
    this.text, {
    required this.at,
    this.pinned = false,
    this.edited = false,
  });

  /// One short sentence.
  final String text;

  /// When the model learned it, or last changed it — or when the user did.
  final DateTime at;

  /// The user edited or pinned it: the model never changes or drops it.
  final bool pinned;

  /// The user wrote this version of it.
  final bool edited;

  LearnedFact copyWith({bool? pinned}) =>
      LearnedFact(text, at: at, pinned: pinned ?? this.pinned, edited: edited);

  Map<String, Object?> toJson() => {
    't': text,
    'at': at.millisecondsSinceEpoch,
    if (pinned) 'pin': true,
    if (edited) 'edit': true,
  };

  static LearnedFact? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['t'];
    final at = json['at'];
    if (text is! String || text.trim().isEmpty || at is! int) return null;
    return LearnedFact(
      text,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      pinned: json['pin'] == true,
      edited: json['edit'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LearnedFact &&
      other.text == text &&
      other.at == at &&
      other.pinned == pinned &&
      other.edited == edited;

  @override
  int get hashCode => Object.hash(text, at, pinned, edited);

  @override
  String toString() => 'LearnedFact(${text.length} chars, $at)';
}

/// What the last automatic update replaced, for putting it back.
@immutable
class MemoryUndo {
  const MemoryUndo({
    required this.at,
    required this.before,
    this.added = const {},
  });

  /// When the update was made.
  final DateTime at;

  /// The learned facts under every key it touched, as they were — an empty
  /// list for a key that had none.
  final Map<String, List<LearnedFact>> before;

  /// What it added or rewrote, per key: remembered as unwanted once undone,
  /// so the next update does not learn it straight back.
  final Map<String, List<String>> added;

  MemoryUndo _only(Map<String, List<LearnedFact>> before) => MemoryUndo(
    at: at,
    before: before,
    added: {...added}..removeWhere((k, _) => !before.containsKey(k)),
  );

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'before': {
      for (final MapEntry(:key, :value) in before.entries)
        key: [for (final f in value) f.toJson()],
    },
    'added': added,
  };

  static MemoryUndo? fromJson(Object? json) {
    if (json is! Map || json['at'] is! int || json['before'] is! Map) {
      return null;
    }
    return MemoryUndo(
      at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
      before: {
        for (final MapEntry(:key, :value) in (json['before'] as Map).entries)
          if (key is String && value is List)
            key: List<LearnedFact>.unmodifiable(
              value.map(LearnedFact.fromJson).whereType<LearnedFact>(),
            ),
      },
      added: {
        if (json['added'] case final Map raw)
          for (final MapEntry(:key, :value) in raw.entries)
            if (key is String && value is List)
              key: List<String>.unmodifiable(value.whereType<String>()),
      },
    );
  }
}

/// A learned fact as the learning prompt numbers it: where it is filed, who it
/// is about (null for the chat), and what it says.
typedef NumberedFact = ({List<String> keys, String? about, String text});

/// The most learned facts one chat keeps; past it the oldest go first.
const int kChatLearnedLimit = 24;

/// The same for one person, whose memory is meant to stay a few lines.
const int kPersonLearnedLimit = 10;

/// The keys [MemoryBook] files [chat]'s own memory under: one per room the
/// chat is made of, so a merged chat finds what was written while its rooms
/// were separate chats, and each keeps it if they are split again.
List<String> chatMemoryKeys(Chat chat) => [
  for (final s in chat.sources) 'room:${s.roomId}',
];

/// The keys [MemoryBook] files the person [chat] is with under, or none for a
/// group — a group's people are found one by one, by [personKeysForSender].
///
/// [handles] are the handles of the chat's contact, every network the person
/// is merged across; their ids are the keys, because a handle id outlives the
/// contact id a merge or an unmerge mints. A direct chat with no handle — a
/// plain Matrix DM the identity graph has not met — is filed under its rooms,
/// with a prefix of its own so the person's memory is not the chat's.
List<String> personMemoryKeys({
  required Chat chat,
  required List<NetworkHandle> handles,
}) {
  if (chat.isGroup) return const [];
  if (handles.isNotEmpty) {
    return [for (final h in handles) 'handle:${h.id}'];
  }
  return [for (final s in chat.sources) 'dm:${s.roomId}'];
}

/// The keys a group member who wrote as [senderId] is filed under: their
/// contact's handles when Sennit knows the ghost, else the Matrix id itself.
///
/// [handlesOf] answers "every handle of the contact this Matrix user belongs
/// to", empty for a sender the identity graph has not met.
List<String> personKeysForSender(
  String senderId,
  List<NetworkHandle> Function(String matrixUserId) handlesOf,
) {
  final handles = handlesOf(senderId);
  if (handles.isNotEmpty) return [for (final h in handles) 'handle:${h.id}'];
  return ['user:$senderId'];
}

/// A person whose memory may go into a prompt: the name the model is told,
/// and the keys their note is filed under.
typedef MemoryPerson = ({String name, List<String> keys});

/// What the AI features are told about a conversation: the chat's own note
/// and the short notes of the people in it, most relevant first.
@immutable
class AiMemory {
  const AiMemory({this.chat = '', this.people = const []});

  /// The chat memory, untrimmed.
  final String chat;

  /// `(name, note)` per person, untrimmed, in the order they matter — for a
  /// group, the most recent speaker first.
  final List<({String name, String note})> people;

  bool get isEmpty =>
      chat.trim().isEmpty && people.every((p) => p.note.trim().isEmpty);

  @override
  String toString() =>
      'AiMemory(chat: ${chat.length} chars, ${people.length} people)';
}

/// The most of one person's note a prompt carries, for a hosted model.
const int kPersonMemoryHostedChars = 400;

/// The same for a self-hosted one.
const int kPersonMemoryLocalChars = 160;

/// The person memory a user is nudged to stay under in the editor: a few
/// lines. Not enforced — the prompt trims to [kPersonMemoryHostedChars] — but
/// past it the "condense" action is offered.
const int kPersonMemorySoftLimit = 300;

/// The most of everything [memoryPromptBlock] sends, for a hosted model — about
/// three hundred tokens.
const int kAiMemoryHostedChars = 1200;

/// The same for a self-hosted one — about a hundred tokens. A phone-sized
/// model reads every token of the prompt before it writes one, and a long
/// note costs seconds there that it costs nothing on an API.
const int kAiMemoryLocalChars = 400;

/// How many dismissed facts are remembered per person; older ones may be
/// offered again, which after fifty refusals is a fair thing to forget.
const int kPersonMemoryDismissedLimit = 50;

/// The shape two facts are compared in: case, punctuation and a leading
/// bullet do not make "Has two kids." new beside "- has two kids".
String factKey(String fact) => fact
    .toLowerCase()
    .replaceAll(RegExp(r'^\s*[-*•]\s*'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// What is left of [proposed] to offer: each fact once, at most
/// [kPersonMemoryMaxSuggestions] waiting in all, and none the [note] already
/// says, that is already [pending], or that the user once [dismissed].
///
/// "Already says" is a line of the note containing the fact, compared through
/// [factKey] — so "Has two kids" is not offered under a note that reads
/// "- has two kids: Mia and Ben". Crude, and the direction it errs in is
/// offering something nearly said, which costs a tap.
List<String> mergeFactSuggestions({
  required String note,
  required List<String> pending,
  required List<String> dismissed,
  required List<String> proposed,
}) {
  final noteLines = [
    for (final line in note.split('\n'))
      if (factKey(line).isNotEmpty) factKey(line),
  ];
  final known = {
    for (final f in [...pending, ...dismissed]) factKey(f),
  };
  final result = [...pending];
  for (final raw in proposed) {
    if (result.length >= kPersonMemoryMaxSuggestions) break;
    final fact = raw.trim();
    final key = factKey(fact);
    if (key.isEmpty || !known.add(key)) continue;
    if (noteLines.any((line) => line.contains(key))) continue;
    result.add(fact);
  }
  return result;
}

/// How many facts may wait for an answer per person.
const int kPersonMemoryMaxSuggestions = 8;

/// [note] made ready for a prompt: comments, headings with nothing under them
/// and runs of blank lines gone, then cut at a whole line to [maxChars].
///
/// The headings are what the editor suggests as a starting point, and a model
/// sent "## Birthday" with nothing after it reads it as something to fill in.
/// Cut from the end because the user writes what matters first, the way the
/// editor's hint lays it out; a first line longer than the whole budget is
/// cut at a word and marked.
String trimPersonMemory(String note, {required int maxChars}) {
  final text = note.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final lines = [for (final l in text.split('\n')) l.trimRight()];
  bool isHeading(String l) => RegExp(r'^\s*#{1,6}\s').hasMatch(l);
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (isHeading(line)) {
      // Kept only when something that is not another heading follows before
      // the next one.
      final next = lines
          .skip(i + 1)
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (next.isEmpty || isHeading(next)) continue;
    }
    if (line.trim().isEmpty && (kept.isEmpty || kept.last.isEmpty)) continue;
    kept.add(line.trim().isEmpty ? '' : line);
  }
  while (kept.isNotEmpty && kept.last.isEmpty) {
    kept.removeLast();
  }

  final out = StringBuffer();
  for (final line in kept) {
    final extra = (out.isEmpty ? 0 : 1) + line.length;
    if (out.length + extra <= maxChars) {
      if (out.isNotEmpty) out.write('\n');
      out.write(line);
      continue;
    }
    if (out.isEmpty) {
      final cut = line.substring(0, maxChars - 1).lastIndexOf(' ');
      out.write('${line.substring(0, cut > 0 ? cut : maxChars - 1)}…');
    }
    break;
  }
  // A heading left last by the cut has nothing under it any more.
  final result = out.toString().split('\n');
  while (result.isNotEmpty &&
      (result.last.trim().isEmpty || isHeading(result.last))) {
    result.removeLast();
  }
  return result.join('\n');
}

/// The whole budget [memoryPromptBlock] has for [baseUrl] when it is given no
/// [LlmBudget] — the figures from before the window was known.
int aiMemoryBudget(String baseUrl) =>
    isHostedLlm(baseUrl) ? kAiMemoryHostedChars : kAiMemoryLocalChars;

/// The paragraph the system message of a quick message, an auto-reply or the
/// reply chips ends with, or nothing when there is nothing to send.
///
/// One wording for every feature, for the reason `calendarPromptBlock` is
/// shared, and each [feature]'s share of the memory budget — see
/// [LlmBudget.memoryCharsFor]. The people come first and get at most half of
/// [LlmBudget.memoryChars] between them, each cut to
/// [LlmBudget.personMemoryChars] — without a [budget], [aiMemoryBudget] and
/// [kPersonMemoryHostedChars] (or the local figure). In a group the list is in order of who spoke last, and
/// whoever does not fit is left out rather than everyone cut to nothing. The
/// chat memory gets what is left, which is at least the other half.
///
/// "Never quote" is there because a model handed a list of facts likes to
/// show it read them — "Happy birthday, and say hi to Mia and Ben, your two
/// kids!" — and a note is there to set the tone, not to be recited.
String memoryPromptBlock(
  AiMemory? memory, {
  required String baseUrl,
  LlmBudget? budget,
  AiFeature? feature,
}) {
  if (memory == null || memory.isEmpty) return '';
  final hosted = isHostedLlm(baseUrl);
  final chars = budget == null
      ? aiMemoryBudget(baseUrl)
      : feature == null
      ? budget.memoryChars
      : budget.memoryCharsFor(feature);
  final personCap =
      budget?.personMemoryChars ??
      (hosted ? kPersonMemoryHostedChars : kPersonMemoryLocalChars);

  final people = <String>[];
  var used = 0;
  for (final person in memory.people) {
    final note = trimPersonMemory(person.note, maxChars: personCap);
    if (note.isEmpty) continue;
    final entry = 'About ${person.name}:\n$note';
    if (used + entry.length > chars ~/ 2) {
      if (people.isEmpty) continue;
      break;
    }
    people.add(entry);
    used += entry.length + 2;
  }
  const chatHeading = 'About this chat:\n';
  final chat = trimPersonMemory(
    memory.chat,
    maxChars: chars - used - chatHeading.length,
  );
  if (people.isEmpty && chat.isEmpty) return '';

  return '\n\nWhat the user has noted and what was learned from their chats '
      '(private; use it for the names to call people, the language, the '
      'tone — formal or informal, emojis or not — and what matters to them; '
      'never quote it and never mention that there are notes):\n'
      '${[...people, if (chat.isNotEmpty) '$chatHeading$chat'].join('\n\n')}';
}

/// Why asking for facts got no list, passed to `onError` of
/// [requestMemoryUpdate].
enum PersonFactsError {
  /// The server answered with an error status; see [PersonFactsFailure.status].
  http,

  /// The model stopped at the budget before it wrote an answer — a thinking
  /// model still thinking.
  cutOff,

  /// The model answered, but not with the JSON it was asked for.
  unreadable,
}

/// A [PersonFactsError] as `onError` receives it.
class PersonFactsFailure implements Exception {
  const PersonFactsFailure(this.error, {this.status});

  final PersonFactsError error;

  /// The HTTP status, for [PersonFactsError.http].
  final int? status;

  @override
  String toString() =>
      'PersonFactsFailure(${error.name}${status == null ? '' : ' $status'})';
}

/// A fact the model wants added, and who it is about: a person's name, or
/// null for the chat.
@immutable
class MemoryAddition {
  const MemoryAddition(this.fact, {this.about});

  final String fact;
  final String? about;
}

/// What the model wants changed in what is remembered about a chat: facts to
/// add, numbered facts to rewrite, numbered facts to drop. The numbers are
/// [MemoryBook.numberedFacts]'s, from 1.
@immutable
class MemoryUpdate {
  const MemoryUpdate({
    this.adds = const [],
    this.updates = const [],
    this.drops = const [],
  });

  final List<MemoryAddition> adds;
  final List<({int id, String fact})> updates;
  final List<int> drops;

  bool get isEmpty => adds.isEmpty && updates.isEmpty && drops.isEmpty;

  @override
  String toString() =>
      'MemoryUpdate(+${adds.length} ~${updates.length} -${drops.length})';
}

/// The chat completion messages that ask what to change in what is remembered
/// about the conversation [chatTitle].
///
/// Separate from [requestMemoryUpdate] so the prompt can be tested without an
/// endpoint. [fixed] is what the user wrote and pinned — the model is told it
/// so it does not repeat it, and is given no way to change it. [numbered] is
/// what was learned before, which it may rewrite or drop by number. [people]
/// are the names a fact may be filed under; anything else is the chat's.
List<Map<String, String>> memoryUpdateRequest({
  required List<String> transcript,
  required String chatTitle,
  required List<String> people,
  String fixed = '',
  List<NumberedFact> numbered = const [],
}) => [
  {
    'role': 'system',
    'content':
        'You keep what the user\'s assistant remembers about a chat and the '
        'people in it up to date. From the conversation, find facts that '
        'would still be worth knowing in a month: what someone likes to be '
        'called, family and partner names, birthdays, job, the language and '
        'tone used (du or Sie, emojis or not), likes and dislikes, plans, '
        'ongoing topics, running jokes. Only what the messages say plainly — '
        'no guesses, nothing about the user ("You"), nothing that only '
        'matters today. Compare with what is remembered: add what is new, '
        'update a numbered fact the conversation changed, drop a numbered '
        'fact that is no longer true or no longer matters, and never repeat '
        'what the user wrote. Each fact is one short sentence in the language '
        'of the conversation. "about" is a person\'s name for what matters in '
        'every chat with them — name, relationship, birthday, family, job, du '
        'or Sie, language — and "chat" for plans, topics, the tone here and '
        'everything else. Output ONLY a JSON object {"add": [{"fact": ..., '
        '"about": ...}], "update": [{"id": number, "fact": ...}], "drop": '
        '[numbers]} — empty lists when nothing changes.',
  },
  {
    'role': 'user',
    'content': memoryUpdatePrompt(
      transcript: const [
        'Lea: Mia hat am 12. März Geburtstag, sie wird 5!',
        'You: Wie schnell die Zeit vergeht',
        'Lea: Ja 🙈 Hab bei der Post gekündigt, ab Montag bin ich bei der Bahn',
      ],
      chatTitle: 'Lea',
      people: const ['Lea'],
      fixed: 'About Lea:\n- Meine Schwester',
      numbered: const [
        (keys: [], about: 'Lea', text: 'Arbeitet bei der Post'),
        (keys: [], about: null, text: 'Schreibt locker, mit Emojis'),
      ],
    ),
  },
  {
    'role': 'assistant',
    'content':
        '{"add": [{"fact": "Tochter Mia, Geburtstag am 12. März", '
        '"about": "Lea"}], "update": [{"id": 1, "fact": "Arbeitet ab '
        'Montag bei der Bahn"}], "drop": []}',
  },
  {
    'role': 'user',
    'content': memoryUpdatePrompt(
      transcript: transcript,
      chatTitle: chatTitle,
      people: people,
      fixed: fixed,
      numbered: numbered,
    ),
  },
];

/// The user turn of [memoryUpdateRequest].
String memoryUpdatePrompt({
  required List<String> transcript,
  required String chatTitle,
  required List<String> people,
  String fixed = '',
  List<NumberedFact> numbered = const [],
}) {
  final buffer = StringBuffer()
    ..writeln('Conversation "$chatTitle" (newest message last):')
    ..writeln(transcript.join('\n'))
    ..writeln()
    ..writeln(
      'People: ${people.isEmpty ? '(only the chat)' : people.join(', ')}',
    )
    ..writeln()
    ..writeln('The user wrote (fixed):')
    ..writeln(fixed.trim().isEmpty ? '(nothing)' : fixed.trim())
    ..writeln()
    ..writeln('Learned so far:');
  if (numbered.isEmpty) buffer.writeln('(nothing)');
  for (var i = 0; i < numbered.length; i++) {
    buffer.writeln(
      '${i + 1}. [${numbered[i].about ?? 'chat'}] ${numbered[i].text}',
    );
  }
  buffer
    ..writeln()
    ..write('JSON:');
  return buffer.toString();
}

/// Asks the configured LLM what to change in what is remembered about a
/// conversation.
///
/// The answer is applied by `MemoryBook.applyLearning`, which keeps the
/// user's notes and pinned facts out of its reach whatever the model says.
/// Null on any failure; the caller learns which it was through [onError],
/// which gets a [PersonFactsFailure] for an answer with nothing readable in it
/// and the thrown error for a request that failed.
Future<MemoryUpdate?> requestMemoryUpdate({
  required String baseUrl,
  required String model,
  String? apiKey,
  required List<String> transcript,
  required String chatTitle,
  List<String> people = const [],
  String fixed = '',
  List<NumberedFact> numbered = const [],
  LlmBudget? budget,
  http.Client? client,
  Duration? timeout,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || transcript.isEmpty) {
    return null;
  }
  final limits = budget ?? LlmBudget.resolve(base);
  final answer = await _complete(
    base: base,
    model: model,
    apiKey: apiKey,
    what: 'memory update',
    temperature: 0.2,
    budget: limits.forFeature(AiFeature.learnFacts),
    answered: (content) => parseMemoryUpdate(content) != null,
    messages: memoryUpdateRequest(
      transcript: transcript,
      chatTitle: chatTitle,
      people: people,
      fixed: fixed,
      numbered: numbered,
    ),
    timeout: timeout ?? llmResponseTimeout(base, LlmTask.personFacts),
    client: client,
    cancel: cancel,
    onError: onError,
  );
  if (answer == null) return null;
  final update = parseMemoryUpdate(answer.content ?? '');
  // Counts and the finish reason only: never what the model said.
  debugPrint(
    'weft: memory update: ${transcript.length} lines sent, '
    '${update ?? 'nothing readable'}, finish ${answer.finishReason}',
  );
  if (update == null) {
    onError?.call(
      PersonFactsFailure(
        answer.finishReason == 'length'
            ? PersonFactsError.cutOff
            : PersonFactsError.unreadable,
      ),
    );
  }
  return update;
}

/// The changes in whatever the model said: the `{"add", "update", "drop"}`
/// object the prompt asks for, through a code fence or `<think>` block — or,
/// from a model that answers in the older shape, a `{"facts": [...]}` list,
/// read as additions to the chat.
///
/// Null when there is nothing readable in it, which is not the same as an
/// empty update: "nothing changes" is three empty lists.
MemoryUpdate? parseMemoryUpdate(String content) {
  final text = _answerText(content);
  if (text == null) return null;
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final parsed = jsonDecode(text.substring(start, end + 1));
      if (parsed is Map &&
          (parsed['add'] is List ||
              parsed['update'] is List ||
              parsed['drop'] is List)) {
        return _memoryUpdateFrom(parsed);
      }
    } on FormatException {
      // The older shape, below.
    }
  }
  final facts = parsePersonFacts(content);
  if (facts == null) return null;
  return MemoryUpdate(adds: [for (final f in facts) MemoryAddition(f)]);
}

MemoryUpdate _memoryUpdateFrom(Map<Object?, Object?> json) {
  int? number(Object? v) => switch (v) {
    int() => v,
    String() => int.tryParse(v.trim()),
    _ => null,
  };
  final adds = <MemoryAddition>[];
  for (final entry in json['add'] is List ? json['add']! as List : const []) {
    final fact = _factText(
      entry is Map ? (Map<Object?, Object?>.of(entry)..remove('about')) : entry,
    );
    if (fact == null || fact.trim().isEmpty) continue;
    final about = entry is Map && entry['about'] is String
        ? (entry['about'] as String).trim()
        : null;
    adds.add(
      MemoryAddition(
        fact.trim(),
        about: about == null || about.isEmpty || about.toLowerCase() == 'chat'
            ? null
            : about,
      ),
    );
    if (adds.length >= kPersonMemoryMaxSuggestions) break;
  }
  final updates = <({int id, String fact})>[];
  for (final entry
      in json['update'] is List ? json['update']! as List : const []) {
    if (entry is! Map) continue;
    final id = number(entry['id']);
    final fact = _factText(entry);
    if (id == null || fact == null || fact.trim().isEmpty) continue;
    updates.add((id: id, fact: fact.trim()));
  }
  final drops = [
    for (final entry in json['drop'] is List ? json['drop']! as List : const [])
      ?number(entry is Map ? entry['id'] : entry),
  ];
  return MemoryUpdate(adds: adds, updates: updates, drops: drops);
}

/// What a model said with its reasoning and a code fence taken off, or null
/// for reasoning that never ended.
String? _answerText(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  // A chat template that opens the <think> itself leaves only the closing tag
  // in the answer, after reasoning that may quote a list of its own.
  final close = text.toLowerCase().lastIndexOf('</think>');
  if (close >= 0) text = text.substring(close + '</think>'.length).trim();
  final fence = RegExp(r'```[\w-]*\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  return text;
}

/// The chat completion messages that ask for [note] about [name] cut down to
/// a few lines.
List<Map<String, String>> condenseRequest({
  required String name,
  required String note,
}) => [
  {
    'role': 'system',
    'content':
        'You shorten the notes a user keeps about a person, for use in every '
        'chat with them. Keep only what matters in any conversation: what '
        'they like to be called, relationship, birthday, du or Sie, language, '
        'the few facts that matter most. Drop plans, topics and details that '
        'only matter in one chat. At most five short lines, as a Markdown '
        'list, in the language of the notes. Never add anything the notes do '
        'not say. Output ONLY a JSON object with a "memory" string.',
  },
  {'role': 'user', 'content': 'Notes about $name:\n${note.trim()}\n\nJSON:'},
];

/// Asks the configured LLM for a short version of the person memory [note].
///
/// Like a proposed fact, the answer is only offered: the editor shows it and
/// the user replaces the note with it, or does not. Null on any failure, or
/// for an answer with nothing in it.
Future<String?> condensePersonMemory({
  required String baseUrl,
  required String model,
  String? apiKey,
  required String name,
  required String note,
  LlmBudget? budget,
  http.Client? client,
  Duration? timeout,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || model.trim().isEmpty || note.trim().isEmpty) return null;
  final answer = await _complete(
    base: base,
    model: model,
    apiKey: apiKey,
    what: 'condense',
    temperature: 0.2,
    budget: (budget ?? LlmBudget.resolve(base)).forFeature(AiFeature.condense),
    answered: (content) => parseCondensed(content) != null,
    messages: condenseRequest(name: name, note: note),
    timeout: timeout ?? llmResponseTimeout(base, LlmTask.personFacts),
    client: client,
    cancel: cancel,
    onError: onError,
  );
  final content = answer?.content;
  return content == null ? null : parseCondensed(content);
}

/// The short version in whatever the model said: the `{"memory": "…"}` the
/// prompt asks for, or plain text through a code fence. Null for nothing, or
/// for reasoning that never ended.
String? parseCondensed(String content) {
  var text = content
      .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
      .trim();
  if (RegExp(r'^<think>', caseSensitive: false).hasMatch(text)) return null;
  final fence = RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final parsed = jsonDecode(text.substring(start, end + 1));
      if (parsed is Map && parsed['memory'] is String) {
        text = parsed['memory'] as String;
      }
    } on FormatException {
      // Plain text, then.
    }
  }
  text = text.trim();
  if (text.isEmpty || !RegExp(r'\p{L}', unicode: true).hasMatch(text)) {
    return null;
  }
  return trimPersonMemory(text, maxChars: kPersonMemoryHostedChars);
}

/// One completion: its text, null when the model gave none, and why it
/// stopped. Null for a request that failed. Cut off before [answered] accepts
/// what it wrote, the model is asked once more with [budget]'s retry room.
/// Logs the status and the error type only: what was said, and what the user
/// wrote about anyone, stay out of the log.
Future<({String? content, String? finishReason})?> _complete({
  required String base,
  required String model,
  String? apiKey,
  required String what,
  required double temperature,
  required FeatureBudget budget,
  required bool Function(String content) answered,
  required List<Map<String, String>> messages,
  required Duration timeout,
  http.Client? client,
  Future<void>? cancel,
  void Function(Object error)? onError,
}) async {
  final url = Uri.parse('$base/chat/completions');
  final owned = client == null;
  final httpClient = client ?? llmHttpClient();
  try {
    final answer = await requestCompletion(
      httpClient,
      url,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      },
      body: {'model': model, 'temperature': temperature, 'messages': messages},
      maxTokens: budget.maxTokens,
      retryMaxTokens: budget.retryMaxTokens,
      answered: answered,
      timeout: timeout,
      cancel: cancel,
      what: what,
    );
    if (!answer.ok) {
      debugPrint('weft: $what: $url answered ${answer.status}');
      onError?.call(
        PersonFactsFailure(PersonFactsError.http, status: answer.status),
      );
      return null;
    }
    return (content: answer.content, finishReason: answer.finishReason);
  } on Object catch (error) {
    debugPrint('weft: $what against $url failed: ${error.runtimeType}');
    onError?.call(error);
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// The facts in whatever the model said: the `{"facts": [...]}` the prompt
/// asks for, or a bare list, through a code fence or `<think>` block. JSON or
/// nothing, for the reason `parseSmartReplies` gives — a model's analysis
/// turned into "facts" would be worse than none.
///
/// Null when there is no list in it at all, which is not the same answer as
/// an empty one: "nothing worth keeping" is `[]`, and reasoning that never
/// ended, or prose, is null. Facts written as objects — `{"person": "Tom",
/// "fact": "Runs"}` — are read too; a small model adds the shape it likes.
List<String>? parsePersonFacts(String content) {
  final text = _answerText(content);
  if (text == null) return null;

  List<Object?>? raw;
  final objStart = text.indexOf('{');
  final objEnd = text.lastIndexOf('}');
  if (objStart >= 0 && objEnd > objStart) {
    try {
      final parsed = jsonDecode(text.substring(objStart, objEnd + 1));
      if (parsed is Map && parsed['facts'] is List) {
        raw = parsed['facts'] as List;
      }
    } on FormatException {
      // Try the bare list below.
    }
  }
  if (raw == null) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) {
      try {
        final parsed = jsonDecode(text.substring(start, end + 1));
        if (parsed is List) raw = parsed;
      } on FormatException {
        // Not JSON: no facts.
      }
    }
  }
  if (raw == null) return null;
  final seen = <String>{};
  return [
    for (final fact in raw.map(_factText).whereType<String>())
      if (fact.trim().isNotEmpty &&
          fact.trim().length <= kPersonFactMaxChars &&
          seen.add(factKey(fact)))
        fact.trim().replaceAll(RegExp(r'\s+'), ' '),
  ].take(kPersonMemoryMaxSuggestions).toList(growable: false);
}

/// One entry of the list as a sentence: a string as it is, or an object's
/// fact, after the name of whoever it is about when it says.
String? _factText(Object? entry) {
  if (entry is String) return entry;
  if (entry is! Map) return null;
  final fact = [
    'fact',
    'text',
    'content',
  ].map((k) => entry[k]).whereType<String>().firstOrNull;
  if (fact == null) return null;
  final who = [
    'person',
    'name',
    'about',
  ].map((k) => entry[k]).whereType<String>().firstOrNull?.trim();
  if (who == null || who.isEmpty || fact.trim().startsWith(who)) return fact;
  return '$who: ${fact.trim()}';
}

/// The longest fact offered; past this the model is writing a summary.
const int kPersonFactMaxChars = 160;
