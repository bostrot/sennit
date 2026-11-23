import 'dart:async';

import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft/data/auto_reply_transport.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';
import 'package:weft/services/ai/person_memory.dart' show AiMemory;

/// A transport that remembers what it was asked to send — and, crucially, what
/// it was *not*.
///
/// It implements [AutoReplyTransport] and nothing else, which is the assertion
/// as much as the fields below are: there is no `markRead` on this interface to
/// call, so a service written against it cannot mark a conversation read even
/// by mistake. The unread bookkeeping it models is the one the real repository
/// does — capture before, restore after — so a test can check the badge is
/// still standing without a homeserver.
class FakeAutoReplyTransport implements AutoReplyTransport {
  FakeAutoReplyTransport({this.failWith});

  /// Thrown instead of sending, for the transport-refused path.
  final Object? failWith;

  final List<({String chatId, String body})> sent = [];

  /// Unread counts before any auto-reply, by chat id. The fake leaves them
  /// exactly as it found them, which is what the real one promises.
  final Map<String, int> unread = {};

  /// Read receipts written. Always empty; asserted, never appended to.
  final List<String> receipts = const [];

  var _nextEvent = 0;

  @override
  Future<String?> sendAutoReply(
    String chatId,
    String body, {
    ChatNetwork? via,
  }) async {
    if (failWith != null) throw failWith!;
    sent.add((chatId: chatId, body: body));
    // Deliberately does not touch `unread`. The whole point.
    return '\$auto-${_nextEvent++}';
  }
}

/// A model that answers instantly with whatever it was told to.
///
/// [script] is for a model that changes its mind between calls: each call
/// takes the next entry — a failure, or null for [reply] — and once it runs
/// out every call answers as [failWith] says.
class FakeComposer {
  FakeComposer({
    this.reply = 'I am away until Monday.',
    this.failWith,
    List<AutoReplyOutcome?> script = const [],
  }) : _script = [...script];

  final String reply;
  final AutoReplyOutcome? failWith;
  final List<AutoReplyOutcome?> _script;

  final List<({String instruction, List<String> transcript})> calls = [];

  /// The calendar section each call was given, in call order.
  final List<String?> calendars = [];

  /// The person's note each call was given, in call order.
  final List<AiMemory?> memories = [];

  Future<AutoReplyDraft> call({
    required String baseUrl,
    required String model,
    String? apiKey,
    required String instruction,
    required String chatTitle,
    required List<String> transcript,
    String? calendar,
    AiMemory? memory,
  }) async {
    calls.add((instruction: instruction, transcript: transcript));
    calendars.add(calendar);
    memories.add(memory);
    final failure = _script.isNotEmpty ? _script.removeAt(0) : failWith;
    if (failure != null) return AutoReplyDraft.failed(failure);
    return AutoReplyDraft.written(reply);
  }
}

/// An [AutoReplyService] wired to fakes, with everything defaulted to the
/// uninteresting answer so a test states only the fact it is about.
({
  AutoReplyService service,
  StreamController<WeftMessage> incoming,
  FakeAutoReplyTransport transport,
  FakeComposer composer,
  List<AutoReplyAttempt> attempts,
})
buildAutoReplyService({
  required Chat chat,
  List<AutoReplyRule>? rules,
  Set<String> labels = const {},
  bool isServiceChat = false,
  bool isBroadcast = false,
  AutoReplyEndpoint? endpoint = const AutoReplyEndpoint(
    baseUrl: 'http://localhost:11434/v1',
    model: 'llama3',
  ),
  FakeComposer? composer,
  FakeAutoReplyTransport? transport,
  AutoReplyLedger? ledger,
  DateTime? now,
  Future<String?> Function(List<String> transcript)? calendar,
  AiMemory? Function(Chat chat, List<WeftMessage> recent)? memory,
}) {
  // Closed by the caller through the returned record — every test that takes
  // one registers an `addTearDown`. Not closed here, because the service is
  // still listening to it when this returns.
  // ignore: close_sinks
  final incoming = StreamController<WeftMessage>.broadcast();
  final fakeTransport = transport ?? FakeAutoReplyTransport();
  final fakeComposer = composer ?? FakeComposer();
  final attempts = <AutoReplyAttempt>[];

  final service = AutoReplyService(
    incoming: incoming.stream,
    transport: fakeTransport,
    chatForRoom: (roomId) =>
        chat.roomIds.contains(roomId) || roomId == chat.id ? chat : null,
    rules: () => rules ?? const [],
    labelsOf: (_) => labels,
    isServiceChat: (_) => isServiceChat,
    isBroadcast: (_) => isBroadcast,
    ownUserIds: () => const {'@ada:example.org'},
    endpoint: () => endpoint,
    onAttempt: attempts.add,
    composer: fakeComposer.call,
    ledger: ledger,
    now: now == null ? null : () => now,
    calendar: calendar,
    memory: memory,
  );

  return (
    service: service,
    incoming: incoming,
    transport: fakeTransport,
    composer: fakeComposer,
    attempts: attempts,
  );
}
