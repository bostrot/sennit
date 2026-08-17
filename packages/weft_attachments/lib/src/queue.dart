import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'plan.dart';

/// How many uploads run at once by default.
///
/// Two, and deliberately small — see the [UploadQueue] doc comment.
const int kDefaultMaxConcurrentUploads = 2;

/// Attempts, not retries: a task is tried at most this many times in total.
const int kMaxUploadAttempts = 3;

/// Wait before the second attempt. Each further attempt waits four times as
/// long, giving 1s, 4s, 16s.
const Duration kUploadBackoffBase = Duration(seconds: 1);

/// How long to wait before attempt number [attempt] + 1.
///
/// Quadrupling rather than doubling because the thing being backed off is a
/// homeserver that is probably one machine in someone's cupboard: 1s, 4s, 16s
/// gives it a real chance to finish whatever it was doing, where 1s, 2s, 4s
/// mostly just retries into the same overload.
///
/// At the default [kMaxUploadAttempts] of 3 only the first two delays are ever
/// waited; the third is what a raised cap would use.
Duration defaultUploadBackoff(int attempt) {
  // Clamped so a caller that raises the cap cannot overflow the shift.
  final n = attempt < 1
      ? 0
      : attempt > 8
      ? 7
      : attempt - 1;
  return kUploadBackoffBase * (1 << (2 * n));
}

/// Waits [duration]. Injected so tests exercise the backoff schedule without
/// spending twenty real seconds on it.
typedef UploadDelay = Future<void> Function(Duration duration);

/// How long to wait before the attempt following [attempt].
typedef UploadBackoff = Duration Function(int attempt);

/// Produces the bytes to upload, on demand.
typedef UploadPayloadLoader = Future<UploadPayload> Function();

/// Thrown by an [AttachmentTransport] when an upload fails in a way worth
/// showing the user.
class AttachmentTransportException implements Exception {
  const AttachmentTransportException(
    this.message, {
    this.statusCode,
    this.retryable = true,
  });

  /// Plain language, already user-facing — it lands in [UploadTask.failure]
  /// and from there on a timeline bubble.
  final String message;

  final int? statusCode;

  /// Whether trying again could plausibly work.
  ///
  /// A 5xx, a timeout or a dropped connection is retryable; a file the server
  /// has refused (413, 403) is not, and retrying it three times just makes the
  /// user wait 5 seconds longer for the same answer. Defaults to true because
  /// most of what goes wrong on a home connection is transient — a transport
  /// has to say so explicitly to spend the retries.
  final bool retryable;

  @override
  String toString() => 'AttachmentTransportException: $message';
}

/// Puts bytes on a homeserver and returns an mxc URI.
///
/// A bare interface with no `package:http` and no `dart:io` behind it, which is
/// the whole reason the queue's retry and cancellation rules can be tested in
/// milliseconds against a fake. The real implementation lands in Phase 02 and
/// wraps the Matrix SDK's upload.
abstract class AttachmentTransport {
  /// Stable identifier, recorded with each upload.
  String get id;

  /// Human-facing name for settings and error messages.
  String get displayName;

  /// Uploads [bytes] and returns the `mxc://` URI the homeserver assigned.
  ///
  /// [bytes] are already ciphertext for an encrypted room — encryption happens
  /// in the payload loader, before this is ever called, so a transport never
  /// sees plaintext it has no business seeing.
  ///
  /// [uploadId] is the [UploadTask.id] and is the handle [cancel] takes.
  ///
  /// [onProgress] is called with bytes sent so far and the total. A transport
  /// that cannot report progress simply never calls it; the task then sits at
  /// 0.0 until it completes, which renders as an indeterminate bar rather than
  /// a wrong one.
  ///
  /// Throws [AttachmentTransportException] on failure.
  Future<String> upload(
    List<int> bytes, {
    required String mimeType,
    required String uploadId,
    void Function(int sent, int total)? onProgress,
  });

  /// Abandons the in-flight upload with this [uploadId], if there is one.
  ///
  /// Best-effort and empty by default so implementations opt in: the queue
  /// marks the task cancelled either way, because a socket that keeps running
  /// after the user has changed their mind wastes their upstream but does not
  /// make the state wrong.
  void cancel(String uploadId) {}

  void dispose() {}
}

