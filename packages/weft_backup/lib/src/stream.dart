/// The two ends of an archive, narrow enough that a test needs no disk.
///
/// `dart:io` would do for production and does nothing for a test that wants to
/// assert on a bit-flip at byte 4 097. So both directions are one small
/// interface with a file implementation and an in-memory one, and every test in
/// this package runs against bytes it built itself.
///
/// [ArchiveSink.add] and [ArchiveInput.read] are async on purpose. A synchronous
/// write is a promise that the bytes went somewhere, which for a 4 GB export is
/// a promise to hold 4 GB — the awaits are the backpressure.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Somewhere an archive's bytes go.
abstract interface class ArchiveSink {
  /// Appends [bytes]. Completes when they have been handed on.
  Future<void> add(List<int> bytes);

  /// Flushes and releases. Called exactly once, including after a failure.
  Future<void> close();
}

/// Somewhere an archive's bytes come from.
abstract interface class ArchiveInput {
  /// Up to [count] bytes.
  ///
  /// A short read means end of file and is not an error here — the reader above
  /// decides whether a short read is a truncated archive or a clean end, and it
  /// is the only thing that knows which.
  Future<Uint8List> read(int count);

  /// Releases the underlying handle. Called exactly once.
  Future<void> close();
}

/// An [ArchiveSink] that keeps everything in memory.
class BytesArchiveSink implements ArchiveSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  /// Everything written so far.
  Uint8List get bytes => _builder.toBytes();

  int get length => _builder.length;

  @override
  Future<void> add(List<int> bytes) async => _builder.add(bytes);

  @override
  Future<void> close() async {}
}

/// An [ArchiveInput] over a byte list.
class BytesArchiveInput implements ArchiveInput {
  BytesArchiveInput(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  @override
  Future<Uint8List> read(int count) async {
    final end = (_offset + count).clamp(0, _bytes.length);
    final out = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return out;
  }

  @override
  Future<void> close() async {}
}

/// An [ArchiveSink] over a file.
class FileArchiveSink implements ArchiveSink {
  FileArchiveSink(this._file);

  static Future<FileArchiveSink> open(File file) async {
    await file.parent.create(recursive: true);
    return FileArchiveSink(await file.open(mode: FileMode.write));
  }

  final RandomAccessFile _file;
  bool _closed = false;

  @override
  Future<void> add(List<int> bytes) => _file.writeFrom(bytes);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.flush();
    await _file.close();
  }
}

/// An [ArchiveInput] over a file.
class FileArchiveInput implements ArchiveInput {
  FileArchiveInput(this._file);

  static Future<FileArchiveInput> open(File file) async =>
      FileArchiveInput(await file.open());

  final RandomAccessFile _file;
  bool _closed = false;

  @override
  Future<Uint8List> read(int count) => _file.read(count);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.close();
  }
}

/// Reads exactly [count] bytes, or fewer at end of file.
///
/// [ArchiveInput.read] is allowed to return a short read for any reason — a
/// `RandomAccessFile` on a network volume routinely does — so every caller that
/// wants a fixed-size field would otherwise need this loop. Getting it wrong
/// looks like a corrupt archive on exactly the files that are fine, which is
/// the worst failure this package could have.
Future<Uint8List> readExactly(ArchiveInput input, int count) async {
  if (count == 0) return Uint8List(0);

  final first = await input.read(count);
  if (first.length >= count) return first;
  if (first.isEmpty) return first;

  final out = BytesBuilder(copy: false)..add(first);
  while (out.length < count) {
    final next = await input.read(count - out.length);
    if (next.isEmpty) break;
    out.add(next);
  }
  return out.toBytes();
}
