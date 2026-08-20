import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Recently displayed attachment bytes, in memory.
///
/// `ListView.builder` disposes a row the moment it leaves the viewport, and
/// the media bubble's state — including its downloaded, *decrypted* bytes —
/// goes with it. Without this cache, scrolling up and back down re-downloaded
/// and re-decrypted every photo it passed, which is exactly the scroll jank it
/// felt like: each returning image was a network round trip, a decryption,
/// and a full-size decode, all mid-gesture.
///
/// Keyed by event, bounded by count and bytes; oldest-touched evicts first.
/// Encrypted content stays where it already was — process memory — so this
/// changes locality, not exposure.
class AttachmentByteCache {
  AttachmentByteCache({this.maxEntries = 64, this.maxBytes = 48 << 20});

  final int maxEntries;
  final int maxBytes;

  // A literal `{}` types as Map, but insertion order is the eviction policy
  // here, so the LinkedHashMap is named — with the lint quieted rather than
  // obeyed, since obeying it would hide the one property this class runs on.
  // ignore: prefer_collection_literals
  final _entries = LinkedHashMap<String, Uint8List>();
  int _totalBytes = 0;

  static String keyFor(String roomId, String eventId) => '$roomId/$eventId';

  Uint8List? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit; // Re-insert: most-recently-used moves to the end.
    return hit;
  }

  void put(String key, Uint8List bytes) {
    // A single value larger than the whole budget would evict everything and
    // still not fit; it is cheaper to just not cache it.
    if (bytes.length > maxBytes) return;
    final existing = _entries.remove(key);
    if (existing != null) _totalBytes -= existing.length;

    _entries[key] = bytes;
    _totalBytes += bytes.length;

    while (_entries.length > maxEntries || _totalBytes > maxBytes) {
      final oldest = _entries.keys.first;
      _totalBytes -= _entries.remove(oldest)!.length;
    }
  }

  void clear() {
    _entries.clear();
    _totalBytes = 0;
  }
}

final attachmentByteCacheProvider = Provider<AttachmentByteCache>((ref) {
  final cache = AttachmentByteCache();
  ref.onDispose(cache.clear);
  return cache;
});
