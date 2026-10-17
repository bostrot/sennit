import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_autoreply/weft_autoreply.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_store/weft_store.dart';

import 'package:weft/app/auto_reply_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/features/settings/auto_reply_screen.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/ai/auto_reply_writer.dart';

import 'support/auto_reply_fakes.dart';

/// The screen is the only place an [AutoReplyRule] is written by a human, so
/// what these pin is the round trip: a control moves, the rule the engine reads
/// changes, and the blob in the real [SettingsStore] changes with it.
///
/// The one thing asserted on pixels rather than state is the explainer, and
/// that is deliberate. Every sentence in it is something a user would be upset
/// to discover afterwards — messages sent by themselves, chats left unread, an
/// hourly ceiling — and a test that let it be moved behind a disclosure would
/// be letting the feature ship without its warning.
void main() {
  Widget appWith(
    WeftStores stores, {
    required Widget home,
    List<Chat> chats = const [],
  }) => ProviderScope(
    overrides: [
      storesProvider.overrideWithValue(stores),
      chatRepositoryProvider.overrideWithValue(_FakeChatRepository(chats)),
      autoReplyServiceProvider.overrideWithValue(null),
    ],
    child: MaterialApp(
      localizationsDelegates: weftLocalizationsDelegates,
      supportedLocales: weftSupportedLocales,
      theme: WeftTheme.build(),
      home: home,
    ),
  );

  Future<WeftStores> pump(
    WidgetTester tester, {
    Widget home = const AutoReplyScreen(),
    List<Chat> chats = const [],
    List<AutoReplyRule> rules = const [],
    String? llmBaseUrl,
  }) async {
    // Tall, because the screen is a ListView: at 800×600 everything past the
    // rule list is never built, and a finder that cannot see a control is
    // indistinguishable from a control that is not there.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    if (rules.isNotEmpty) {
      stores.settings.setJson(
        WeftSettings.autoReplyRules,
        AutoReplyRule.listToJson(rules),
      );
    }
    if (llmBaseUrl != null) {
      stores.settings
        ..setString(WeftSettings.llmBaseUrl, llmBaseUrl)
        ..setString(WeftSettings.llmModel, 'llama3');
    }

    await tester.pumpWidget(appWith(stores, home: home, chats: chats));
    await tester.pumpAndSettle();
    return stores;
  }

  AutoReplyRule rule({
    String id = 'away',
    String name = 'Out of office',
    bool enabled = true,
    String prompt = 'Say I am away until Monday.',
    AutoReplyAudience audience = const EveryoneAudience(),
  }) => AutoReplyRule(
    id: id,
    name: name,
    prompt: prompt,
    audience: audience,
    enabled: enabled,
  );

  group('the screen itself', () {
    testWidgets('states the three things that would surprise someone', (
      tester,
    ) async {
      await pump(tester, llmBaseUrl: 'http://localhost:11434/v1');

      // Sent automatically…
      expect(find.textContaining('by itself'), findsOneWidget);
      // …the chat stays unread…
      expect(find.textContaining('stays unread'), findsOneWidget);
      // …and there is a ceiling, with the real number in it.
      expect(
        find.textContaining('$kAutoReplyMaxPerConversation automatic replies'),
        findsOneWidget,
      );
    });

    testWidgets('says so when no model is configured', (tester) async {
      await pump(tester);

      expect(find.textContaining('No model is set up yet'), findsOneWidget);
      // And names the screen that fixes it, from that screen's own key.
      expect(find.textContaining('Search & transcription'), findsOneWidget);
    });

    testWidgets('the notice goes once an endpoint exists', (tester) async {
      await pump(tester, llmBaseUrl: 'http://localhost:11434/v1');

      expect(find.textContaining('No model is set up yet'), findsNothing);
    });

    testWidgets('an empty list says so rather than showing nothing', (
      tester,
    ) async {
      await pump(tester);

      expect(find.textContaining('No rules yet'), findsOneWidget);
    });
  });

  group('the rule list', () {
    testWidgets('shows a rule with its name and audience', (tester) async {
      await pump(tester, rules: [rule()]);

      expect(find.text('Out of office'), findsOneWidget);
      expect(find.textContaining('Everyone'), findsWidgets);
    });

    testWidgets('a rule with no name falls back to its audience', (
      tester,
    ) async {
      await pump(tester, rules: [rule(name: '  ')]);

      expect(find.text('Everyone'), findsWidgets);
    });

    testWidgets('the switch writes through to the store', (tester) async {
      final stores = await pump(tester, rules: [rule(enabled: false)]);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.enabled, isTrue);
    });

    testWidgets('a rule with no prompt cannot be switched on', (tester) async {
      // Nothing to send, so the switch is dead rather than lying about being
      // armed.
      await pump(tester, rules: [rule(prompt: '')]);

      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.onChanged, isNull);
      expect(find.textContaining('No prompt yet'), findsOneWidget);
    });
  });

  group('the editor', () {
    testWidgets('a new rule is saved off, whatever the form said', (
      tester,
    ) async {
      // A rule that started replying the moment it was saved would be a message
      // sent by a half-finished form.
      final stores = await pump(tester);

      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(1),
        'Say I am on holiday.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.prompt, 'Say I am on holiday.');
      expect(saved.single.enabled, isFalse);
    });

    testWidgets('Save is dead until there is a prompt', (tester) async {
      await pump(tester);

      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();

      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Save'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('editing keeps the id, so the cooldown is not reset', (
      tester,
    ) async {
      final stores = await pump(tester, rules: [rule(id: 'away')]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Renamed');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.id, 'away');
      expect(saved.single.name, 'Renamed');
    });

    testWidgets('editing an armed rule leaves it armed', (tester) async {
      final stores = await pump(tester, rules: [rule(enabled: true)]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.enabled, isTrue);
    });

    testWidgets('the audience picker changes what is stored', (tester) async {
      final stores = await pump(
        tester,
        chats: [
          const Chat(
            id: '!a:example.org',
            title: 'Grace',
            sources: [
              ChatSource(
                roomId: '!a:example.org',
                network: ChatNetwork.whatsapp,
              ),
            ],
          ),
        ],
        rules: [rule()],
      );

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Networks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.audience, isA<NetworkAudience>());
    });

    testWidgets('a schedule window can be turned on and comes back', (
      tester,
    ) async {
      final stores = await pump(tester, rules: [rule()]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Only at set times'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved.single.window, isNotNull);
      expect(saved.single.window!.startMinute, 9 * 60);
    });

    testWidgets('deleting asks first, and then removes the rule', (
      tester,
    ) async {
      final stores = await pump(tester, rules: [rule()]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      expect(find.textContaining('stop answering'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      final saved = AutoReplyRule.listFromJson(
        stores.settings.getJson(WeftSettings.autoReplyRules),
      );
      expect(saved, isEmpty);
    });

    testWidgets('cancelling the delete keeps the rule', (tester) async {
      final stores = await pump(tester, rules: [rule()]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(
        AutoReplyRule.listFromJson(
          stores.settings.getJson(WeftSettings.autoReplyRules),
        ),
        hasLength(1),
      );
    });
  });

  group('the dry run', () {
    testWidgets('says what it will and will not do', (tester) async {
      await pump(tester, rules: [rule()]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing is sent'), findsOneWidget);
      expect(find.text('Write a sample reply'), findsOneWidget);
    });

    testWidgets('with no service, it reports rather than doing nothing', (
      tester,
    ) async {
      // The state a widget test is in, and the state a signed-out app is in.
      // A button that silently does nothing is the worst of the three.
      await pump(tester, rules: [rule()]);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Write a sample reply'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No model is set up'), findsWidgets);
    });

    testWidgets('the button is dead until there is a prompt', (tester) async {
      await pump(tester);

      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();

      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Write a sample reply'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('the attempt log', () {
    Future<ProviderContainer> pumpLog(
      WidgetTester tester, {
      required AutoReplyAttempt attempt,
      AutoReplyService? service,
    }) async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            _FakeChatRepository(const []),
          ),
          autoReplyServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      container.read(autoReplyLogProvider.notifier).add(attempt);

      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const AutoReplyScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    const grace = '!grace:example.org';
    final graceChat = Chat(
      id: grace,
      title: 'Grace',
      unreadCount: 1,
      sources: const [ChatSource(roomId: grace, network: ChatNetwork.whatsapp)],
    );
    AutoReplyAttempt failed(AutoReplyOutcome outcome) => AutoReplyAttempt(
      chatId: grace,
      chatTitle: 'Grace',
      at: DateTime.utc(2026, 1, 15, 10),
      outcome: outcome,
      ruleName: 'Out of office',
    );

    testWidgets('a failure the model caused can be retried, and sends', (
      tester,
    ) async {
      final h = buildAutoReplyService(
        chat: graceChat,
        rules: [rule()],
        composer: FakeComposer(
          script: const [AutoReplyOutcome.refused, AutoReplyOutcome.refused],
        ),
      );
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);
      await h.service.handleMessage(
        WeftMessage(
          eventId: r'$in',
          roomId: grace,
          network: ChatNetwork.whatsapp,
          senderId: '@whatsapp_grace:example.org',
          senderName: 'Grace',
          timestamp: DateTime.utc(2026, 1, 15, 10),
          kind: MessageKind.text,
          isOwn: false,
          body: 'are you around?',
        ),
      );
      expect(h.transport.sent, isEmpty);

      await pumpLog(tester, attempt: h.attempts.single, service: h.service);
      await tester.tap(find.byTooltip('Retry'));
      await tester.pumpAndSettle();

      expect(h.transport.sent.single.body, 'I am away until Monday.');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('says so when there is nothing left to answer', (tester) async {
      final h = buildAutoReplyService(chat: graceChat, rules: [rule()]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await pumpLog(
        tester,
        attempt: failed(AutoReplyOutcome.timedOut),
        service: h.service,
      );
      await tester.tap(find.byTooltip('Retry'));
      await tester.pumpAndSettle();

      expect(h.composer.calls, isEmpty);
      expect(find.textContaining('nothing left to answer'), findsOneWidget);
    });

    testWidgets('a decline offers no retry', (tester) async {
      final h = buildAutoReplyService(chat: graceChat, rules: [rule()]);
      addTearDown(h.incoming.close);
      addTearDown(h.service.dispose);

      await pumpLog(
        tester,
        attempt: failed(AutoReplyOutcome.declined),
        service: h.service,
      );

      expect(find.byTooltip('Retry'), findsNothing);
    });

    testWidgets('no service, no retry button that would do nothing', (
      tester,
    ) async {
      await pumpLog(tester, attempt: failed(AutoReplyOutcome.unreachable));

      expect(find.byTooltip('Retry'), findsNothing);
    });

    testWidgets('is absent until something has happened', (tester) async {
      await pump(tester);

      expect(find.textContaining('Recent replies'), findsNothing);
    });

    testWidgets('shows a success with what was said', (tester) async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            _FakeChatRepository(const []),
          ),
          autoReplyServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(autoReplyLogProvider.notifier)
          .add(
            AutoReplyAttempt(
              chatId: '!a:example.org',
              chatTitle: 'Grace',
              at: DateTime.utc(2026, 1, 15, 10),
              outcome: AutoReplyOutcome.sent,
              ruleName: 'Out of office',
              text: 'Away until Monday.',
            ),
          );

      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const AutoReplyScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Grace'), findsOneWidget);
      expect(find.textContaining('Away until Monday.'), findsOneWidget);
    });

    testWidgets('a failure is on the screen, not only in a log', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            _FakeChatRepository(const []),
          ),
          autoReplyServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(autoReplyLogProvider.notifier)
          .add(
            AutoReplyAttempt(
              chatId: '!a:example.org',
              chatTitle: 'Grace',
              at: DateTime.utc(2026, 1, 15, 10),
              outcome: AutoReplyOutcome.unreachable,
              ruleName: 'Out of office',
            ),
          );

      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const AutoReplyScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be reached'), findsOneWidget);
    });

    testWidgets('a decline is shown as a choice, not an error', (tester) async {
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            _FakeChatRepository(const []),
          ),
          autoReplyServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(autoReplyLogProvider.notifier)
          .add(
            AutoReplyAttempt(
              chatId: '!a:example.org',
              chatTitle: 'Grace',
              at: DateTime.utc(2026, 1, 15, 10),
              outcome: AutoReplyOutcome.declined,
              ruleName: 'Out of office',
            ),
          );

      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: const AutoReplyScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('chose not to reply'), findsOneWidget);
      expect(find.byIcon(Icons.do_not_disturb_on_outlined), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });
  });
}

/// The slice of [ChatRepository] this screen touches. Everything else throws:
/// a settings screen that started calling the rest of the repository should
/// fail loudly.
class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository(this._chats);

  final List<Chat> _chats;

  @override
  List<ChatNetwork> get availableNetworks => const [ChatNetwork.whatsapp];

  @override
  Stream<List<Chat>> watchChats() => Stream.value(_chats);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
