/// A hybrid logical clock timestamp: wall time, a counter for ties within one
/// millisecond, and the device that made it.
///
/// Wall time alone is not enough to order edits from two devices: a phone
/// whose clock runs a minute fast would win every conflict for a minute after
/// each edit. A hybrid clock never goes backwards on a device and always moves
/// past anything it has seen, so an edit made *after* seeing another one sorts
/// after it whatever the clocks say. The device id breaks exact ties, which is
/// what makes the order total and every device pick the same winner.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.wall, this.counter, this.node);

  /// Parses [toString]'s form. Throws [FormatException] on anything else.
  factory Hlc.parse(String raw) {
    final first = raw.indexOf('-');
    final second = first < 0 ? -1 : raw.indexOf('-', first + 1);
    if (first < 0 || second < 0) throw FormatException('Not an HLC', raw);
    final wall = int.tryParse(raw.substring(0, first), radix: 36);
    final counter = int.tryParse(raw.substring(first + 1, second), radix: 36);
    final node = raw.substring(second + 1);
    if (wall == null || counter == null || node.isEmpty) {
      throw FormatException('Not an HLC', raw);
    }
    return Hlc(wall, counter, node);
  }

  /// Milliseconds since the epoch.
  final int wall;
  final int counter;
  final String node;

  @override
  int compareTo(Hlc other) {
    if (wall != other.wall) return wall.compareTo(other.wall);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return node.compareTo(other.node);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.wall == wall &&
      other.counter == counter &&
      other.node == node;

  @override
  int get hashCode => Object.hash(wall, counter, node);

  /// Fixed-width base 36, so two stamps also sort as strings.
  @override
  String toString() =>
      '${wall.toRadixString(36).padLeft(9, '0')}-'
      '${counter.toRadixString(36).padLeft(4, '0')}-$node';
}

/// Issues [Hlc]s for one device.
class HlcClock {
  HlcClock(this.node, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String node;
  final int Function() _now;
  Hlc? _last;

  /// A stamp later than every stamp this clock issued or saw.
  Hlc tick() {
    final now = _now();
    final last = _last;
    final next = last == null || now > last.wall
        ? Hlc(now, 0, node)
        : Hlc(last.wall, last.counter + 1, node);
    return _last = next;
  }

  /// Moves past [remote], so the next [tick] sorts after it.
  void receive(Hlc remote) {
    final last = _last;
    if (last == null || remote.wall > last.wall) {
      _last = Hlc(remote.wall, remote.counter, node);
    } else if (remote.wall == last.wall && remote.counter > last.counter) {
      _last = Hlc(last.wall, remote.counter, node);
    }
  }
}
