import 'sdp.dart';

/// Holds ICE candidates that arrive before there is anywhere to put them.
///
/// Candidates routinely beat the description they belong to. The caller starts
/// trickling the moment gathering begins, so on a fast homeserver
/// `m.call.candidates` can land before `m.call.answer` has been processed; and
/// on this side, local candidates are gathered before the invite has been sent
/// and cannot go out until the far end knows the call exists. Both directions
/// need the same queue, and this is it.
///
/// Dropping early candidates does not break a call outright — it removes the
/// host and server-reflexive candidates and leaves whatever arrives later,
/// which on the same Wi-Fi still connects. That is exactly why it is worth a
/// class: the bug it causes is "calls work at home and never anywhere else",
/// which is indistinguishable from a missing TURN server and is diagnosed months
/// late.
class IceCandidateBuffer {
  IceCandidateBuffer({this.capacity = 256});

  /// The most candidates to hold before refusing more.
  ///
  /// A real call gathers a handful; several hundred means a peer is misbehaving
  /// or a buffer is never being flushed, and unbounded growth in a long-lived
  /// call service is a leak rather than a resilience.
  final int capacity;

  final List<IceCandidate> _pending = [];
  bool _open = true;
  int _dropped = 0;

  /// Whether the buffer still accepts candidates. Closed buffers discard.
  bool get isOpen => _open;

  bool get isEmpty => _pending.isEmpty;

  bool get isNotEmpty => _pending.isNotEmpty;

  int get length => _pending.length;

  /// How many candidates have been thrown away since construction, whether
  /// because the buffer was closed or full. Non-zero is worth logging: it is
  /// the only visible symptom of the failure mode above.
  int get droppedCount => _dropped;

  /// The queued candidates, oldest first, without consuming them.
  List<IceCandidate> get pending => List.unmodifiable(_pending);

  /// Queue one candidate. Returns false if it was discarded.
  ///
  /// An exact duplicate is discarded rather than queued — peers resend
  /// candidates after a reconnect, and adding the same one twice is at best
  /// wasted work and at worst an error from the platform's ICE agent — but it
  /// does not count as a drop, because nothing was lost.
  bool add(IceCandidate candidate) {
    if (!_open) {
      _dropped++;
      return false;
    }
    if (_pending.contains(candidate)) return false;
    if (_pending.length >= capacity) {
      _dropped++;
      return false;
    }
    _pending.add(candidate);
    return true;
  }

  /// Queue several, preserving order. Returns how many were accepted.
  int addAll(Iterable<IceCandidate> candidates) {
    var accepted = 0;
    for (final candidate in candidates) {
      if (add(candidate)) accepted++;
    }
    return accepted;
  }

  /// Take everything queued, in arrival order, and empty the buffer.
  ///
  /// Order is the contract. ICE is not order-sensitive in principle, but host
  /// candidates arriving before relay ones is what lets a connection come up on
  /// the LAN in milliseconds instead of waiting on TURN, and reordering a flush
  /// silently gives that up.
  List<IceCandidate> flush() {
    if (_pending.isEmpty) return const [];
    final flushed = List<IceCandidate>.unmodifiable(_pending);
    _pending.clear();
    return flushed;
  }

  /// Discard everything queued without returning it, and refuse any more.
  ///
  /// Called on hangup. A candidate that arrives after the call ended has no
  /// peer connection to go into, and feeding one to a disposed engine is a
  /// crash on at least one platform.
  void close() {
    _dropped += _pending.length;
    _pending.clear();
    _open = false;
  }

  /// Empty the buffer and accept again.
  ///
  /// Used when one call replaces another — glare — and the queue belongs to the
  /// call that lost.
  void reopen() {
    _pending.clear();
    _open = true;
  }

  @override
  String toString() =>
      'IceCandidateBuffer(${_pending.length}/$capacity'
      '${_open ? '' : ', closed'}'
      '${_dropped > 0 ? ', dropped $_dropped' : ''})';
}
