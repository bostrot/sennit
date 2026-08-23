import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/notification_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/features/settings/notifications_screen.dart';
import 'package:weft/services/notifications/notification_service.dart';
import 'package:weft/services/notifications/push_registration.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

import 'support/notification_fixtures.dart';

/// The screen is the only place a [NotificationPolicy] is *written* by a human,
/// so what these tests pin is the round trip rather than the pixels: a control
/// moves, the policy the notification path reads changes, and the blob in the
/// real [SettingsStore] changes with it. A test that asserted only on
/// `notificationPolicyProvider` would pass just as happily against a screen
/// that never persisted anything.
void main() {
  final now = DateTime.utc(2026, 8, 18, 12);

  /// The app around [home], with a real store to persist into, a fake
  /// repository, and the two providers that would otherwise go looking for a
  /// homeserver.
  Widget appWith(
    WeftStores stores,
    ChatRepository repository, {
    required Widget home,
    PushRegistrationOutcome push = const PushRegistrationOutcome(
      PushRegistrationStatus.noToken,
    ),
    RecordingNotificationSink? sink,
  }) => ProviderScope(
    overrides: [
      storesProvider.overrideWithValue(stores),
      chatRepositoryProvider.overrideWithValue(repository),
      pushRegistrationProvider.overrideWith((ref) async => push),
      // Without a sink: desktop, or a build with no Firebase config. Nothing to
      // post through, which is the state the button has to survive. With one:
      // the real service over the real pipeline, so pressing the button
      // exercises the chain it exists to prove rather than a stub of it.
      notificationServiceProvider.overrideWith((ref) async {
        if (sink == null) return null;
        final session = FakeNotificationSession();
        final pipeline = MatrixNotificationPipeline(
          session: session,
          chatForRoom: (_) => null,
          policy: () => ref.read(notificationPolicyProvider),
        );
        final service = WeftNotificationService(sink: sink, pipeline: pipeline);
        ref.onDispose(() {
          unawaited(service.dispose());
          unawaited(pipeline.dispose());
          unawaited(session.close());
        });
        await service.start();
        return service;
      }),
    ],
    child: MaterialApp(
      theme: WeftTheme.build(),
      // 24-hour time throughout, so the rendered window is "22:00" rather than
      // a locale's "10:00 PM" and the time picker takes a 24-hour entry.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
      home: home,
    ),
  );

  /// Pumps the screen over a real in-memory store, and hands back the store so
  /// a test can read what was actually written to disk.
  ///
  /// The surface is made tall enough for the whole screen because it is a
  /// `ListView`: at the default 800×600 everything below quiet hours is never
  /// built, and a finder that cannot see a control is indistinguishable from a
  /// control that is not there.
  Future<({WeftStores stores, ProviderContainer container})> pump(
    WidgetTester tester, {
    List<Chat> chats = const [],
    List<ChatNetwork> networks = const [
      ChatNetwork.whatsapp,
      ChatNetwork.signal,
    ],
    _FakeChatRepository? repository,
    NotificationPolicy? policy,
    PushRegistrationOutcome push = const PushRegistrationOutcome(
      PushRegistrationStatus.noToken,
    ),
    RecordingNotificationSink? sink,
  }) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    if (policy != null) {
      stores.settings.setJson(WeftSettings.notifyPolicy, policy.toJson());
    }

    await tester.pumpWidget(
      appWith(
        stores,
        repository ?? _FakeChatRepository(chats: chats, networks: networks),
        home: const NotificationsScreen(),
        push: push,
        sink: sink,
      ),
    );
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(NotificationsScreen));
    return (
      stores: stores,
      container: ProviderScope.containerOf(element, listen: false),
    );
  }

  /// The policy as it would be rebuilt from storage on the next launch — not
  /// the one held in memory. This is the assertion that matters: a background
  /// isolate has only the blob.
  NotificationPolicy persisted(WeftStores stores) =>
      NotificationPolicy.fromJson(
        stores.settings.getJson(WeftSettings.notifyPolicy),
      );

  testWidgets('opens and closes without throwing', (tester) async {
    // The regression `bridges_screen_test` guards, on a screen that also
    // writes a provider from its first post-frame callback.
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);

    await tester.pumpWidget(
      appWith(
        stores,
        _FakeChatRepository(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NotificationsScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsWidgets);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the master switch persists, and hides what it disables', (
    tester,
  ) async {
    final (:stores, :container) = await pump(tester);

    // By label, not position: the built-in-connection switch sits above the
    // master switch on Android.
    await tester.tap(find.widgetWithText(SwitchListTile, 'Notifications'));
    await tester.pumpAndSettle();

    expect(container.read(notificationPolicyProvider).enabled, isFalse);
    expect(persisted(stores).enabled, isFalse);
    // Nothing below the master switch applies while it is off, so nothing
    // below it is shown — a "quiet hours" row that does nothing is a row that
    // teaches the user the setting is broken.
    expect(find.text('Only notify for mentions'), findsNothing);
    // Push and the test button survive: they are how the user gets notifications
    // working again, and both are outside the policy.
    expect(find.text('Send test notification'), findsOneWidget);
  });

  testWidgets('a network can be muted, and muting is not disabling', (
    tester,
  ) async {
    final (:stores, :container) = await pump(tester);

    // The WhatsApp row's three segments, in `_NetworkMode` order.
    await tester.tap(find.text('Muted').first);
    await tester.pumpAndSettle();

    final policy = container.read(notificationPolicyProvider);
    expect(policy.mutedNetworks, {ChatNetwork.whatsapp});
    expect(policy.disabledNetworks, isEmpty);
    expect(persisted(stores).mutedNetworks, {ChatNetwork.whatsapp});

    // Off replaces Muted rather than joining it: one network, one verdict.
    await tester.tap(find.text('Off').first);
    await tester.pumpAndSettle();

    final off = container.read(notificationPolicyProvider);
    expect(off.disabledNetworks, {ChatNetwork.whatsapp});
    expect(off.mutedNetworks, isEmpty);
    expect(persisted(stores).disabledNetworks, {ChatNetwork.whatsapp});
    // And the other network is untouched throughout.
    expect(off.isNetworkEnabled(ChatNetwork.signal), isTrue);
  });

  testWidgets('mentions-only and the preview switch persist', (tester) async {
    final (:stores, :container) = await pump(tester);

    await tester.tap(find.text('Only notify for mentions'));
    await tester.tap(find.text('Show message text on the lock screen'));
    await tester.pumpAndSettle();

    expect(persisted(stores).mentionsOnly, isTrue);
    expect(persisted(stores).showPreviews, isFalse);
    expect(container.read(notificationPolicyProvider).mentionsOnly, isTrue);
  });

  testWidgets('a network with no bridge says so instead of showing nothing', (
    tester,
  ) async {
    // First launch, before any bridge has connected. An empty "Networks"
    // heading reads as a screen that failed to load.
    await pump(tester, networks: const []);

    expect(
      find.textContaining('No bridges are configured yet'),
      findsOneWidget,
    );
    expect(find.text('Muted'), findsNothing);
  });

  testWidgets('mute bypass is a switch of its own, and persists', (
    tester,
  ) async {
    // Slack semantics and Matrix semantics both have users, which is why this
    // is a setting rather than a constant — and why `push_rules.dart` refuses
    // to send a bypassable mute to the homeserver.
    final (:stores, :container) = await pump(tester);
    expect(
      container.read(notificationPolicyProvider).mentionsBypassMute,
      isTrue,
    );

    await tester.tap(find.text('Mentions break through a mute'));
    await tester.pumpAndSettle();

    expect(persisted(stores).mentionsBypassMute, isFalse);
  });

  testWidgets('quiet hours start as a window, not as empty pickers', (
    tester,
  ) async {
    await withClock(Clock.fixed(now), () async {
      final (:stores, :container) = await pump(tester);

      expect(find.text('From'), findsNothing);
      await tester.tap(find.widgetWithText(SwitchListTile, 'Quiet hours'));
      await tester.pumpAndSettle();

      final quiet = persisted(stores).quietHours!;
      expect(quiet.startMinute, 22 * 60);
      expect(quiet.endMinute, 7 * 60);
      // The offset is what lets a background isolate with no timezone reach the
      // same verdict as the UI.
      expect(quiet.offsetMinutes, now.timeZoneOffset.inMinutes);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Until'), findsOneWidget);
      expect(find.text('22:00'), findsOneWidget);
      expect(find.text('07:00'), findsOneWidget);

      // And the sub-switches write into the same window rather than replacing
      // it with a fresh default.
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Let mentions through'),
      );
      await tester.pumpAndSettle();
      expect(persisted(stores).quietHours!.allowMentions, isFalse);
      expect(persisted(stores).quietHours!.startMinute, 22 * 60);
      expect(container.read(notificationPolicyProvider).quietHours, isNotNull);
    });
  });

  testWidgets(
    'delivering silently is a property of the window, not of a new one',
    (tester) async {
      await withClock(Clock.fixed(now), () async {
        final (:stores, container: _) = await pump(
          tester,
          policy: NotificationPolicy(
            quietHours: QuietHours(
              startMinute: 23 * 60,
              endMinute: 6 * 60,
              offsetMinutes: now.timeZoneOffset.inMinutes,
              allowMentions: false,
            ),
          ),
        );

        await tester.tap(
          find.widgetWithText(
            SwitchListTile,
            'Deliver silently instead of hiding',
          ),
        );
        await tester.pumpAndSettle();

        final quiet = persisted(stores).quietHours!;
        expect(quiet.deliverSilently, isTrue);
        // Every other edge of the window survives: this is the switch that turns
        // "nothing happened at 3am" into "it is in the shade in the morning", not
        // a reset to the defaults.
        expect(quiet.startMinute, 23 * 60);
        expect(quiet.endMinute, 6 * 60);
        expect(quiet.allowMentions, isFalse);
      });
    },
  );

  testWidgets('the time picker moves one edge of the window, not both', (
    tester,
  ) async {
    await withClock(Clock.fixed(now), () async {
      final (:stores, container: _) = await pump(
        tester,
        policy: NotificationPolicy(
          quietHours: QuietHours(
            startMinute: 22 * 60,
            endMinute: 7 * 60,
            offsetMinutes: now.timeZoneOffset.inMinutes,
          ),
        ),
      );

      await tester.tap(find.text('From'));
      await tester.pumpAndSettle();
      // Text entry rather than the dial: dragging a clock face by hit-test
      // coordinates tests Flutter's picker, not Weft's screen.
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      // Scoped to the dialog: the screen's own push-gateway field is still in
      // the tree underneath it, and `.first` would land there.
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.first, '23');
      await tester.enterText(fields.last, '15');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final quiet = persisted(stores).quietHours!;
      expect(quiet.startMinute, 23 * 60 + 15);
      // The edge the user did not touch is exactly where they left it.
      expect(quiet.endMinute, 7 * 60);
      expect(find.text('23:15'), findsOneWidget);
    });
  });

  group('muted chats', () {
    const chat = Chat(
      id: 'merged:contact_1',
      title: 'Grace',
      contactId: 'contact_1',
      sources: [
        ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
      ],
    );

    testWidgets('an empty list says so rather than showing nothing', (
      tester,
    ) async {
      await pump(tester, chats: const [chat]);
      expect(find.text('Nothing is muted.'), findsOneWidget);
    });

    testWidgets('a timed mute shows how much of it is left', (tester) async {
      await withClock(Clock.fixed(now), () async {
        final (:stores, :container) = await pump(
          tester,
          chats: const [chat],
          policy: NotificationPolicy().muteChat(
            chat.id,
            until: now.add(const Duration(minutes: 47)),
          ),
        );

        // The title, not the id: the list is about conversations.
        expect(find.text('Grace'), findsOneWidget);
        expect(find.text('Muted for another 47 minutes'), findsOneWidget);

        await tester.tap(find.text('Unmute'));
        await tester.pumpAndSettle();

        expect(find.text('Nothing is muted.'), findsOneWidget);
        expect(persisted(stores).chats, isEmpty);
        expect(container.read(notificationPolicyProvider).chats, isEmpty);
      });
    });

    testWidgets('a chat muted on the homeserver is listed too', (tester) async {
      // Muted from the chat screen, which writes a push rule and never touches
      // the policy. Listing only the policy's own mutes would leave a user
      // staring at an empty list while their phone stayed quiet.
      const muted = Chat(
        id: '!wa:example.org',
        title: 'Standup',
        isGroup: true,
        muted: true,
        sources: [
          ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
        ],
      );
      final repository = _FakeChatRepository(chats: const [muted]);
      await pump(tester, repository: repository);

      expect(find.text('Standup'), findsOneWidget);
      expect(find.text('Muted on the homeserver'), findsOneWidget);

      await tester.tap(find.text('Unmute'));
      await tester.pumpAndSettle();

      // Lifted where it actually lives, which is the server.
      expect(repository.unmuted, ['!wa:example.org']);
    });

    testWidgets('an indefinite mute is not described as expiring', (
      tester,
    ) async {
      await withClock(Clock.fixed(now), () async {
        await pump(
          tester,
          chats: const [chat],
          policy: NotificationPolicy().muteChat(chat.id),
        );

        expect(find.text('Muted in Braid'), findsOneWidget);
        expect(find.textContaining('for another'), findsNothing);
      });
    });

    testWidgets('a chat muted both ways is listed once and lifted twice', (
      tester,
    ) async {
      // Silenced from the chat screen — a homeserver push rule — and then again
      // for an hour from a notification action. Lifting only one leaves the
      // phone quiet, which reads as an Unmute button that does nothing.
      await withClock(Clock.fixed(now), () async {
        const muted = Chat(
          id: '!wa:example.org',
          title: 'Standup',
          isGroup: true,
          muted: true,
          sources: [
            ChatSource(
              roomId: '!wa:example.org',
              network: ChatNetwork.whatsapp,
            ),
          ],
        );
        final repository = _FakeChatRepository(chats: const [muted]);
        final (:stores, :container) = await pump(
          tester,
          repository: repository,
          policy: NotificationPolicy().muteChat(
            muted.id,
            until: now.add(const Duration(hours: 3)),
          ),
        );

        expect(find.text('Standup'), findsOneWidget);
        expect(
          find.text('Muted for another 3 hours · Muted on the homeserver'),
          findsOneWidget,
        );

        await tester.tap(find.text('Unmute'));
        await tester.pumpAndSettle();

        expect(persisted(stores).chats, isEmpty);
        expect(repository.unmuted, ['!wa:example.org']);
        expect(find.text('Nothing is muted.'), findsOneWidget);
      });
    });

    testWidgets('a muted chat the inbox has not resolved still appears', (
      tester,
    ) async {
      // Archived, or not yet synced. Dropping it from the list would leave
      // something silencing the user with no way to find it.
      await withClock(Clock.fixed(now), () async {
        await pump(
          tester,
          policy: NotificationPolicy().muteChat('merged:contact_9'),
        );

        expect(find.text('merged:contact_9'), findsOneWidget);
      });
    });

    testWidgets('a lapsed timed mute is pruned on open', (tester) async {
      await withClock(Clock.fixed(now), () async {
        final (:stores, :container) = await pump(
          tester,
          chats: const [chat],
          policy: NotificationPolicy()
              .muteChat(chat.id, until: now.subtract(const Duration(hours: 2)))
              .muteChat('merged:contact_2'),
        );

        // Gone from the blob, not merely filtered out of the list — nothing
        // else ever removes it, so an hour's mute would otherwise be a key
        // that outlived the app.
        expect(persisted(stores).chats.keys, ['merged:contact_2']);
        expect(find.text('Grace'), findsNothing);
      });
    });
  });

  testWidgets('the push gateway is saved deliberately, not per keystroke', (
    tester,
  ) async {
    final (:stores, :container) = await pump(tester);

    await tester.enterText(
      find.byType(TextField),
      ' https://sygnal.example.org/_matrix/push/v1/notify ',
    );
    await tester.pumpAndSettle();
    // Free text, so it is not committed until the user says so — unlike every
    // switch on this screen.
    expect(stores.settings.getString(WeftSettings.notifyPushGateway), isNull);

    await tester.tap(find.text('Save gateway'));
    await tester.pumpAndSettle();

    expect(
      stores.settings.getString(WeftSettings.notifyPushGateway),
      'https://sygnal.example.org/_matrix/push/v1/notify',
    );
    expect(
      container.read(pushGatewayProvider),
      Uri.parse('https://sygnal.example.org/_matrix/push/v1/notify'),
    );
  });

  testWidgets('the test button survives having nothing to post through', (
    tester,
  ) async {
    // Desktop with no push, or a build with no Firebase config. The button is
    // still there — it is how the user checks the OS has not blocked Weft —
    // and pressing it must not throw.
    await pump(tester);

    await tester.tap(find.text('Send test notification'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  group('push status', () {
    // Three of the six statuses are not failures at all, and the sentence is
    // the whole of what the user has to act on. One test each rather than a
    // loop inside one, because a second `pumpWidget` reuses the `ProviderScope`
    // element and its container — the override would be replaced without the
    // provider being recomputed, and the screen would still show the first
    // status.
    for (final (status, expected) in const [
      (
        PushRegistrationStatus.notConfigured,
        'No push gateway configured, so this device is not woken.',
      ),
      (
        PushRegistrationStatus.unsupportedPlatform,
        'This platform has no push. Notifications arrive while Braid is '
            'running.',
      ),
      (PushRegistrationStatus.registered, 'Registered with your homeserver.'),
    ]) {
      testWidgets('${status.name} says what to do about it', (tester) async {
        await pump(tester, push: PushRegistrationOutcome(status));
        expect(find.text(expected), findsOneWidget);
      });
    }

    testWidgets('an outcome that carries its own sentence uses it', (
      tester,
    ) async {
      // `WeftPushRegistration` writes the actionable ones itself — the enum
      // label is only the fallback.
      await pump(
        tester,
        push: const PushRegistrationOutcome(
          PushRegistrationStatus.failed,
          message: 'The homeserver rejected the pusher (M_UNKNOWN).',
        ),
      );

      expect(
        find.text('The homeserver rejected the pusher (M_UNKNOWN).'),
        findsOneWidget,
      );
      expect(find.text('Registration failed.'), findsNothing);
    });

    testWidgets('Retry asks again', (tester) async {
      var attempts = 0;
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
            notificationServiceProvider.overrideWith((ref) async => null),
            pushRegistrationProvider.overrideWith((ref) async {
              attempts++;
              return const PushRegistrationOutcome(
                PushRegistrationStatus.noToken,
              );
            }),
          ],
          child: MaterialApp(
            theme: WeftTheme.build(),
            home: const NotificationsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(attempts, 1);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      // Invalidating the provider *is* the retry button — there is no second
      // registration path for it to have gone down.
      expect(attempts, 2);
    });
  });

  group('the test notification', () {
    testWidgets('posts through the real path and says where it went', (
      tester,
    ) async {
      final sink = RecordingNotificationSink();
      await pump(tester, sink: sink);

      await tester.tap(find.text('Send test notification'));
      await tester.pumpAndSettle();

      // A real notification, in a conversation of its own — attributing Weft's
      // sample text to a contact would put words in their mouth in the shade.
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.groupKey, kTestNotificationChatId);
      expect(sink.shown.single.title, 'Notification test');
      // The first available network, so the channel under test is the one the
      // user's own messages arrive on.
      expect(
        sink.shown.single.details.android!.channelId,
        'weft.messages.whatsapp',
      );
      expect(
        find.textContaining('Posted on the WhatsApp channel'),
        findsOneWidget,
      );
    });

    testWidgets('a suppressed test names the setting responsible', (
      tester,
    ) async {
      // The answer the button exists to give. A button that appears to do
      // nothing teaches the user that notifications are broken.
      final sink = RecordingNotificationSink();
      await pump(
        tester,
        sink: sink,
        policy: NotificationPolicy(mentionsOnly: true),
      );

      await tester.tap(find.text('Send test notification'));
      await tester.pumpAndSettle();

      expect(sink.shown, isEmpty);
      expect(
        find.textContaining(
          'Only mentions get through, and a test message does not mention you.',
        ),
        findsOneWidget,
      );
    });
  });
}

/// The slice of [ChatRepository] this screen touches. Everything else throws:
/// a settings screen that started calling the rest of the repository should
/// fail loudly.
class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({
    List<Chat> chats = const [],
    this.networks = const [ChatNetwork.whatsapp, ChatNetwork.signal],
  }) : _chats = StreamController<List<Chat>>.broadcast() {
    _latest = chats;
  }

  final List<ChatNetwork> networks;
  final StreamController<List<Chat>> _chats;
  late List<Chat> _latest;

  /// Chats unmuted through the repository, i.e. on the homeserver.
  final List<String> unmuted = [];

  @override
  List<ChatNetwork> get availableNetworks => networks;

  @override
  Stream<List<Chat>> watchChats() async* {
    yield _latest;
    yield* _chats.stream;
  }

  @override
  Future<void> setMuted(String chatId, {required bool muted}) async {
    if (!muted) unmuted.add(chatId);
    _latest = [
      for (final chat in _latest)
        if (chat.id == chatId) chat.copyWith(muted: muted) else chat,
    ];
    _chats.add(_latest);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