/// The bytes for one upload, plus the key material they were encrypted with.
///
/// Produced lazily, per attempt, rather than held in the queue: a share of
/// twenty photos would otherwise pin every one of them in memory from the
/// moment it is enqueued until the moment it is sent.
@immutable
class UploadPayload {
  const UploadPayload({required this.bytes, this.file});

  /// What goes on the wire — ciphertext for an encrypted room, the file itself
  /// for a plain one.
  final List<int> bytes;

  /// Key material for an encrypted room, null for a plain one.
  ///
  /// It arrives with the bytes because it is produced by the same step: the
  /// `sha256` in it is the hash of exactly these bytes, and pairing them
  /// anywhere else invites a mismatch nobody can debug from a timeline.
  final EncryptedFileInfo? file;

  @override
  String toString() =>
      'UploadPayload(${bytes.length} bytes${file == null ? '' : ', encrypted'})';
}

/// Where one upload currently stands.
enum UploadState {
  /// Waiting for a concurrency slot.
  queued,

  /// Reading, encrypting and hashing the file — everything between picking the
  /// task up and having bytes to send.
  hashing,

  /// On the wire.
  uploading,

  /// Failed, and waiting out a backoff before trying again.
  retrying,

  /// The homeserver has the bytes and returned a URI.
  sent,

  /// Out of attempts, or refused outright. Terminal but recoverable — the task
  /// stays in the queue with its plan, so [UploadQueue.retry] can revive it.
  failed,

  /// The user changed their mind.
  cancelled;

  /// Whether nothing further will happen without a new instruction.
  bool get isTerminal =>
      this == UploadState.sent ||
      this == UploadState.failed ||
      this == UploadState.cancelled;

  /// Whether this is occupying one of the queue's concurrency slots.
  ///
  /// [retrying] is not: a task waiting out a 16-second backoff hands its slot
  /// back so the rest of the share keeps moving, and reclaims one when the
  /// backoff ends.
  bool get isActive =>
      this == UploadState.hashing || this == UploadState.uploading;
}

/// One attachment's journey through the queue, as a value.
///
/// Immutable so a snapshot the UI is mid-build against cannot change underneath
/// it: every transition replaces the task rather than mutating it, and the
/// stream carries whole new lists.
@immutable
class UploadTask {
  const UploadTask({
    required this.id,
    required this.roomId,
    required this.plan,
    this.state = UploadState.queued,
    this.progress = 0,
    this.attempts = 0,
    this.failure,
    this.uri,
    this.file,
  });

  /// Unique within one queue, and the handle [UploadQueue.cancel],
  /// [UploadQueue.retry] and [AttachmentTransport.cancel] all take.
  final String id;

  /// Which chat this is being sent to. Uploads start in the order they were
  /// enqueued, so this is what makes "these twenty photos arrive in the order I
  /// picked them" meaningful.
  final String roomId;

  /// The full decision from `planUpload`, kept for the life of the task —
  /// including through [UploadState.failed], which is what lets the UI offer a
  /// retry rather than making the user pick the file again.
  final UploadPlan plan;

  final UploadState state;

  /// 0.0 to 1.0. Stays at 0 for a transport that cannot report progress.
  final double progress;

  /// How many attempts have been started, including the current one.
  final int attempts;

  /// Why this failed, in language fit to show the user. Null unless [state] is
  /// [UploadState.failed].
  final String? failure;

  /// The mxc URI, once the homeserver has returned one.
  final String? uri;

  /// Key material for an encrypted attachment, once the payload has been
  /// produced. Feeds `UploadPlan.toEventContent(uri: ..., file: ...)`.
  final EncryptedFileInfo? file;

  /// Whether nothing further will happen without a new instruction.
  bool get isTerminal => state.isTerminal;

  /// Whether the UI should offer a retry.
  bool get canRetry =>
      state == UploadState.failed || state == UploadState.cancelled;

  /// A new task with the given fields replaced.
  ///
  /// Cannot clear [failure], [uri] or [file] — a null argument means "leave it
  /// alone", as everywhere else in the workspace. Requeueing builds a fresh
  /// task instead, which is also the honest description of what it is.
  UploadTask copyWith({
    UploadState? state,
    double? progress,
    int? attempts,
    String? failure,
    String? uri,
    EncryptedFileInfo? file,
  }) {
    return UploadTask(
      id: id,
      roomId: roomId,
      plan: plan,
      state: state ?? this.state,
      progress: progress ?? this.progress,
      attempts: attempts ?? this.attempts,
      failure: failure ?? this.failure,
      uri: uri ?? this.uri,
      file: file ?? this.file,
    );
  }

