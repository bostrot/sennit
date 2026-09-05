import 'package:test/test.dart';
import 'package:weft_mcp/weft_mcp.dart';

/// The tunnel supervisor's platform gate, and the failures it reports.
///
/// The bug this covers was not a crash. On Android the tunnel row offered a
/// Start button, tapping it produced `TunnelState.failed`, and the sentence
/// under it — the supervisor's own English — read *"Could not start
/// cloudflared. Install it and make sure it is on PATH."* Both halves of that
/// are impossible on a phone: an app may not exec a binary it did not ship in
/// its own sandbox, and there is no user-writable PATH to install one onto. The
/// advice could not be followed by anyone who read it.
///
/// So the gate is asserted from both directions — that a mobile build refuses
/// before spawning anything, and that a desktop build still reaches the real
/// failure it can do something about.
void main() {
  tearDown(() => TunnelPlatform.debugOverride = null);

  group('the platform gate', () {
    test('a phone is not a place a tunnel can run', () {
      TunnelPlatform.debugOverride = false;
      expect(CloudflaredSupervisor().isSupportedPlatform, isFalse);
    });

    test('a desktop is', () {
      TunnelPlatform.debugOverride = true;
      expect(CloudflaredSupervisor().isSupportedPlatform, isTrue);
    });

    test('start refuses and reports the typed reason', () async {
      TunnelPlatform.debugOverride = false;
      final tunnel = CloudflaredSupervisor();
      addTearDown(tunnel.dispose);

      await tunnel.start(localPort: 8765);

      expect(tunnel.state, TunnelState.failed);
      expect(tunnel.failure, TunnelFailure.unsupportedPlatform);
      // Not "not installed": there is nothing to install, and the two lead to
      // opposite sentences — one tells the user to go and get a binary.
      expect(tunnel.failure, isNot(TunnelFailure.notInstalled));
      expect(tunnel.publicUrl, isNull);
    });

    test('it does not spawn a process to find out', () async {
      // The executable name is deliberately one no machine has. A supervisor
      // that reached `Process.start` would come back with `notInstalled` —
      // which is the answer this gate exists to stop being given on a phone.
      TunnelPlatform.debugOverride = false;
      final tunnel = CloudflaredSupervisor(
        executable: 'weft-nonexistent-binary',
      );
      addTearDown(tunnel.dispose);

      await tunnel.start(localPort: 8765);

      expect(tunnel.failure, TunnelFailure.unsupportedPlatform);
    });

    test('isAvailable answers false without asking the OS', () async {
      TunnelPlatform.debugOverride = false;
      final tunnel = CloudflaredSupervisor(executable: 'echo');
      addTearDown(tunnel.dispose);

      // `echo` exists and exits 0 everywhere this test runs, so a true answer
      // here would mean the gate was skipped and the OS consulted.
      expect(await tunnel.isAvailable(), isFalse);
    });

    test('a state change is emitted, so a listening screen redraws', () async {
      TunnelPlatform.debugOverride = false;
      final tunnel = CloudflaredSupervisor();
      addTearDown(tunnel.dispose);

      final seen = <TunnelState>[];
      final subscription = tunnel.states.listen(seen.add);
      await tunnel.start(localPort: 8765);
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(seen, [TunnelState.failed]);
    });
  });

  group('on a platform that can run one', () {
    setUp(() => TunnelPlatform.debugOverride = true);

    test(
      'a missing binary is reported as missing, not as unsupported',
      () async {
        final tunnel = CloudflaredSupervisor(
          executable: 'weft-nonexistent-binary',
        );
        addTearDown(tunnel.dispose);

        await tunnel.start(localPort: 8765);

        expect(tunnel.state, TunnelState.failed);
        // Recoverable, and the sentence the app draws for it says how. Losing
        // this distinction is what made the mobile message wrong in the first
        // place.
        expect(tunnel.failure, TunnelFailure.notInstalled);
      },
    );

    test(
      'stopping clears the reason rather than leaving it under an off row',
      () async {
        final tunnel = CloudflaredSupervisor(
          executable: 'weft-nonexistent-binary',
        );
        addTearDown(tunnel.dispose);

        await tunnel.start(localPort: 8765);
        expect(tunnel.failure, isNotNull);

        await tunnel.stop();

        expect(tunnel.state, TunnelState.stopped);
        expect(tunnel.failure, isNull);
        expect(tunnel.lastExitCode, isNull);
      },
    );
  });

  group('the URL in a banner line', () {
    test('is found among the box-drawing characters around it', () {
      expect(
        extractTunnelUrl('|  https://calm-river-1234.trycloudflare.com    |'),
        'https://calm-river-1234.trycloudflare.com',
      );
    });

    test('an ordinary log line has none', () {
      expect(extractTunnelUrl('INF Starting tunnel tunnelID=abc'), isNull);
    });
  });
}
