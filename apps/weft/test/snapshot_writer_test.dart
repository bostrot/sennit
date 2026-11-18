/// What the shared container is told, and — far more often — what it is not.
///
/// `weft_snapshot` already pins what a policy discloses; nothing here re-tests a
/// redaction rule. What is only testable at this layer is the *traffic*: which
/// inbox ticks reach the container, which are suppressed, what a refusal does to
/// the next tick, whether signing out actually removes the file, and how many
/// method calls a change costs. A widget that is redrawn on every read receipt
/// is a home screen re-layout the user pays for in battery, and the diff is the
/// only thing standing between them and it.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/services/snapshot/snapshot_writer.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';
import 'package:weft_store/weft_store.dart';

import 'support/snapshot_fixtures.dart';

/// The channel name three platforms answer on. Spelled out rather than imported
/// because `WeftSnapshotContainer` holds it as a literal too, and the point of
/// these tests is that the two literals agree.
const String _channelName = 'com.bostrot.weft/snapshot';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Both surfaces on, both content flags on: the loudest gate the screen can
  /// produce, and the one most tests want out of the way while they are about
  /// something else.
  const everything = SnapshotSettings(
    widgets: true,
    watch: true,
    includePreviews: true,
    includeSenderNames: true,
  );

  const codec = SnapshotCodec();

  /// The payload as a surface would decode it, rather than as the writer
  /// remembers it. `written` is a convenience; this is the contract.
  InboxSnapshot decoded(SnapshotWrite write) => codec.decode(write.json)!;

  /// [count] chats, most recent first, one unread each.
  List<Chat> inbox(int count) => [
    for (var i = 0; i < count; i++)
      snapshotChat(
        id: '!room_$i:example.org',
        title: 'Chat $i',
        unreadCount: 1,
        lastMessage: snapshotMessage(
          eventId: '\$event_$i',
          body: 'message $i',
          timestamp: snapshotAgo(Duration(minutes: i + 1)),
        ),
      ),
  ];

  group('SnapshotSettings', () {
    late WeftStores stores;

    setUp(() => stores = WeftStores.inMemory());
    tearDown(() => stores.dispose());

    test('is off with nothing disclosed before anyone configures it', () {
      // Every install before this build, and every install after it until
      // somebody opens the screen. The gate that opens when it cannot find its
      // own configuration is not a gate.
      final settings = SnapshotSettings.fromStore(stores.settings);
      expect(settings.anySurface, isFalse);
      expect(settings.policy.enabled, isFalse);
      expect(settings.allows(ChatNetwork.matrix), isFalse);
    });

    test(
      'switching a surface on shows names and messages unless told not to',
      () {
        // The first version wrote anonymous, wordless rows until two further
        // switches were found and flipped — a widget of identical lines.
        final fresh = SnapshotSettings.fromStore(stores.settings);
        expect(fresh.includeSenderNames, isTrue);
        expect(fresh.includePreviews, isTrue);

        fresh.copyWith(widgets: true).writeTo(stores.settings);
        final policy = SnapshotSettings.fromStore(stores.settings).policy;
        expect(policy.includeSenderNames, isTrue);
        expect(policy.includePreviews, isTrue);

        // And a choice to hide them is kept.
        SnapshotSettings.fromStore(
          stores.settings,
        ).copyWith(includeSenderNames: false).writeTo(stores.settings);
        expect(
          SnapshotSettings.fromStore(stores.settings).includeSenderNames,
          isFalse,
        );
      },
    );

    test('round-trips through a real settings store', () {
      const written = SnapshotSettings(
        widgets: true,
        includePreviews: true,
        excludedNetworks: {'signal', 'whatsapp'},
      );
      written.writeTo(stores.settings);

      final read = SnapshotSettings.fromStore(stores.settings);
      expect(read, written);
      expect(read.watch, isFalse);
      expect(read.includeSenderNames, isFalse);
      expect(read.allows(ChatNetwork.matrix), isTrue);
      expect(read.allows(ChatNetwork.signal), isFalse);
    });

    test('a corrupt exclusion list reads as nothing excluded, not a crash', () {
      // The reason the row cap clamps and the reason this survives: a schema-less
      // key/value table is what stands between a settings bug and the writer.
      stores.settings.setBool(WeftSettings.snapshotWidgets, value: true);
      stores.settings.setJson(WeftSettings.snapshotExcludedNetworks, {
        'networks': ['signal', 7, null],
      });

      final read = SnapshotSettings.fromStore(stores.settings);
      expect(read.excludedNetworks, {'signal'});
      expect(read.widgets, isTrue);
    });

    test('either surface alone opens the policy; neither closes it', () {
      expect(const SnapshotSettings(widgets: true).policy.enabled, isTrue);
      expect(const SnapshotSettings(watch: true).policy.enabled, isTrue);
      expect(SnapshotSettings.off.policy.enabled, isFalse);
    });

    test('the content flags travel into the policy unchanged', () {
      // One payload for two surfaces, so the policy is the only thing that
      // decides what a row says — the surface flags decide only who may draw it.
      const settings = SnapshotSettings(
        watch: true,
        includePreviews: true,
        excludedNetworks: {'sms'},
      );
      expect(
        settings.policy,
        const SnapshotPolicy(
          enabled: true,
          includePreviews: true,
          excludedNetworks: {'sms'},
        ),
      );
      expect(settings.policy.maxRows, kDefaultSnapshotRowCap);
    });
  });

  group('the diff', () {
    test('writes the inbox on the first refresh', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(2), now: snapshotNow);

      // One write, not two: the settings arrived before there was an inbox, so
      // there was nothing to publish until the first refresh.
      expect(gateway.writes, hasLength(1));
      final snapshot = decoded(gateway.last);
      expect(snapshot.enabled, isTrue);
      expect(snapshot.rows.map((row) => row.chatId), [
        '!room_0:example.org',
        '!room_1:example.org',
      ]);
      expect(snapshot.totalUnread, 2);
      expect(gateway.last.widgets, isTrue);
      expect(gateway.last.watch, isTrue);
    });

    test('a second refresh with the same inbox writes nothing', () async {
      // The reason this class exists. `watchChats` emits on read receipts,
      // typing and presence; a widget's contents change on almost none of them,
      // and every write is a `WidgetCenter` reload and a home screen re-layout.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);

      await writer.refresh(inbox(2), now: snapshotNow);
      await writer.refresh(
        inbox(2),
        now: snapshotNow.add(const Duration(minutes: 5)),
      );

      expect(gateway.writes, hasLength(1));
    });

    test('a changed unread count is a change', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);

      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh([
        snapshotChat(
          id: '!room_0:example.org',
          title: 'Chat 0',
          unreadCount: 4,
        ),
      ], now: snapshotNow);

      expect(gateway.writes, hasLength(2));
      expect(decoded(gateway.last).totalUnread, 4);
    });

    test('a moved generatedAt alone is not a change', () async {
      // The trap the diff is written around: `generatedAt` differs on every
      // build, so a byte comparison finds every tick different and the diff
      // never fires. Excluded on purpose — and this is the assertion that says
      // so, because the symptom of getting it wrong is invisible in a screenshot.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);

      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh(
        inbox(1),
        now: snapshotNow.add(const Duration(minutes: 90)),
      );

      expect(gateway.writes, hasLength(1));
    });

    test('an unchanged inbox is rewritten at the rewriteAfter boundary', () async {
      // The cost of excluding `generatedAt`, paid back. A payload that is never
      // rewritten crosses `kSnapshotStaleAfter` while the app is running and the
      // counts are correct, and every surface starts saying "open Weft on your
      // phone" at a phone the user is holding.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(
        gateway: gateway,
        rewriteAfter: const Duration(hours: 3),
      );
      await writer.applySettings(everything, now: snapshotNow);

      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh(
        inbox(1),
        now: snapshotNow.add(
          const Duration(hours: 2, minutes: 59, seconds: 59),
        ),
      );
      expect(gateway.writes, hasLength(1));

      await writer.refresh(
        inbox(1),
        now: snapshotNow.add(const Duration(hours: 3)),
      );
      expect(gateway.writes, hasLength(2));
      // And the rewrite restarts the clock rather than leaving the boundary
      // behind, which would make every subsequent tick a write.
      await writer.refresh(
        inbox(1),
        now: snapshotNow.add(const Duration(hours: 3, minutes: 1)),
      );
      expect(gateway.writes, hasLength(2));
    });

    test('rewriteAfter is a quarter of the staleness a surface applies', () {
      // Three refreshes inside `kSnapshotStaleAfter`, so a phone picked up once
      // an afternoon never shows the stale state while it is in the user's hand.
      expect(
        SnapshotWriter(gateway: RecordingSnapshotGateway()).rewriteAfter * 4,
        kSnapshotStaleAfter,
      );
    });

    test('a surface toggle alone forces a write', () async {
      // Nothing in the payload changes when the watch is switched off while the
      // widget stays on — and everything about who may draw it does. The flags
      // are part of the diff key for exactly this.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(1), now: snapshotNow);

      await writer.applySettings(
        everything.copyWith(watch: false),
        now: snapshotNow,
      );

      expect(gateway.writes, hasLength(2));
      expect(gateway.last.widgets, isTrue);
      expect(gateway.last.watch, isFalse);
      // The rows are identical, which is the whole point of the case.
      expect(decoded(gateway.last).rows, decoded(gateway.writes.first).rows);
    });

    test('re-applying the same settings does nothing at all', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(1), now: snapshotNow);

      await writer.applySettings(everything, now: snapshotNow);

      expect(gateway.writes, hasLength(1));
    });

    test(
      'settings arriving before an inbox are recorded, not written',
      () async {
        // Nobody is signed in. Writing here would publish a snapshot of an inbox
        // this process cannot see.
        final gateway = RecordingSnapshotGateway();
        final writer = SnapshotWriter(gateway: gateway);

        await writer.applySettings(everything, now: snapshotNow);

        expect(gateway.writes, isEmpty);
        expect(writer.settings, everything);
      },
    );
  });

  group('the gate', () {
    test('both surfaces off writes the switched-off payload', () async {
      // Written rather than deleted, and that is the decision under test: an
      // absent payload means "signed out" and this one has to mean "switched
      // off in Settings", so the widget can point at the setting instead of
      // showing a sign-in prompt to somebody already signed in.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.refresh(inbox(3), now: snapshotNow);

      expect(gateway.writes, hasLength(1));
      expect(gateway.clears, 0);
      final snapshot = decoded(gateway.last);
      expect(snapshot.enabled, isFalse);
      expect(snapshot.rows, isEmpty);
      expect(snapshot.totalUnread, 0);
      expect(gateway.last.widgets, isFalse);
      expect(gateway.last.watch, isFalse);
    });

    test('switching off replaces the rows with the disabled payload', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(2), now: snapshotNow);
      expect(decoded(gateway.last).rows, hasLength(2));

      await writer.applySettings(SnapshotSettings.off, now: snapshotNow);

      expect(gateway.writes, hasLength(2));
      expect(decoded(gateway.last).enabled, isFalse);
      expect(decoded(gateway.last).rows, isEmpty);
    });

    test('previews off keeps the counts and drops every word', () async {
      // `SnapshotSettings(widgets: true)` on its own discloses how many unread
      // messages there are and nothing else. The assertion is against the whole
      // serialised payload rather than the fields that were cleared, which is
      // what catches a body reaching a surface through some other key later.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(
        const SnapshotSettings(widgets: true),
        now: snapshotNow,
      );
      await writer.refresh([
        snapshotChat(
          title: 'Grace',
          unreadCount: 5,
          avatarUrl: 'mxc://example.org/grace',
          lastMessage: snapshotMessage(body: 'the otter is loose'),
        ),
      ], now: snapshotNow);

      final json = gateway.last.json;
      expect(json, isNot(contains('otter')));
      expect(json, isNot(contains('Grace')));
      expect(json, isNot(contains('mxc://')));
      final snapshot = decoded(gateway.last);
      expect(snapshot.totalUnread, 5);
      // Its network, which its dots already show — never its name.
      expect(snapshot.rows.single.title, 'WhatsApp');
      expect(snapshot.rows.single.unreadCount, 5);
    });

    test('an excluded network drops the chat whole, merged included', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(
        everything.copyWith(excludedNetworks: {'signal'}),
        now: snapshotNow,
      );
      await writer.refresh([
        mergedSnapshotChat(title: 'Grace', unreadCount: 2),
        snapshotChat(
          id: '!wa:example.org',
          title: 'Ines',
          unreadCount: 3,
          lastMessage: snapshotMessage(senderName: 'Ines', body: 'on my way'),
        ),
      ], now: snapshotNow);

      final snapshot = decoded(gateway.last);
      expect(snapshot.rows.map((row) => row.title), ['Ines']);
      // The excluded chat's unread messages are gone from the total too: an
      // excluded network's traffic does not leave the encrypted store in any
      // form, including as a number.
      expect(snapshot.totalUnread, 3);
      expect(gateway.last.json, isNot(contains('Grace')));
    });

    test('the surface flags are not in the payload', () async {
      // `SnapshotCodec` is the only writer of a format two hand-written parsers
      // read. The flags travel beside it — a `SharedPreferences` boolean, a
      // shared `UserDefaults` boolean — precisely so a sixth field never has to
      // be bolted onto that shape from the app layer.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(
        const SnapshotSettings(widgets: true, watch: true),
        now: snapshotNow,
      );
      await writer.refresh(inbox(1), now: snapshotNow);

      expect(gateway.last.json, isNot(contains('widgets')));
      expect(gateway.last.json, isNot(contains('watch')));
    });
  });

  group('sign-out', () {
    test('clear deletes the payload and forgets what was in it', () async {
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(2), now: snapshotNow);

      await writer.clear();

      expect(gateway.clears, 1);
      expect(writer.written, isNull);
      // A deletion, not a switched-off payload: the two are different states on
      // every surface, and only one of them means "nobody is signed in".
      expect(gateway.writes, hasLength(1));
    });

    test(
      'a settings change after a clear does not resurrect the inbox',
      () async {
        // The signed-out phone whose home screen still lists four conversations by
        // name. `_chats` is dropped by `clear`, so there is nothing to publish
        // until somebody signs in and the listener refreshes again.
        final gateway = RecordingSnapshotGateway();
        final writer = SnapshotWriter(gateway: gateway);
        await writer.applySettings(everything, now: snapshotNow);
        await writer.refresh(inbox(2), now: snapshotNow);
        await writer.clear();

        await writer.applySettings(
          everything.copyWith(includePreviews: false),
          now: snapshotNow,
        );

        expect(gateway.writes, hasLength(1));
        expect(gateway.clears, 1);
      },
    );

    test('clearing twice is not an error', () async {
      // Sign-out and soft sign-out both land here, and the session state stream
      // re-emits.
      final gateway = RecordingSnapshotGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.clear();
      await writer.clear();
      expect(gateway.clears, 2);
    });
  });

  group('a container that stored nothing', () {
    test('a refused write is retried on the next tick', () async {
      // False is "I stored nothing", not "I failed" — an unentitled build, a
      // platform with no handler. Remembering what it was asked for would mean
      // never asking again for as long as the app runs.
      final gateway = RecordingSnapshotGateway()..refuse = true;
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);

      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh(inbox(1), now: snapshotNow);
      expect(gateway.writes, hasLength(2));
      expect(writer.written, isNull);

      gateway.refuse = false;
      await writer.refresh(inbox(1), now: snapshotNow);
      expect(gateway.writes, hasLength(3));
      expect(writer.written, isNotNull);
      // And once it has landed, the diff resumes suppressing.
      await writer.refresh(inbox(1), now: snapshotNow);
      expect(gateway.writes, hasLength(3));
    });
  });

  group('overlapping ticks', () {
    test('a tick during a write coalesces rather than queueing', () async {
      // `watchChats` can emit several times inside one channel round trip. What
      // the container wants is the *newest* list written once, not every
      // intermediate list written in turn.
      final gateway = _SlowGateway();
      final writer = SnapshotWriter(gateway: gateway);
      await writer.applySettings(everything, now: snapshotNow);

      final first = writer.refresh(inbox(1), now: snapshotNow);
      final second = writer.refresh(inbox(2), now: snapshotNow);
      final third = writer.refresh(inbox(3), now: snapshotNow);
      gateway.release();
      await Future.wait([first, second, third]);

      // Two writes: the one in flight, and one more for the newest list. Not
      // three.
      expect(gateway.writes, hasLength(2));
      expect(codec.decode(gateway.writes.last.json)!.rows, hasLength(3));
    });
  });

  group('WeftSnapshotContainer', () {
    late _ChannelHarness harness;

    setUp(() => harness = _ChannelHarness());
    tearDown(() => harness.dispose());

    test('one change is exactly one platform call', () async {
      // The brief's "calls the platform reload exactly once per change", against
      // the real container over a mock channel rather than against the fake
      // gateway — because the count that matters is the count of method calls,
      // and everything above this group is one layer short of them.
      final writer = SnapshotWriter(gateway: harness.container);
      await writer.applySettings(everything, now: snapshotNow);
      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh(inbox(1), now: snapshotNow);
      await writer.refresh(inbox(2), now: snapshotNow);
      await writer.clear();

      expect(harness.methods, [
        'writeSnapshot',
        'writeSnapshot',
        'clearSnapshot',
      ]);
    });

    test('the arguments are the three keys both platforms read', () async {
      // Kotlin reads these off a `Map<String, Any?>` and Swift off an
      // `[String: Any]`, with no compiler between either of them and this call.
      await harness.container.writeSnapshot('{}', widgets: true, watch: false);

      expect(harness.calls.single.method, 'writeSnapshot');
      expect(harness.arguments.single, {
        'json': '{}',
        'widgets': true,
        'watch': false,
      });
    });

    test('a platform with no handler is "nothing was stored"', () async {
      // Linux, Windows, and every widget test. The absent handler is the whole
      // fixture: `invokeMethod` on an unhandled channel is a MissingPluginException.
      harness.dispose();
      final container = WeftSnapshotContainer(
        channel: const MethodChannel(_channelName),
      );

      expect(
        await container.writeSnapshot('{}', widgets: true, watch: true),
        isFalse,
      );
      // And the clear survives it too, which is the call sign-out makes on
      // every platform whether or not it has a container.
      await container.clearSnapshot();
    });

    test('a container the build cannot reach is "nothing was stored"', () async {
      // An unsigned CI build, a stale provisioning profile, a missing App Group
      // entitlement. Not worth throwing out of a chat-list listener that runs on
      // every message.
      harness.fail = true;
      expect(
        await harness.container.writeSnapshot('{}', widgets: true, watch: true),
        isFalse,
      );
      await harness.container.clearSnapshot();
    });

    test('a platform that answers null is not a stored write', () async {
      // A handler that returns before it has written — the shape a Kotlin
      // `result.success(null)` takes on the Dart side.
      harness.answer = null;
      expect(
        await harness.container.writeSnapshot('{}', widgets: true, watch: true),
        isFalse,
      );
    });
  });
}