  /// Equality covers the id and everything that changes under it. The plan is
  /// fixed for the life of an id, so leaving it out costs nothing and spares
  /// `UploadPlan` an equality it has no other use for.
  @override
  bool operator ==(Object other) =>
      other is UploadTask &&
      other.id == id &&
      other.roomId == roomId &&
      other.state == state &&
      other.progress == progress &&
      other.attempts == attempts &&
      other.failure == failure &&
      other.uri == uri;

  @override
  int get hashCode =>
      Object.hash(id, roomId, state, progress, attempts, failure, uri);

  @override
  String toString() =>
      'UploadTask($id, ${plan.filename}, ${state.name}, '
      '${(progress * 100).round()}%, attempt $attempts)';
}

/// Runs attachment uploads a few at a time, in order, retrying the ones worth
/// retrying.
///
/// **Concurrency is bounded, and that is the point of the class.** Weft talks
/// to homeservers people run themselves — a Synapse on a NAS behind a domestic
/// upstream. Sharing twenty photos from the system picker would, unbounded,
/// open twenty sockets and push twenty multipart bodies into a link that can
/// carry perhaps two of them at a time: every upload then crawls, progress bars
/// move in lockstep at a fifth of their real speed, the first photo lands no
/// sooner than the last, and a homeserver with a worker limit starts returning
/// 429s that look to the user like failures. Two at a time saturates a typical
/// upstream, lets the first photos appear in the room while the rest are still
/// going, and keeps the retry budget for problems that are actually the
/// network's fault.
///
/// Ordering: tasks *start* in the order they were enqueued, so within a chat
/// the first photo picked is the first uploaded. Completion order is the
/// transport's business and is not promised — sending the events in order is
/// the sender's job in Phase 02, not the uploader's.
///
/// The transport is injected and not owned: [dispose] closes this queue's own
/// stream and leaves the transport alone, because the caller that built it may
/// well be sharing it with the download path.
class UploadQueue {
  UploadQueue({
    required AttachmentTransport transport,
    this.maxConcurrent = kDefaultMaxConcurrentUploads,
    this.maxAttempts = kMaxUploadAttempts,
    UploadBackoff backoff = defaultUploadBackoff,
    UploadDelay? delay,
  }) : _transport = transport,
       _backoff = backoff,
       _delay = delay ?? _wait;

  final AttachmentTransport _transport;

  /// How many uploads may be in flight at once. See the class doc for why this
  /// is small.
  final int maxConcurrent;

  /// Attempts per task, in total rather than in addition to the first.
  final int maxAttempts;

  final UploadBackoff _backoff;
  final UploadDelay _delay;

  final _controller = StreamController<List<UploadTask>>.broadcast();

  /// Insertion-ordered, which is what makes dequeueing FIFO by construction.
  final List<UploadTask> _tasks = [];

  /// Ids with a `_run` loop attached. A task can be [UploadState.cancelled]
  /// while its loop is still unwinding, and reviving it before then would leave
  /// two loops driving one task.
  final Set<String> _running = {};

  /// The byte source for each task, kept beside the task rather than inside it
  /// so [UploadTask] stays a value the UI can hold and compare.
  final Map<String, UploadPayloadLoader> _loaders = {};

  int _nextId = 0;
  bool _disposed = false;

  /// Every task the queue knows about, in enqueue order, including terminal
  /// ones. Terminal tasks stay until [remove] or [clearFinished] takes them.
  List<UploadTask> get tasks => List.unmodifiable(_tasks);

  /// A fresh snapshot on every transition, so the UI renders progress without
  /// polling.
  ///
  /// Broadcast and lossless in the sense that matters: a subscriber that joins
  /// late reads [tasks] for the current state and then follows this.
  Stream<List<UploadTask>> get updates => _controller.stream;

  /// Tasks for one chat, in enqueue order.
  List<UploadTask> tasksFor(String roomId) =>
      List.unmodifiable(_tasks.where((t) => t.roomId == roomId));

  /// The task with this id, or null once it has been removed.
  UploadTask? task(String id) {
    final index = _indexOf(id);
    return index < 0 ? null : _tasks[index];
  }

