import 'dart:async';

import 'backend.dart';
import 'models.dart';

/// Where a login attempt currently stands.
enum BridgeLoginStatus {
  idle,
  running,
  waitingForUser,
  waitingForRemote,
  complete,
  failed,
}

/// Why an attempt stopped or is held, as a value the app words.
///
/// A package has no translations (see `docs/architecture/l10n-pipeline.md`), so
/// what the session knows about a failure leaves it as one of these plus the
/// bridge's own error code, and the screen picks the sentence.
enum BridgeLoginProblem {
  /// The bridge refused or failed; [BridgeLoginSession.errorCode] and
  /// [BridgeLoginSession.error] say how.
  bridge,

  /// A value the user typed was rejected; the step is still open.
  invalidInput,

  /// The other device never confirmed.
  timedOut,

  /// The user (or the screen going away) abandoned the attempt.
  cancelled,

  /// The bridge asked for a step type this build cannot show.
  unsupportedStep,
}

/// Drives one login attempt through a bridge's declarative flow.
///
/// The bridge decides what the steps are; this only sequences them and holds
/// the state the UI renders. That separation is what lets a bridge add a new
/// field, or a whole new flow, without a Weft release.
class BridgeLoginSession {
  BridgeLoginSession({
    required BridgeLoginBackend client,
    required this.flowId,
    this.reloginId,
    this.pollInterval = const Duration(seconds: 2),
    this.maxWait = const Duration(minutes: 10),
  }) : _client = client;

  final BridgeLoginBackend _client;
  final String flowId;

  /// The account being signed in again, when this is a reconnect.
  final String? reloginId;

  /// How long to pause before re-asking a bridge that answered a wait with
  /// exactly what it said last time. A bridgev2 wait is a long poll and never
  /// does that; an older bridge or a stub might, and a tight loop of requests
  /// is the wrong way to find out.
  final Duration pollInterval;

  /// How long to wait for the remote side before giving up altogether.
  ///
  /// The bridge refreshes its own QR codes and gives up on its own schedule;
  /// this is only the backstop for a bridge that never answers, so the screen
  /// cannot spin for ever.
  final Duration maxWait;

  final _controller = StreamController<BridgeLoginSession>.broadcast();

  LoginStep? _step;
  String? _loginId;
  String? _userLoginId;
  BridgeLoginStatus _status = BridgeLoginStatus.idle;
  String? _error;
  String? _errorCode;
  BridgeFailure? _failure;
  BridgeLoginProblem? _problem;
  int _refreshes = 0;
  bool _cancelled = false;

  /// The pause between two polls of a waiting step, as something that can be
  /// interrupted.
  ///
  /// `Future.delayed` cannot be cancelled, so a login abandoned while its QR
  /// code was on screen left a timer running and a suspended loop waiting on
  /// it — which a widget test reports as a pending timer and a phone reports
  /// as a wakeup it did not need.
  Timer? _delay;
  Completer<void>? _wake;

  /// Emits this session whenever anything the UI shows has changed.
  Stream<BridgeLoginSession> get updates => _controller.stream;

  LoginStep? get currentStep => _step;
  BridgeLoginStatus get status => _status;

  /// The bridge's own words about what went wrong, or this package's English
  /// fallback when it had none.
  String? get error => _error;

  /// The bridge's error code (`FI.MAU.WHATSAPP.LOGIN_TIMEOUT`…), when it sent
  /// one — the key the app's friendlier sentences are looked up by.
  String? get errorCode => _errorCode;

  /// A transport failure this package described itself.
  BridgeFailure? get failure => _failure;

  BridgeLoginProblem? get problem => _problem;

  /// How many times the code on screen has been replaced by a fresh one.
  int get refreshes => _refreshes;

  /// The login process id, set once the bridge has started the attempt.
  String? get loginId => _loginId;

  /// The remote account the bridge now holds, set on completion.
  String? get userLoginId => _userLoginId;

  bool get isComplete => _status == BridgeLoginStatus.complete;

  /// Begins the flow and advances to the first step needing attention.
  Future<void> start() async {
    _status = BridgeLoginStatus.running;
    _clearError();
    _emit();

    try {
      final step = await _client.startLogin(flowId, reloginId: reloginId);
      await _apply(step);
    } on BridgeException catch (e) {
      _fail(e);
    }
  }

  /// Submits the values for a [LoginStepType.userInput] step.
  ///
  /// Validates against the bridge's own patterns first, so a mistyped phone
  /// number is caught locally rather than costing a round trip and, on some
  /// networks, a rate-limit penalty.
  Future<void> submitInput(Map<String, String> values) async {
    final step = _step;
    if (step == null || step.type != LoginStepType.userInput) {
      throw StateError('No input step is awaiting submission');
    }

    final invalid = step.fields
        .where((f) => !f.validate(values[f.id] ?? ''))
        .map((f) => f.name)
        .toList();
    if (invalid.isNotEmpty) {
      _error = 'Check these fields: ${invalid.join(', ')}';
      _errorCode = null;
      _failure = null;
      _problem = BridgeLoginProblem.invalidInput;
      _status = BridgeLoginStatus.waitingForUser;
      _emit();
      return;
    }

    _status = BridgeLoginStatus.running;
    _clearError();
    _emit();

    try {
      final next = await _client.submitStep(
        loginId: _loginId ?? '',
        stepId: step.stepId,
        stepType: 'user_input',
        body: {
          for (final field in step.fields)
            if ((values[field.id] ?? '').trim().isNotEmpty || !field.optional)
              field.id: field.clean(values[field.id] ?? ''),
        },
      );
      await _apply(next);
    } on BridgeException catch (e) {
      // A value the bridge rejected with the step still open — the bot chat
      // keeps asking for the same field after "Invalid value" — goes back to
      // the form with the reason, not to a dead end.
      if (e.errorCode == BridgeException.invalidInputCode) {
        _error = e.message;
        _errorCode = e.errorCode;
        _problem = BridgeLoginProblem.invalidInput;
        _status = BridgeLoginStatus.waitingForUser;
        _emit();
        return;
      }
      _fail(e);
    }
  }

