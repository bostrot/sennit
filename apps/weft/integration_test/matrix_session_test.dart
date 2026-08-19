import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:path/path.dart' as p;
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

/// End-to-end against the local Synapse from `tooling/docker`.
///
///   docker compose -f tooling/docker/compose.yaml up -d --wait
///   ./tooling/docker/seed.sh
///   cd apps/weft && flutter test integration_test/*_test.dart -d macos
///
/// The glob, not the bare directory: `integration_test/patrol/` holds the
/// device suite, and a Patrol test cannot be loaded by `flutter test` — see
/// that directory's README. It runs from `tooling/scripts/e2e.sh`.
///
/// These exercise the parts that cannot be unit tested: a real login, real
/// E2EE key upload, and a real encrypted round trip between two accounts.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const homeserver = String.fromEnvironment(
    'WEFT_HOMESERVER',
    defaultValue: 'localhost:8008',
  );
  const password = String.fromEnvironment(
    'WEFT_TEST_PASSWORD',
    defaultValue: 'weft-test-password',
  );

  /// Every session gets its own database file under a temp directory, removed
  /// when the run ends.
  ///
  /// Deliberately *not* `inMemoryDatabasePath`: sqflite caches open databases
  /// by path, so two sessions asking for `:memory:` in one process are handed
  /// the same database. The second client then restores the first one's stored
  /// session and login fails with "User is already logged in".
  final tempRoot = Directory.systemTemp.createTempSync('weft-it-');
  tearDownAll(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  var sessionCounter = 0;
  WeftMatrixSession newSession(String label) {
    final path = p.join(tempRoot.path, '$label-${sessionCounter++}.sqlite');
    return WeftMatrixSession(
      clientName: 'weft-test-$label',
      deviceDisplayName: 'Weft integration test',
      databaseOverride: () async => sdk.MatrixSdkDatabase.init(
        'weft-test-$label',
        database: await openWeftSqfliteDatabase(path),
      ),
    );
  }

  group('homeserver discovery', () {
    test('resolves the local test server', () async {
      final session = newSession('discovery');
      addTearDown(session.dispose);

      await session.initialize();
      final discovery = await session.checkHomeserver(homeserver);

      expect(
        discovery.baseUrl.scheme,
        'http',
        reason: 'loopback should not be forced to https',
      );
      expect(discovery.baseUrl.port, 8008);
    });

    test('reports the offered login flows', () async {
      final session = newSession('flows');
      addTearDown(session.dispose);

      await session.initialize();
      await session.checkHomeserver(homeserver);

      final flows = await session.supportedLoginFlows();
      expect(flows.map((f) => f.type), contains('m.login.password'));
    });
  });

  group('login', () {
    test('signs in and reaches a usable state', () async {
      final session = newSession('login');
      addTearDown(session.dispose);

      await session.initialize();
      expect(session.state, WeftSessionState.loggedOut);

      await session.checkHomeserver(homeserver);
      await session.loginWithPassword(username: 'alice', password: password);

      expect(session.client.userID, '@alice:localhost');
      expect(
        session.state,
        anyOf(WeftSessionState.ready, WeftSessionState.unverified),
      );
      expect(
        session.encryptionEnabled,
        isTrue,
        reason: 'vodozemac should be available on this platform',
      );
    });

    test('rejects a wrong password with a recognisable error', () async {
      final session = newSession('badlogin');
      addTearDown(session.dispose);

      await session.initialize();
      await session.checkHomeserver(homeserver);

      await expectLater(
        session.loginWithPassword(username: 'alice', password: 'wrong'),
        throwsA(isA<Exception>()),
      );
      expect(session.state, WeftSessionState.loggedOut);
    });
  });

  group('encrypted round trip', () {
    test(
      'alice and bob exchange a message in an encrypted room',
      () async {
        final alice = newSession('alice');
        final bob = newSession('bob');
        addTearDown(alice.dispose);
        addTearDown(bob.dispose);

        await alice.initialize();
        await alice.checkHomeserver(homeserver);
        await alice.loginWithPassword(username: 'alice', password: password);

        await bob.initialize();
        await bob.checkHomeserver(homeserver);
        await bob.loginWithPassword(username: 'bob', password: password);

        final roomId = await alice.client.createRoom(
          invite: ['@bob:localhost'],
          isDirect: true,
          preset: sdk.CreateRoomPreset.trustedPrivateChat,
        );

        final aliceRoom = await _awaitRoom(alice.client, roomId);
        await aliceRoom.enableEncryption();

        await bob.client.joinRoomById(roomId);
        final bobRoom = await _awaitRoom(bob.client, roomId);

        await aliceRoom.sendTextEvent('the watermark holds');

        final timeline = await bobRoom.getTimeline();
        final received = await _awaitMessage(timeline, 'the watermark holds');

        expect(received, isNotNull);
        expect(aliceRoom.encrypted, isTrue);

        // And it maps cleanly onto Weft's domain model.
        final mapped = mapEvent(
          received!,
          network: networkForRoom(bobRoom),
          ownUserId: bob.client.userID,
          timeline: timeline,
        );
        expect(mapped, isNotNull);
        expect(mapped!.body, 'the watermark holds');
        expect(mapped.isOwn, isFalse);
        expect(mapped.network, ChatNetwork.matrix);
        expect(mapped.kind, MessageKind.text);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

/// Waits for a room to appear in the client's room list after sync.
Future<sdk.Room> _awaitRoom(sdk.Client client, String roomId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final room = client.getRoomById(roomId);
    if (room != null) return room;
    await client.oneShotSync();
  }
  throw StateError('Room $roomId never arrived');
}

/// Waits for a decrypted message with [body] to land in [timeline].
Future<sdk.Event?> _awaitMessage(sdk.Timeline timeline, String body) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    for (final event in timeline.events) {
      if (event.type == sdk.EventTypes.Message && event.body == body) {
        return event;
      }
    }
    await timeline.room.client.oneShotSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return null;
}