/// The real container over a mock channel, and everything it was told.
class _ChannelHarness {
  _ChannelHarness() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (fail) {
            throw PlatformException(
              code: 'no_container',
              message: 'no App Group entitlement',
            );
          }
          return call.method == 'writeSnapshot' ? answer : null;
        });
  }

  final MethodChannel channel = const MethodChannel(_channelName);
  final List<MethodCall> calls = [];

  late final WeftSnapshotContainer container = WeftSnapshotContainer(
    channel: channel,
  );

  /// What `writeSnapshot` answers. Null is a platform that stored nothing and
  /// did not say so.
  bool? answer = true;

  /// Refuse every call the way an unentitled build does.
  bool fail = false;

  List<String> get methods => [for (final call in calls) call.method];

  List<Map<Object?, Object?>> get arguments => [
    for (final call in calls)
      if (call.arguments case final Map<Object?, Object?> map) map,
  ];

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

/// A container that does not answer until it is told to.
///
/// The only way to have two refreshes genuinely in flight at once: with an
/// `async` gateway that completes on the microtask queue there is no window for
/// the second tick to arrive in.
class _SlowGateway extends RecordingSnapshotGateway {
  final List<Completer<void>> _waiting = [];
  bool _open = false;

  /// Let everything through, now and from here on — the coalescing pass the
  /// writer runs after the first write lands has to be able to complete too.
  void release() {
    _open = true;
    for (final gate in _waiting.toList(growable: false)) {
      gate.complete();
    }
    _waiting.clear();
  }

  @override
  Future<bool> writeSnapshot(
    String json, {
    required bool widgets,
    required bool watch,
  }) async {
    if (!_open) {
      final gate = Completer<void>();
      _waiting.add(gate);
      await gate.future;
    }
    return super.writeSnapshot(json, widgets: widgets, watch: watch);
  }
}
