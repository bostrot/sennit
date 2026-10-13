import 'dart:collection';

import 'package:weft_domain/weft_domain.dart';

/// Runs lookups a few at a time instead of all at once.
///
/// The inbox asks for a profile per conversation whose member event was never
/// loaded, and on an account with a couple of thousand bridged chats that is a
/// couple of thousand requests issued from one rebuild: every socket the
/// platform will open, every response decoded on the UI thread in the same few
/// frames, and — on a phone — enough memory held at once to get the process
/// killed under the user's finger. A lane keeps the count in flight to [width]
/// and leaves the rest waiting their turn.
///
/// Order is first come, first served.
class LookupLane {
  LookupLane({this.width = 8}) : assert(width > 0, 'a lane needs room for one');

  /// How many lookups may be in flight together.
  final int width;

  final Queue<Future<void> Function()> _waiting = Queue();
  int _running = 0;
  bool _closed = false;

  /// Lookups in flight right now. Never more than [width].
  int get running => _running;

  /// Lookups accepted and not yet started.
  int get waiting => _waiting.length;

  /// Queues [task]. It starts immediately when the lane has room.
  ///
  /// A task that throws frees its place like one that returns: a lookup is
  /// allowed to fail, and one that did must not narrow the lane for the rest
  /// of the session.
  void add(Future<void> Function() task) {
    if (_closed) return;
    _waiting.add(task);
    _pump();
  }

  /// Drops everything still waiting. Lookups already in flight finish.
  void close() {
    _closed = true;
    _waiting.clear();
  }

  void _pump() {
    while (_running < width && _waiting.isNotEmpty) {
      final task = _waiting.removeFirst();
      _running++;
      // Deliberately not awaited: the loop fills the lane, it does not walk it.
      () async {
        try {
          await task();
        } on Object {
          // The task's own business. See [add].
        } finally {
          _running--;
          _pump();
        }
      }();
    }
  }
}

/// What a previous run already learned about a peer, for a room that has not
/// said anything about them yet.
///
/// The identity store keeps every handle's name and picture, and the graph is
/// rehydrated from it before the first rebuild — so on any launch after the
/// first, the answer to "what is this person called" is usually already in
/// memory. Reading it here is what lets a cold start title and draw a
/// conversation without a request per contact.
///
/// [fallbackName] is the name the room would make up for a member it knows
/// nothing about (the localpart, prettified). A stored name equal to it is not
/// something a previous run *learned*, only that same guess written down, and
/// it is reported as no name at all so the caller keeps its own, better
/// fallback and still asks the server.
({String? displayName, String? avatarUrl}) rememberedProfile(
  NetworkHandle? known, {
  required String fallbackName,
}) {
  if (known == null) return (displayName: null, avatarUrl: null);
  final name = known.displayName?.trim() ?? '';
  return (
    displayName: name.isEmpty || name == fallbackName ? null : name,
    avatarUrl: known.avatarUrl,
  );
}
