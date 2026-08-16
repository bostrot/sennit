import 'dart:async';

import 'models.dart';
import 'provisioning_client.dart';

/// Where a login attempt currently stands.
enum BridgeLoginStatus {
  idle,
  running,
  waitingForUser,
  waitingForRemote,
  complete,
  failed,
}

/// Drives one login attempt through a bridge's declarative flow.
///
/// The bridge decides what the steps are; this only sequences them and holds
/// the state the UI renders. That separation is what lets a bridge add a new
/// field, or a whole new flow, without a Weft release.
class BridgeLoginSession {
  BridgeLoginSession({
    required BridgeProvisioningClient client,
    required this.flowId,
    this.pollInterval = const Duration(seconds: 2),
    this.maxWait = const Duration(minutes: 3),
  }) : _client = client;

  final BridgeProvisioningClient _client;
  final String flowId;

  /// How often a `display_and_wait` step is re-polled.
  final Duration pollInterval;

  /// How long to wait for the remote side before giving up. QR codes expire,
  /// and waiting forever on a dead code looks like a hang.
  final Duration maxWait;

  final _controller = StreamController<BridgeLoginSession>.broadcast();

  LoginStep? _step;
  String? _loginId;
  BridgeLoginStatus _status = BridgeLoginStatus.idle;
  String? _error;
  bool _cancelled = false;

  /// Emits this session whenever anything the UI shows has changed.
  Stream<BridgeLoginSession> get updates => _controller.stream;

  LoginStep? get currentStep => _step;
  BridgeLoginStatus get status => _status;
  String? get error => _error;

  /// Set once the bridge accepts the login.
  String? get loginId => _loginId;

  bool get isComplete => _status == BridgeLoginStatus.complete;

  /// Begins the flow and advances to the first step needing attention.
  Future<void> start() async {
    _status = BridgeLoginStatus.running;
    _error = null;
    _emit();

    try {
      final step = await _client.startLogin(flowId);
      await _apply(step);
    } on BridgeException catch (e) {
      _fail(e.message);
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
      _status = BridgeLoginStatus.waitingForUser;
      _emit();
      return;
    }

    _status = BridgeLoginStatus.running;
    _error = null;
    _emit();

    try {
      final next = await _client.submitStep(
        loginId: _loginId ?? '',
        stepId: step.stepId,
        stepType: 'user_input',
        body: values,
      );
      await _apply(next);
    } on BridgeException catch (e) {
      _fail(e.message);
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
      _fail(e.message);
    }
  }

  /// Abandons the attempt. Safe to call at any point.
  void cancel() {
    _cancelled = true;
    if (_status != BridgeLoginStatus.complete) {
      _status = BridgeLoginStatus.failed;
      _error ??= 'Cancelled';
      _emit();
    }
  }

  Future<void> dispose() async {
    _cancelled = true;
    await _controller.close();
  }

  /// Moves to [step], polling on the user's behalf when the bridge is simply
  /// waiting for the remote side.
  Future<void> _apply(LoginStep step) async {
    _step = step;
    _loginId ??= step.loginId;

    switch (step.type) {
      case LoginStepType.complete:
        _loginId = step.loginId ?? _loginId;
        _status = BridgeLoginStatus.complete;
        _emit();

      case LoginStepType.userInput:
      case LoginStepType.cookies:
        _status = BridgeLoginStatus.waitingForUser;
        _emit();

      case LoginStepType.displayAndWait:
        _status = BridgeLoginStatus.waitingForRemote;
        _emit();
        await _pollUntilAdvanced(step);

      case LoginStepType.unsupported:
        _fail(
          'This bridge asked for a login step Weft does not understand '
          '("${step.raw['type']}"). Update Weft, or use the bridge\'s admin room.',
        );
    }
  }

  /// Re-polls a waiting step until the bridge moves on or [maxWait] elapses.
  Future<void> _pollUntilAdvanced(LoginStep waiting) async {
    final deadline = DateTime.now().add(maxWait);

    while (!_cancelled && DateTime.now().isBefore(deadline)) {
      try {
        final next = await _client.waitForStep(
          loginId: _loginId ?? '',
          stepId: waiting.stepId,
        );

        // The bridge returns the same step while nothing has happened.
        if (next.stepId == waiting.stepId &&
            next.type == LoginStepType.displayAndWait) {
          // A refreshed QR payload still matters: the old code may have expired.
          if (next.displayData != waiting.displayData) {
            _step = next;
            _emit();
            return _pollUntilAdvanced(next);
          }
          await Future<void>.delayed(pollInterval);
          continue;
        }

        return _apply(next);
      } on BridgeException catch (e) {
        _fail(e.message);
        return;
      }
    }

    if (!_cancelled) {
      _fail('The bridge did not respond in time. The code may have expired.');
    }
  }

  void _fail(String message) {
    _error = message;
    _status = BridgeLoginStatus.failed;
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(this);
  }
}
