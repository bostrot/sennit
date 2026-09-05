import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// State of the tunnel process.
enum TunnelState { stopped, starting, running, failed }

/// Why a tunnel is not running, as a value the app turns into a sentence.
///
/// A value rather than the English string this used to carry. `weft_mcp` has no
/// ARB files and never will — the rule for the whole workspace is that a
/// package answers in values and the app supplies the words — and the sentence
/// it carried was worse than untranslated: *"Could not start cloudflared.
/// Install it and make sure it is on PATH"* was shown on Android, where no
/// amount of installing will produce a PATH a Flutter app may exec from.
enum TunnelFailure {
  /// This platform cannot run a `cloudflared` process at all.
  ///
  /// Android and iOS both forbid an app from executing a binary it did not ship
  /// inside its own sandbox, and neither has a user-writable PATH. This is not
  /// a missing install and cannot become one; the tunnel belongs on a machine
  /// that stays on.
  unsupportedPlatform,

  /// No `cloudflared` on PATH. A desktop-only answer, and a fixable one.
  notInstalled,

  /// The process started and exited. Restartable — see [CloudflaredSupervisor].
  exited,

  /// It kept exiting. Stopped trying rather than hammering Cloudflare.
  gaveUp,
}

/// Whether a `cloudflared` child process is possible on this platform.
///
/// A capability getter rather than a `Platform.isAndroid` at the call site, the
/// same shape `NotificationPlatform.supportsPush` uses in the app: the question
/// has one answer and several askers — the supervisor refusing to start, the
/// settings screen deciding whether to draw a button — and two of them
/// disagreeing is how a control appears for something that cannot happen.
///
/// [debugOverride] exists because the branch that matters is unreachable
/// otherwise: these tests run on a laptop, and the platform being gated out is
/// a phone.
abstract final class TunnelPlatform {
  @visibleForTesting
  static bool? debugOverride;

  /// False on Android and iOS. True on every desktop, and on anything else —
  /// an unknown platform that can spawn a process is a platform where the
  /// honest failure is "cloudflared is not installed", which is recoverable.
  static bool get supportsProcess =>
      debugOverride ?? !(Platform.isAndroid || Platform.isIOS);
}

/// Supervises a `cloudflared` process that exposes the local MCP server.
///
/// Cloudflare terminates TLS and hands the request to the local port, so the
/// tunnel provides transport encryption and a stable public hostname — but no
/// authentication. Authorisation is entirely Weft's API keys, which is why
/// [WeftToolRegistry] refuses unauthenticated calls regardless of how they
/// arrived. Cloudflare Access can be layered on top for a second factor.
class CloudflaredSupervisor {
  CloudflaredSupervisor({
    this.executable = 'cloudflared',
    this.restartDelay = const Duration(seconds: 5),
    this.maxRestarts = 5,
  });

  final String executable;

  /// How long to wait before restarting after an unexpected exit.
  final Duration restartDelay;

  /// Give up after this many consecutive failures, rather than hammering
  /// Cloudflare and filling the log forever.
  final int maxRestarts;

  Process? _process;
  TunnelState _state = TunnelState.stopped;
  String? _publicUrl;
  TunnelFailure? _failure;
  int? _lastExitCode;
  int _restarts = 0;
  bool _stopRequested = false;

  final _stateController = StreamController<TunnelState>.broadcast();
  final _logController = StreamController<String>.broadcast();

  TunnelState get state => _state;

  /// Public hostname, once cloudflared reports one.
  String? get publicUrl => _publicUrl;

  /// Why the tunnel is not running, or null when nothing has gone wrong.
  ///
  /// [TunnelFailure.unsupportedPlatform] is set before any attempt is made, so
  /// it is readable on a phone without ever having tapped anything.
  TunnelFailure? get failure => _failure;

  /// The exit code behind a [TunnelFailure.exited] or [TunnelFailure.gaveUp].
  ///
  /// A number rather than part of a sentence: the app interpolates it into a
  /// translated one, and a package that pre-formatted it would be handing over
  /// English with an integer in it.
  int? get lastExitCode => _lastExitCode;

  /// Whether this build can run a tunnel at all. See [TunnelPlatform].
  bool get isSupportedPlatform => TunnelPlatform.supportsProcess;

  /// Puts the supervisor into a failed state without a process behind it.
  ///
  /// For the widget tests over the tunnel row, which have to render each
  /// failure and cannot produce one: `testWidgets` runs its body inside
  /// `FakeAsync`, where a real `Process.start` never completes and the test
  /// simply hangs. The states this reaches are otherwise only reachable by
  /// failing to spawn a binary, which is the one thing that environment cannot
  /// do.
  @visibleForTesting
  void debugFail(TunnelFailure reason, {int? exitCode}) {
    _failure = reason;
    _lastExitCode = exitCode;
    _setState(TunnelState.failed);
  }