  /// Queues [plan] for [roomId] and returns the task tracking it.
  ///
  /// [loadPayload] is called once per attempt, immediately before the upload,
  /// and is where reading the file, encrypting it and hashing the ciphertext
  /// belong — all the work that must not happen twenty times over at enqueue
  /// time. It runs in [UploadState.hashing]; anything it throws is treated as a
  /// failed attempt.
  ///
  /// [id] is for callers that already have a local echo to correlate with;
  /// otherwise the queue assigns one.
  UploadTask enqueue(
    UploadPlan plan, {
    required String roomId,
    required UploadPayloadLoader loadPayload,
    String? id,
  }) {
    if (_disposed) {
      throw StateError('This UploadQueue has been disposed');
    }
    final taskId = id ?? 'upload-${++_nextId}';
    if (_indexOf(taskId) >= 0) {
      throw ArgumentError.value(taskId, 'id', 'Already in this queue');
    }

    _loaders[taskId] = loadPayload;
    final task = UploadTask(id: taskId, roomId: roomId, plan: plan);
    _tasks.add(task);
    _emit();
    _pump();
    return task;
  }

  /// Stops [taskId], whether it is waiting, hashing, uploading or backing off.
  ///
  /// Returns false when there is no such task or it has already finished.
  /// Cancelling something already on the wire is best-effort at the transport
  /// but immediate here: the state is [UploadState.cancelled] from this call
  /// onwards and a late success is discarded rather than resurrecting it.
  bool cancel(String taskId) {
    final index = _indexOf(taskId);
    if (index < 0 || _tasks[index].isTerminal) return false;

    _tasks[index] = _tasks[index].copyWith(state: UploadState.cancelled);
    _emit();
    _transport.cancel(taskId);
    _pump();
    return true;
  }

  /// Puts a failed or cancelled task back at the position it already holds,
  /// with a fresh attempt budget.
  ///
  /// Returns false if there is no such task, if it is not in a state that can
  /// be retried, or if its previous run has not finished unwinding yet.
  bool retry(String taskId) {
    final index = _indexOf(taskId);
    if (index < 0 || !_tasks[index].canRetry) return false;
    if (_running.contains(taskId)) return false;
    if (!_loaders.containsKey(taskId)) return false;

    final previous = _tasks[index];
    _tasks[index] = UploadTask(
      id: previous.id,
      roomId: previous.roomId,
      plan: previous.plan,
    );
    _emit();
    _pump();
    return true;
  }

  /// Forgets a finished task. Returns false for one that has not finished —
  /// the UI dismisses a failed upload, it does not yank one off the wire.
  ///
  /// A cancelled task can still have a socket unwinding behind it; that is no
  /// reason to keep showing it. The run loop tolerates its task disappearing.
  bool remove(String taskId) {
    final index = _indexOf(taskId);
    if (index < 0 || !_tasks[index].isTerminal) return false;

    _tasks.removeAt(index);
    _loaders.remove(taskId);
    _emit();
    return true;
  }

  /// Forgets every sent and cancelled task, keeping failures — those are the
  /// ones the user still has a decision to make about.
  void clearFinished() {
    final before = _tasks.length;
    _tasks.removeWhere(
      (t) => t.state == UploadState.sent || t.state == UploadState.cancelled,
    );
    if (_tasks.length != before) {
      _loaders.removeWhere((id, _) => _indexOf(id) < 0);
      _emit();
    }
  }

  /// Cancels everything outstanding and closes [updates].
  ///
  /// Does not dispose the transport: it was injected, so whoever built it owns
  /// its lifetime.
  Future<void> dispose() async {
    _disposed = true;
    for (final task in List<UploadTask>.of(_tasks)) {
      if (!task.isTerminal) cancel(task.id);
    }
    _loaders.clear();
    await _controller.close();
  }

  /// Starts as many queued tasks as there are free slots, oldest first.
  void _pump() {
    if (_disposed) return;
    while (_activeCount < maxConcurrent) {
      final next = _tasks.firstWhereOrNull(
        (t) => t.state == UploadState.queued && !_running.contains(t.id),
      );
      if (next == null) return;
      _running.add(next.id);
      unawaited(_run(next.id));
    }
  }

  int get _activeCount => _tasks.where((t) => t.state.isActive).length;

