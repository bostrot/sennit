import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// State of the tunnel process.
enum TunnelState { stopped, starting, running, failed }

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
  String? _lastError;
  int _restarts = 0;
  bool _stopRequested = false;

  final _stateController = StreamController<TunnelState>.broadcast();
  final _logController = StreamController<String>.broadcast();

  TunnelState get state => _state;

  /// Public hostname, once cloudflared reports one.
  String? get publicUrl => _publicUrl;

  String? get lastError => _lastError;

  Stream<TunnelState> get states => _stateController.stream;

  /// Raw cloudflared output, for the diagnostics panel.
  Stream<String> get logs => _logController.stream;

  /// Whether cloudflared is installed and runnable.
  ///
  /// Checked before offering the toggle: a switch that silently does nothing
  /// because a binary is missing is worse than one that explains itself.
  Future<bool> isAvailable() async {
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
  Future<void> start({required int localPort, String? token}) async {
    if (_state == TunnelState.running || _state == TunnelState.starting) return;

    _stopRequested = false;
    _lastError = null;
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
    } on ProcessException catch (e) {
      _lastError =
          'Could not start cloudflared: ${e.message}. Install it and make sure '
          'it is on PATH.';
      _setState(TunnelState.failed);
    }
  }

  Future<void> stop() async {
    _stopRequested = true;
    _process?.kill();
    _process = null;
    _publicUrl = null;
    _restarts = 0;
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

    _lastError = 'cloudflared exited with code $code';

    if (_restarts >= maxRestarts) {
      _lastError =
          'cloudflared kept failing (exit $code). Giving up after $maxRestarts '
          'attempts.';
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
