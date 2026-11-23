import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:weft_domain/weft_domain.dart';

/// How many new messages make a chat due at once, whenever it was last read.
const int kMemoryLearnAfterMessages = 30;

/// The fewest new messages that make a chat due for its daily pass.
const int kMemoryLearnDailyMessages = 3;

/// How long a chat waits for its daily pass after the last one.
const Duration kMemoryLearnDaily = Duration(hours: 24);

/// The least time between two passes over one chat, however busy it is.
const Duration kMemoryLearnMinGap = Duration(minutes: 30);

/// How long a chat waits after a pass that failed — the endpoint down, the
/// model cut off — before it is tried again.
const Duration kMemoryLearnRetry = Duration(hours: 2);

/// How often due chats are looked for while Sennit is in front.
const Duration kMemoryLearnTick = Duration(minutes: 10);

/// The least time between two passes, over any chats: a dozen chats coming
/// due together are a dozen completions a minute apart, not at once.
const Duration kMemoryLearnSpacing = Duration(minutes: 1);

/// The most passes in a day, all chats together — a ceiling for a hosted
/// endpoint's bill, well above what a normal day of chatting comes to.
const int kMemoryLearnMaxPerDay = 48;

/// Where one chat stands: what arrived since it was last read, and when that
/// was.
@immutable
class MemoryLearnState {
  const MemoryLearnState({
    this.newMessages = 0,
    this.lastLearned,
    this.lastTried,
  });

  /// Messages that arrived since the last pass that went through.
  final int newMessages;

  /// When a pass last went through, whatever it learned.
  final DateTime? lastLearned;

  /// When a pass was last started, whether or not it went through.
  final DateTime? lastTried;

  MemoryLearnState copyWith({
    int? newMessages,
    DateTime? lastLearned,
    DateTime? lastTried,
  }) => MemoryLearnState(
    newMessages: newMessages ?? this.newMessages,
    lastLearned: lastLearned ?? this.lastLearned,
    lastTried: lastTried ?? this.lastTried,
  );

  Map<String, Object?> toJson() => {
    'n': newMessages,
    'learned': ?lastLearned?.millisecondsSinceEpoch,
    'tried': ?lastTried?.millisecondsSinceEpoch,
  };