  /// Runs one attempt at [taskId], to a terminal state or to a scheduled retry.
  ///
  /// Exactly one attempt: a retry goes back through [UploadState.queued] and
  /// [_pump] rather than looping here, which is what frees the slot for the
  /// duration of the backoff.
  Future<void> _run(String taskId) async {
    try {
      final current = task(taskId);
      if (current == null || current.state != UploadState.queued) return;

      final attempt = current.attempts + 1;
      _update(
        taskId,
        (t) => t.copyWith(
          state: UploadState.hashing,
          attempts: attempt,
          progress: 0,
        ),
      );

      try {
        final loader = _loaders[taskId];
        if (loader == null) {
          throw const AttachmentTransportException(
            'This upload is no longer available.',
            retryable: false,
          );
        }

        final payload = await loader();
        if (_isCancelled(taskId)) return;

        _update(
          taskId,
          (t) => t.copyWith(state: UploadState.uploading, file: payload.file),
        );

        final uri = await _transport.upload(
          payload.bytes,
          mimeType: current.plan.mimeType,
          uploadId: taskId,
          onProgress: (sent, total) => _reportProgress(taskId, sent, total),
        );
        if (_isCancelled(taskId)) return;

        _update(
          taskId,
          (t) => t.copyWith(
            state: UploadState.sent,
            progress: 1,
            uri: uri,
            file: payload.file,
          ),
        );
      } on Object catch (error) {
        if (_isCancelled(taskId)) return;

        final retryable = error is AttachmentTransportException
            ? error.retryable
            // Anything else came from the payload loader, or from a transport
            // that threw something undeclared. Transient until proven
            // otherwise: most of what goes wrong on a home connection recovers.
            : true;
        final message = error is AttachmentTransportException
            ? error.message
            : '$error';

        if (!retryable || attempt >= maxAttempts) {
          _update(
            taskId,
            (t) => t.copyWith(state: UploadState.failed, failure: message),
          );
          return;
        }

        _update(taskId, (t) => t.copyWith(state: UploadState.retrying));
        unawaited(_scheduleRetry(taskId, attempt));
      }
    } finally {
      _running.remove(taskId);
      // The slot this task held is free now, whichever way it went.
      _pump();
    }
  }

  /// Waits out the backoff, then puts the task back in the run queue.
  ///
  /// Deliberately not awaited inside [_run]: a task waiting 16 seconds must not
  /// hold one of two slots while nineteen other photos sit behind it. It keeps
  /// its position in [_tasks], so when it does come back it is still the oldest
  /// thing waiting and goes first.
  Future<void> _scheduleRetry(String taskId, int attempt) async {
    await _delay(_backoff(attempt));
    if (_disposed) return;
    // Cancelled, removed, or retried by hand while the backoff was running.
    if (task(taskId)?.state != UploadState.retrying) return;

    _update(taskId, (t) => t.copyWith(state: UploadState.queued));
    _pump();
  }

  void _reportProgress(String taskId, int sent, int total) {
    final current = task(taskId);
    if (current == null || current.state != UploadState.uploading) return;

    // A transport that reports a zero total tells us nothing; leaving progress
    // where it is renders as an indeterminate bar rather than a wrong one.
    if (total <= 0) return;
    final value = sent <= 0
        ? 0.0
        : sent >= total
        ? 1.0
        : sent / total;

    // Every byte would otherwise be a rebuild of the whole list. A percentage
    // point is the finest granularity a progress bar can show.
    if ((value - current.progress).abs() < _progressEpsilon && value < 1) {
      return;
    }
    _update(taskId, (t) => t.copyWith(progress: value));
  }

  bool _isCancelled(String taskId) {
    final current = task(taskId);
    return current == null || current.state == UploadState.cancelled;
  }

  /// Applies [change] and emits, unless the task has been cancelled or removed
  /// under us — a cancelled task is not dragged back out of its state by work
  /// that was already in flight when the user pressed the button.
  void _update(String taskId, UploadTask Function(UploadTask) change) {
    final index = _indexOf(taskId);
    if (index < 0 || _tasks[index].state == UploadState.cancelled) return;
    _tasks[index] = change(_tasks[index]);
    _emit();
  }

  int _indexOf(String taskId) => _tasks.indexWhere((t) => t.id == taskId);

  void _emit() {
    if (!_controller.isClosed) _controller.add(List.unmodifiable(_tasks));
  }
}

/// Finest progress change worth a rebuild: one percentage point.
const double _progressEpsilon = 0.01;

Future<void> _wait(Duration duration) => Future<void>.delayed(duration);