  /// Submits harvested cookies for a [LoginStepType.cookies] step.
  Future<void> submitCookies(Map<String, String> cookies) async {
    final step = _step;
    if (step == null || step.type != LoginStepType.cookies) {
      throw StateError('No cookie step is awaiting submission');
    }

    _status = BridgeLoginStatus.running;
    _emit();

    try {
      final next = await _client.submitStep(
        loginId: _loginId ?? '',
        stepId: step.stepId,
        stepType: 'cookies',
        body: cookies,
      );
      await _apply(next);
    } on BridgeException catch (e) {
      _fail(e);
    }
  }

  /// Abandons the attempt. Safe to call at any point.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _stopWaiting();
    if (_status != BridgeLoginStatus.complete) {
      final loginId = _loginId;
      if (loginId != null && _status != BridgeLoginStatus.failed) {
        // Tell the bridge, so the next attempt is not refused as "already in
        // progress". Fire and forget: the user has already left.
        unawaited(_client.cancelLogin(loginId).catchError((_) {}));
      }
      _status = BridgeLoginStatus.failed;
      _problem ??= BridgeLoginProblem.cancelled;
      _error ??= 'Cancelled';
      _emit();
    }
  }

  Future<void> dispose() async {
    _cancelled = true;
    _stopWaiting();
    await _controller.close();
  }

  /// Sleeps for [duration], or until the attempt is abandoned.
  Future<void> _sleep(Duration duration) {
    final wake = Completer<void>();
    _wake = wake;
    _delay = Timer(duration, () {
      _delay = null;
      _wake = null;
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future;
  }

  /// Ends any sleep in progress, releasing the loop waiting on it.
  void _stopWaiting() {
    _delay?.cancel();
    _delay = null;
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Moves to [step], polling on the user's behalf when the bridge is simply
  /// waiting for the remote side.
  Future<void> _apply(LoginStep step) async {
    if (_cancelled) return;
    _step = step;
    _loginId ??= step.loginId;

    switch (step.type) {
      case LoginStepType.complete:
        _userLoginId = step.userLoginId ?? reloginId;
        _status = BridgeLoginStatus.complete;
        _emit();

      case LoginStepType.userInput:
      case LoginStepType.cookies:
        _status = BridgeLoginStatus.waitingForUser;
        _emit();

      case LoginStepType.displayAndWait:
        _status = BridgeLoginStatus.waitingForRemote;
        _emit();
        await _waitUntilAdvanced(step);

      case LoginStepType.unsupported:
        _problem = BridgeLoginProblem.unsupportedStep;
        _error =
            'This bridge asked for a login step Sennit does not understand '
            '("${step.raw['type']}").';
        _status = BridgeLoginStatus.failed;
        _emit();
    }
  }

  /// Waits on a step until the bridge moves on or [maxWait] elapses.
  ///
  /// A loop rather than recursion: a WhatsApp QR refreshes every twenty
  /// seconds for as long as the screen is open, and each refresh used to be
  /// one more frame on the stack.
  Future<void> _waitUntilAdvanced(LoginStep waiting) async {
    final deadline = DateTime.now().add(maxWait);
    var current = waiting;

    while (!_cancelled && DateTime.now().isBefore(deadline)) {
      final LoginStep next;
      try {
        next = await _client.waitForStep(
          loginId: _loginId ?? '',
          stepId: current.stepId,
        );
      } on BridgeException catch (e) {
        // A long poll that outlived the client's patience is not a failure —
        // nothing happened yet. Ask again; a bridgev2 bridge answers a repeat
        // of the same wait with the same pending step.
        if (e.failure == BridgeFailure.timeout) continue;
        if (!_cancelled) _fail(e);
        return;
      }
      if (_cancelled) return;

      final sameStep =
          next.stepId == current.stepId &&
          next.type == LoginStepType.displayAndWait;
      if (!sameStep) return _apply(next);

      if (next.displayData != current.displayData) {
        // A refreshed code: the old one may have expired, so it has to reach
        // the screen now.
        _step = next;
        _refreshes++;
        current = next;
        _emit();
        continue;
      }
      await _sleep(pollInterval);
    }

    if (!_cancelled) {
      _problem = BridgeLoginProblem.timedOut;
      _error = 'The bridge did not respond in time. The code may have expired.';
      _status = BridgeLoginStatus.failed;
      _emit();
    }
  }

  void _clearError() {
    _error = null;
    _errorCode = null;
    _failure = null;
    _problem = null;
  }

  void _fail(BridgeException e) {
    _error = e.message;
    _errorCode = e.errorCode;
    _failure = e.failure;
    _problem = BridgeLoginProblem.bridge;
    _status = BridgeLoginStatus.failed;
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(this);
  }
}