  static MemoryLearnState fromJson(Object? json) {
    if (json is! Map) return const MemoryLearnState();
    DateTime? time(Object? v) =>
        v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return MemoryLearnState(
      newMessages: json['n'] is int ? json['n'] as int : 0,
      lastLearned: time(json['learned']),
      lastTried: time(json['tried']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MemoryLearnState &&
      other.newMessages == newMessages &&
      other.lastLearned == lastLearned &&
      other.lastTried == lastTried;

  @override
  int get hashCode => Object.hash(newMessages, lastLearned, lastTried);

  @override
  String toString() =>
      'MemoryLearnState($newMessages new, learned $lastLearned, '
      'tried $lastTried)';
}

/// Whether a chat in [state] is due for a pass at [now].
///
/// Due after [kMemoryLearnAfterMessages] new messages, or once a day when at
/// least [kMemoryLearnDailyMessages] arrived — the first pass of a chat never
/// read counts as its daily one. Never within [kMemoryLearnMinGap] of the last
/// try, nor within [kMemoryLearnRetry] of one that failed.
bool memoryLearnDue(MemoryLearnState state, DateTime now) {
  if (state.newMessages <= 0) return false;
  final tried = state.lastTried;
  final learned = state.lastLearned;
  if (tried != null) {
    final since = now.difference(tried);
    if (since < kMemoryLearnMinGap) return false;
    final failed = learned == null || tried.isAfter(learned);
    if (failed && since < kMemoryLearnRetry) return false;
  }
  if (state.newMessages >= kMemoryLearnAfterMessages) return true;
  return state.newMessages >= kMemoryLearnDailyMessages &&
      (learned == null || now.difference(learned) >= kMemoryLearnDaily);
}

/// Keeps personal memory up to date on its own, a chat at a time.
///
/// Counts what arrives per chat and, while Sennit is in front, reads a chat
/// again when [memoryLearnDue] says so: after a burst of conversation, or once
/// a day for a chat that has been active. One pass at a time, at most one a
/// [kMemoryLearnSpacing], at most [kMemoryLearnMaxPerDay] a day. Only in front
/// for the reason the embedding backfill is: a backgrounded phone is in Doze,
/// on mobile data, on battery, and a pass that pages history and waits on a
/// model has no business there — the counts simply wait for the next time the
/// app is opened.
///
/// The orchestration only, like `TodoAgent`: what a pass sends and writes is
/// [learn] — `learnPersonFacts`, which checks every gate again; true when the
/// pass went through, whatever it learned, false when it should be tried
/// again later — and whether
/// passes run at all is [enabled], read per check so the switches in settings
/// take effect at once. Counting goes on while it is off, so switching it on
/// finds the chats that were busy.
class MemoryLearner {
  MemoryLearner({
    required Stream<WeftMessage> incoming,
    required Chat? Function(String roomId) chatForRoom,
    required Chat? Function(String chatId) chatById,
    required bool Function(String chatId) isServiceChat,
    required bool Function(Chat chat) isBroadcast,
    required bool Function() enabled,
    required Future<bool> Function(Chat chat, MemoryLearnState state) learn,
    Map<String, MemoryLearnState> Function()? load,
    void Function(Map<String, MemoryLearnState> states)? save,
    ValueListenable<bool>? foreground,
    DateTime Function()? now,
    Duration tick = kMemoryLearnTick,
    Duration spacing = kMemoryLearnSpacing,
  }) : _incoming = incoming,
       _chatForRoom = chatForRoom,
       _chatById = chatById,
       _isServiceChat = isServiceChat,
       _isBroadcast = isBroadcast,
       _enabled = enabled,
       _learn = learn,
       _save = save,
       _foreground = foreground,
       _now = now ?? DateTime.now,
       _tick = tick,
       _spacing = spacing,
       _states = {...?load?.call()};

  final Stream<WeftMessage> _incoming;
  final Chat? Function(String roomId) _chatForRoom;
  final Chat? Function(String chatId) _chatById;
  final bool Function(String chatId) _isServiceChat;
  final bool Function(Chat chat) _isBroadcast;
  final bool Function() _enabled;
  final Future<bool> Function(Chat chat, MemoryLearnState state) _learn;
  final void Function(Map<String, MemoryLearnState> states)? _save;
  final ValueListenable<bool>? _foreground;
  final DateTime Function() _now;
  final Duration _tick;
  final Duration _spacing;

  final Map<String, MemoryLearnState> _states;
  final List<DateTime> _passes = [];
  StreamSubscription<WeftMessage>? _sub;
  Timer? _ticker;
  Timer? _saveTimer;
  Timer? _again;
  DateTime? _lastPass;
  bool _running = false;
  bool _disposed = false;

  /// Where each chat stands, for tests and the log.
  Map<String, MemoryLearnState> get states => Map.unmodifiable(_states);

  /// Whether a pass is under way.
  bool get running => _running;

  bool get _inForeground => _foreground?.value ?? true;

  void start() {
    _sub ??= _incoming.listen(
      handleMessage,
      onError: (Object error) =>
          debugPrint('weft: memory learner stream failed: $error'),
    );
    _foreground?.addListener(_onForegroundChanged);
    _ticker ??= Timer.periodic(_tick, (_) => unawaited(check()));
    unawaited(check());
  }

  Future<void> dispose() async {
    _disposed = true;
    _foreground?.removeListener(_onForegroundChanged);
    _ticker?.cancel();
    _again?.cancel();
    _saveTimer?.cancel();
    _persist();
    await _sub?.cancel();
    _sub = null;
  }

  void _onForegroundChanged() {
    if (_inForeground) unawaited(check());
  }

  /// Counts [message] for its chat, and checks for a due chat when that one
  /// just became due.
  void handleMessage(WeftMessage message) {
    if (_disposed) return;
    final chat = _chatForRoom(message.roomId);
    if (chat == null || chat.isPendingRequest) return;
    if (_isServiceChat(chat.id) || _isBroadcast(chat)) return;
    if (message.redacted || message.isBridgeNotice || message.isAutoReply) {
      return;
    }
    final before = _states[chat.id] ?? const MemoryLearnState();
    final after = before.copyWith(newMessages: before.newMessages + 1);
    _states[chat.id] = after;
    _persistSoon();
    final now = _now();
    if (!memoryLearnDue(before, now) && memoryLearnDue(after, now)) {
      unawaited(check());
    }
  }

  /// Runs a pass over the chat most overdue, when one is due and nothing says
  /// to wait. Returns the id of the chat read, or null.
  Future<String?> check() async {
    if (_disposed || _running || !_inForeground || !_enabled()) return null;
    final now = _now();
    if (_lastPass case final last? when now.difference(last) < _spacing) {
      _checkAfter(_spacing - now.difference(last));
      return null;
    }
    _passes.removeWhere((t) => now.difference(t) >= const Duration(hours: 24));
    if (_passes.length >= kMemoryLearnMaxPerDay) return null;

    String? dueId;
    for (final MapEntry(key: id, value: state) in _states.entries) {
      if (!memoryLearnDue(state, now)) continue;
      if (dueId == null || state.newMessages > _states[dueId]!.newMessages) {
        dueId = id;
      }
    }
    if (dueId == null) return null;
    final chat = _chatById(dueId);
    if (chat == null) {
      // Left, or merged into another chat: nothing to read any more.
      _states.remove(dueId);
      _persistSoon();
      return null;
    }

    _running = true;
    _lastPass = now;
    _passes.add(now);
    final due = _states[dueId]!;
    final counted = due.newMessages;
    _states[dueId] = due.copyWith(lastTried: now);
    var ok = false;
    try {
      ok = await _learn(chat, due);
    } on Object catch (error) {
      debugPrint('weft: memory pass failed: ${error.runtimeType}');
    } finally {
      _running = false;
    }
    if (_disposed) return dueId;
    final state = _states[dueId] ?? const MemoryLearnState();
    _states[dueId] = ok
        ? MemoryLearnState(
            // What arrived while the pass ran is for the next one.
            newMessages: (state.newMessages - counted).clamp(0, 1 << 30),
            lastLearned: now,
            lastTried: now,
          )
        : state;
    _persist();
    // Others may be due too; they wait out the spacing.
    _checkAfter(_spacing);
    return dueId;
  }

  void _checkAfter(Duration wait) {
    _again?.cancel();
    _again = Timer(wait, () => unawaited(check()));
  }

  void _persistSoon() {
    if (_save == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 10), _persist);
  }

  void _persist() {
    _saveTimer?.cancel();
    try {
      _save?.call(Map.unmodifiable(_states));
    } on Object catch (error) {
      debugPrint('weft: memory learner: not saved: ${error.runtimeType}');
    }
  }
}