  Stream<TunnelState> get states => _stateController.stream;

  /// Raw cloudflared output, for the diagnostics panel.
  Stream<String> get logs => _logController.stream;

  /// Whether cloudflared is installed and runnable.
  ///
  /// Checked before offering the toggle: a switch that silently does nothing
  /// because a binary is missing is worse than one that explains itself.
  ///
  /// False without asking on Android and iOS. `Process.run` there does not
  /// merely fail to find the binary — there is nowhere for one to be — and
  /// spending a process spawn to learn that on every screen build is a cost
  /// for an answer that cannot change.
  Future<bool> isAvailable() async {
    if (!isSupportedPlatform) return false;
    try {
      final result = await Process.run(executable, ['--version']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Starts a tunnel to [localPort].
  ///
  /// With a [token] this runs a named tunnel from the user's Cloudflare
  /// account, which keeps a stable hostname across restarts. Without one it
  /// falls back to a quick tunnel — a throwaway `*.trycloudflare.com` address
  /// that changes every run and is only useful for trying it out.
  /// Refuses outright on Android and iOS.
  ///
  /// Before the state machine, before any process work, and without a retry:
  /// there is no `cloudflared` to find on a phone and no PATH to put one on, so
  /// every downstream behaviour this class has — the restart backoff, the log
  /// stream, "install it" — is answering a question that cannot be asked there.
  /// The failure is recorded so a caller that started it anyway can say why
  /// nothing happened.
  Future<void> start({required int localPort, String? token}) async {
    if (!isSupportedPlatform) {
      _failure = TunnelFailure.unsupportedPlatform;
      _lastExitCode = null;
      _setState(TunnelState.failed);
      return;
    }
    if (_state == TunnelState.running || _state == TunnelState.starting) return;

    _stopRequested = false;
    _failure = null;
    _lastExitCode = null;
    _setState(TunnelState.starting);

    final args = token != null && token.isNotEmpty
        ? ['tunnel', '--no-autoupdate', 'run', '--token', token]
        : ['tunnel', '--no-autoupdate', '--url', 'http://127.0.0.1:$localPort'];

    try {
      final process = await Process.start(executable, args);
      _process = process;

      // cloudflared writes its banner, including the assigned hostname, to
      // stderr rather than stdout.
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLogLine);

      unawaited(
        process.exitCode.then((code) => _onExit(code, localPort, token)),
      );

      // A named tunnel never prints a URL, so it is running as soon as the
      // process is up; a quick tunnel flips to running when the URL appears.
      if (token != null && token.isNotEmpty) _setState(TunnelState.running);
    } on ProcessException {
      // The message is deliberately dropped rather than surfaced. It is the
      // OS's, in the OS's language, and what the user needs is the one sentence
      // the app can translate: cloudflared is not on this machine.
      _failure = TunnelFailure.notInstalled;
      _setState(TunnelState.failed);
    }
  }

  Future<void> stop() async {
    _stopRequested = true;
    _process?.kill();
    _process = null;
    _publicUrl = null;
    _restarts = 0;
    // A tunnel that was stopped is not a tunnel that failed. Leaving the
    // reason behind would put "cloudflared is not installed" under a row the
    // user just switched off.
    _failure = null;
    _lastExitCode = null;
    _setState(TunnelState.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
    await _logController.close();
  }

  void _onLogLine(String line) {
    if (!_logController.isClosed) _logController.add(line);

    final url = extractTunnelUrl(line);
    if (url != null) {
      _publicUrl = url;
      _restarts = 0;
      _setState(TunnelState.running);
    }
  }

  Future<void> _onExit(int code, int localPort, String? token) async {
    _process = null;
    if (_stopRequested) return;

    _failure = TunnelFailure.exited;
    _lastExitCode = code;

    if (_restarts >= maxRestarts) {
      _failure = TunnelFailure.gaveUp;
      _setState(TunnelState.failed);
      return;
    }

    _restarts++;
    _setState(TunnelState.starting);
    await Future<void>.delayed(restartDelay);
    if (!_stopRequested) await start(localPort: localPort, token: token);
  }

  void _setState(TunnelState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }
}

/// Pulls a `trycloudflare.com` hostname out of a cloudflared log line.
///
/// The banner is a decorated box drawn with `|` and `+` characters, so the URL
/// has to be extracted rather than parsed from a known position.
String? extractTunnelUrl(String line) {
  final match = RegExp(
    r'https://[a-z0-9-]+\.trycloudflare\.com',
  ).firstMatch(line);
  return match?.group(0);
}
