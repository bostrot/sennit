import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weft/app/auto_reply_providers.dart';
import 'package:weft/app/billing_providers.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/quick_message_providers.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/chat/rich_text_view.dart';
import 'package:weft/features/settings/pro_screen.dart';
import 'package:weft/features/settings/quick_messages_screen.dart';
import 'package:weft/services/ai/auto_reply_service.dart';
import 'package:weft/services/billing/entitlements.dart';
import 'package:weft_design/weft_design.dart';

import 'support/recording_repository.dart';

/// Attach menu → Quick message → a pick → a draft in the composer, unsent.
///
/// The model is a `MockClient` answering in turn, so "regenerate" can be seen
/// to replace the first draft rather than add to it. The one thing every test
/// here also asserts is the feature's promise: nothing is ever sent.
void main() {
  const mergedChat = 'merged:anna';

  late DemoChatRepository demo;
  late RecordingChatRepository repository;
  late List<Map<String, Object?>> requests;

  setUp(() {
    clearMessageDocumentCache();
    demo = DemoChatRepository(uploadTick: Duration.zero);
    repository = RecordingChatRepository(demo);
    requests = [];
  });
  tearDown(() => demo.dispose());

  http.Client answering(List<String> answers) {
    var i = 0;
    return MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, Object?>);
      final content = answers[i++ % answers.length];
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    AutoReplyEndpoint? endpoint = const AutoReplyEndpoint(
      baseUrl: 'http://llm.test/v1',
      model: 'small',
    ),
    http.Client? client,
    bool locked = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(repository),
          autoReplyEndpointProvider.overrideWithValue(endpoint),
          quickMessageClientProvider.overrideWithValue(client),
          if (locked) ...[
            sennitEditionProvider.overrideWithValue(SennitEdition.store),
            storeBillingPlatformProvider.overrideWithValue(true),
          ],
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          theme: WeftTheme.build(),
          home: const ChatView(chatId: mergedChat),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openQuickMessages(WidgetTester tester) async {
    final l10n = tester.element(find.byType(ChatView)).l10n;
    await tester.tap(find.byTooltip(l10n.attachSheetTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.attachSourceQuickMessage));
    await tester.pumpAndSettle();
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  Iterable<Object?> sends() => repository.calls
      .where((c) => c.method == 'send' || c.method == 'sendRich')
      .map((c) => c.body);

  testWidgets('a pick puts the draft into the composer, unsent', (
    tester,
  ) async {
    await pump(
      tester,
      client: answering([
        'Happy birthday, Anna! 🎂 Have a wonderful day!',
        'Happy birthday, Anna! Hope your day is as lovely as you are.',
      ]),
    );
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await openQuickMessages(tester);
    expect(find.text(l10n.quickMessageSheetTitle), findsOneWidget);
    expect(find.text(l10n.quickMessageEditList), findsOneWidget);
    await tester.tap(find.text(l10n.quickMessagePresetBirthday));
    await tester.pumpAndSettle();

    expect(
      composerText(tester),
      'Happy birthday, Anna! 🎂 Have a wonderful day!',
    );
    expect(
      find.text(l10n.quickMessageWritten(l10n.quickMessagePresetBirthday)),
      findsOneWidget,
    );
    expect(sends(), isEmpty);

    // The demo chat is "Anna Maven": the model is told her first name.
    final prompt =
        ((requests.single['messages']! as List).last as Map)['content']
            as String;
    expect(prompt, contains('It is for: Anna'));

    // Regenerate replaces the draft; it does not append a second one.
    await tester.tap(find.text(l10n.quickMessageRegenerate));
    await tester.pumpAndSettle();
    expect(
      composerText(tester),
      'Happy birthday, Anna! Hope your day is as lovely as you are.',
    );
    expect(requests, hasLength(2));
    expect(sends(), isEmpty);

    // Cleared by hand, the bar has nothing left to talk about.
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pumpAndSettle();
    expect(find.text(l10n.quickMessageRegenerate), findsNothing);
  });

  testWidgets('what the user typed first is kept', (tester) async {
    await pump(tester, client: answering(['Thank you so much, Anna!']));
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await tester.enterText(find.byType(TextField).last, 'Hey!');
    await tester.pumpAndSettle();
    await openQuickMessages(tester);
    await tester.tap(find.text(l10n.quickMessagePresetThanks));
    await tester.pumpAndSettle();

    expect(composerText(tester), 'Hey! Thank you so much, Anna!');
    expect(sends(), isEmpty);
  });

  testWidgets('no model set up says where to add one, and writes nothing', (
    tester,
  ) async {
    await pump(tester, endpoint: null);
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await openQuickMessages(tester);
    await tester.tap(find.text(l10n.quickMessagePresetBirthday));
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.quickMessageNoEndpoint(l10n.settingsEndpointsTitle)),
      findsOneWidget,
    );
    expect(find.text(l10n.quickMessageSetUp), findsOneWidget);
    expect(composerText(tester), isEmpty);
  });

  testWidgets('a model that fails says why, and writes nothing', (
    tester,
  ) async {
    await pump(tester, client: answering(['<think>hmm, what']));
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await openQuickMessages(tester);
    await tester.tap(find.text(l10n.quickMessagePresetBirthday));
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.quickMessageFailed(l10n.autoReplyOutcomeRefused)),
      findsOneWidget,
    );
    expect(composerText(tester), isEmpty);
    expect(find.text(l10n.quickMessageRegenerate), findsNothing);
  });

  testWidgets('a slow model counts the wait, and Cancel aborts it', (
    tester,
  ) async {
    var aborted = false;
    // A model that never answers on its own, as a local one on a laptop can
    // seem to: only the abort ends the request.
    final client = MockClient.streaming((request, body) async {
      await body.drain<void>();
      await (request as http.Abortable).abortTrigger;
      aborted = true;
      throw http.RequestAbortedException(request.url);
    });
    await pump(tester, client: client);
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await openQuickMessages(tester);
    await tester.tap(find.text(l10n.quickMessagePresetBirthday));
    // Not settled: the spinner turns for as long as the model takes.
    await tester.pump();
    expect(find.byTooltip(l10n.commonCancel), findsOneWidget);
    expect(find.text('0:01'), findsNothing);

    // Real time, not fake: the bar reads a stopwatch.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 6)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(RegExp(r'^0:0[5-9]$')), findsOneWidget);
    expect(aborted, isFalse);

    await tester.tap(find.byTooltip(l10n.commonCancel));
    await tester.pumpAndSettle();

    expect(aborted, isTrue);
    expect(find.byTooltip(l10n.commonCancel), findsNothing);
    expect(composerText(tester), isEmpty);
    // Cancelled is not failed: no error for a stop the user asked for.
    expect(find.textContaining(l10n.quickMessageFailed('')), findsNothing);
    expect(sends(), isEmpty);
  });

  testWidgets('"Edit quick messages" opens the list', (tester) async {
    await pump(tester, client: answering(['x']));
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await openQuickMessages(tester);
    await tester.tap(find.text(l10n.quickMessageEditList));
    await tester.pumpAndSettle();

    expect(find.byType(QuickMessagesScreen), findsOneWidget);
    expect(find.text(l10n.quickMessagePresetBirthday), findsOneWidget);
  });

  testWidgets('a build that charges badges the row and sells Pro instead', (
    tester,
  ) async {
    await pump(tester, client: answering(['x']), locked: true);
    final l10n = tester.element(find.byType(ChatView)).l10n;

    await tester.tap(find.byTooltip(l10n.attachSheetTitle));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text(l10n.attachSourceQuickMessage),
          matching: find.byType(ListTile),
        ),
        matching: find.byType(ProBadge),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(l10n.attachSourceQuickMessage));
    // Not settled: the Pro screen spins while it asks the store for prices.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ProScreen), findsOneWidget);
    expect(requests, isEmpty);
  });
}
