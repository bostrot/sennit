import 'dart:async';

import 'package:weft_attachments/weft_attachments.dart';

/// One call to [FakeTransport.upload], held open so the test decides when — and
/// whether — it finishes.
///
/// Every upload stalls by default. A test that wants a success completes it;
/// one that wants a failure completes it with an error; one that is asserting
/// on the concurrency cap simply leaves it hanging, which is exactly the
/// long-running upload the cap exists for.
class FakeUpload {
  FakeUpload({
    required this.uploadId,
    required this.mimeType,
    required this.byteCount,
    required this.onProgress,
  });

  final String uploadId;
  final String mimeType;
  final int byteCount;
  final void Function(int sent, int total)? onProgress;

  final _completer = Completer<String>();

  Future<String> get future => _completer.future;
  bool get isDone => _completer.isCompleted;

  void succeed([String? uri]) =>
      _completer.complete(uri ?? 'mxc://example.org/$uploadId');

  void fail(String message, {bool retryable = true}) =>
      _completer.completeError(
        AttachmentTransportException(message, retryable: retryable),
      );

  /// Throws something the transport never declared, to prove the queue does not
  /// assume every failure is an [AttachmentTransportException].
  void throwRaw(Object error) => _completer.completeError(error);

  void report(int sent, int total) => onProgress?.call(sent, total);
}

/// An [AttachmentTransport] that does nothing until the test tells it to.
class FakeTransport implements AttachmentTransport {
  FakeTransport({this.autoComplete = false});

  /// When true, every upload succeeds on the next microtask. Convenient for the
  /// ordering tests, where what happens on the wire is beside the point.
  final bool autoComplete;

  /// Every call in the order it was made, which is what the FIFO assertions
  /// read.
  final List<FakeUpload> calls = [];

  /// Ids passed to [cancel].
  final List<String> cancelled = [];

  int disposeCount = 0;

  int _live = 0;

  /// The most uploads that were ever in flight at once.
  int peakConcurrency = 0;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake transport';

  List<String> get startOrder => [for (final c in calls) c.uploadId];

  int callsFor(String uploadId) =>
      calls.where((c) => c.uploadId == uploadId).length;

  FakeUpload get last => calls.last;

  @override
  Future<String> upload(
    List<int> bytes, {
    required String mimeType,
    required String uploadId,
    void Function(int sent, int total)? onProgress,
  }) async {
    final call = FakeUpload(
      uploadId: uploadId,
      mimeType: mimeType,
      byteCount: bytes.length,
      onProgress: onProgress,
    );
    calls.add(call);
    _live++;
    if (_live > peakConcurrency) peakConcurrency = _live;
    if (autoComplete) scheduleMicrotask(call.succeed);

    try {
      return await call.future;
    } finally {
      _live--;
    }
  }

  @override
  void cancel(String uploadId) => cancelled.add(uploadId);

  @override
  void dispose() => disposeCount++;
}
