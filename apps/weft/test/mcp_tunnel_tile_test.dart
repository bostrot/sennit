import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/features/settings/mcp_screen.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_mcp/weft_mcp.dart';

/// The Cloudflare tunnel row on a platform that cannot run one.
///
/// A tunnel is a long-lived child process. Android and iOS do not let an app
/// start one and have no user-writable PATH to install a binary onto, so the
/// row's Start button was an offer the OS would always refuse — and the refusal
/// arrived as the supervisor's own English: *"Could not start cloudflared.
/// Install it and make sure it is on PATH."* Two impossible instructions, in a
/// language the reader may not have chosen.
///
/// So there are two assertions worth making, and they are the two here: the
/// control is gone before anybody taps, and the sentence in its place says what
/// the user can actually do instead.
void main() {
  tearDown(() => TunnelPlatform.debugOverride = null);

  Future<void> pump(WidgetTester tester, CloudflaredSupervisor tunnel) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: weftLocalizationsDelegates,
        supportedLocales: weftSupportedLocales,
        theme: WeftTheme.build(),
        home: Scaffold(body: McpTunnelTile(tunnel: tunnel, localPort: 8765)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on a phone there is no start button at all', (tester) async {
    TunnelPlatform.debugOverride = false;
    final tunnel = CloudflaredSupervisor();
    addTearDown(tunnel.dispose);

    await pump(tester, tunnel);

    // Not a disabled button: a greyed-out control still invites the tap, and
    // the row is information here rather than an offer.
    expect(find.widgetWithText(TextButton, 'Start'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Stop'), findsNothing);
  });

  testWidgets('it explains the platform and names the alternative', (
    tester,
  ) async {
    TunnelPlatform.debugOverride = false;
    final tunnel = CloudflaredSupervisor();
    addTearDown(tunnel.dispose);

    await pump(tester, tunnel);

    expect(find.textContaining('Not on a phone'), findsOneWidget);
    // The two ways out, both of which the user can actually take.
    expect(find.textContaining('local network'), findsOneWidget);
    expect(find.textContaining('computer that stays on'), findsOneWidget);
    // And none of the advice that could not be followed.
    expect(find.textContaining('PATH'), findsNothing);
    expect(find.textContaining('Install it'), findsNothing);
  });

  testWidgets('the explanation survives a failed start being requested', (
    tester,
  ) async {
    // Nothing in the UI can reach this — there is no button — but `start` is
    // public and `McpService` calls it when the setting says so. The row must
    // still read as a platform fact rather than as a failure with no message.
    TunnelPlatform.debugOverride = false;
    final tunnel = CloudflaredSupervisor();
    addTearDown(tunnel.dispose);
    await tunnel.start(localPort: 8765);

    await pump(tester, tunnel);

    expect(tunnel.state, TunnelState.failed);
    expect(find.textContaining('Not on a phone'), findsOneWidget);
    expect(find.text('Failed to start'), findsNothing);
  });

  testWidgets('on a desktop the tunnel is offered', (tester) async {
    TunnelPlatform.debugOverride = true;
    final tunnel = CloudflaredSupervisor();
    addTearDown(tunnel.dispose);

    await pump(tester, tunnel);

    expect(find.widgetWithText(TextButton, 'Start'), findsOneWidget);
    expect(find.textContaining('Requires cloudflared'), findsOneWidget);
    expect(find.textContaining('Not on a phone'), findsNothing);
  });

  /// Each failure as the row draws it.
  ///
  /// Reached through `debugFail` rather than by failing a real spawn, because
  /// `testWidgets` runs inside `FakeAsync` and a real `Process.start` there
  /// never completes — the test hangs rather than failing. That the supervisor
  /// sets these reasons for the right causes is `weft_mcp`'s own unit test;
  /// what belongs here is that each one becomes a sentence in the reader's
  /// language, because `weft_mcp` has no ARB files and anything it formatted
  /// itself could only ever be English.
  group('a desktop failure is localized from its typed reason', () {
    testWidgets('a missing binary', (tester) async {
      TunnelPlatform.debugOverride = true;
      final tunnel = CloudflaredSupervisor();
      addTearDown(tunnel.dispose);
      tunnel.debugFail(TunnelFailure.notInstalled);

      await pump(tester, tunnel);

      expect(find.textContaining('is not on this machine'), findsOneWidget);
    });

    testWidgets('an exit, with its code', (tester) async {
      TunnelPlatform.debugOverride = true;
      final tunnel = CloudflaredSupervisor();
      addTearDown(tunnel.dispose);
      tunnel.debugFail(TunnelFailure.exited, exitCode: 7);

      await pump(tester, tunnel);

      // The number is the app's to interpolate. A package that pre-formatted
      // it would be handing over an English sentence with an integer in it.
      expect(find.textContaining('exit 7'), findsOneWidget);
    });

    testWidgets('giving up, which is a different sentence', (tester) async {
      TunnelPlatform.debugOverride = true;
      final tunnel = CloudflaredSupervisor();
      addTearDown(tunnel.dispose);
      tunnel.debugFail(TunnelFailure.gaveUp, exitCode: 1);

      await pump(tester, tunnel);

      expect(find.textContaining('stopped trying'), findsOneWidget);
      expect(find.textContaining('Trying again'), findsNothing);
    });
  });
}
