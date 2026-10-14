/// The AI settings hub, and the "copy from" action on the endpoints screen.
///
/// Two claims. The first is that every AI setting is reachable from one row on
/// the settings list, and from nowhere else on it — three rows that each held a
/// third of the answer is what this replaced. The second is about what "copy"
/// copies: the address and the key, the *stored* key when nothing has been
/// typed, and never the model, which is the one field that differs between an
/// embedding, a speech and a chat endpoint on the same server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/settings/ai_screen.dart';
import 'package:weft/features/settings/auto_reply_screen.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/features/settings/models_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft_store/weft_store.dart';

import 'support/golden_harness.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));

  // Tall, because both screens are lazy lists: a row that was never built is
  // indistinguishable from a row that is not there.
  const tall = Size(500, 2400);

  TextField field(WidgetTester tester, String label, {int index = 0}) => tester
      .widgetList<TextField>(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        ),
      )
      .elementAt(index);

  group('AI settings hub', () {
    testWidgets('settings has one AI row, which leads to all three screens', (
      tester,
    ) async {
      await pumpWeft(
        tester,
        const SettingsScreen(),
        size: tall,
        stores: WeftStores.inMemory(),
      );

      expect(find.text(en.settingsAiTitle), findsOneWidget);
      expect(find.text(en.settingsEndpointsTitle), findsNothing);
      expect(find.text(en.settingsModelsTitle), findsNothing);
      expect(find.text(en.settingsAutoReplyTitle), findsNothing);

      await tester.tap(find.text(en.settingsAiTitle));
      await tester.pumpAndSettle();
      expect(find.byType(AiSettingsScreen), findsOneWidget);

      final doors = <String, Type>{
        en.settingsEndpointsTitle: EndpointsScreen,
        en.settingsAutoReplyTitle: AutoReplyScreen,
      };
      for (final door in doors.entries) {
        await tester.tap(find.text(door.key));
        await tester.pumpAndSettle();
        expect(find.byType(door.value), findsOneWidget, reason: door.key);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      // The models screen polls its installer, so it never settles.
      await tester.tap(find.text(en.settingsModelsTitle));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ModelsScreen), findsOneWidget);
    });
  });

  group('copying an endpoint', () {
    Future<WeftStores> pumpEndpoints(WidgetTester tester) async {
      final stores = WeftStores.inMemory();
      stores.settings
        ..setBool(WeftSettings.embeddingEnabled, value: true)
        ..setBool(WeftSettings.transcriptionEnabled, value: true)
        ..setString(WeftSettings.llmBaseUrl, 'http://nas.local:11434/v1')
        ..setString(WeftSettings.llmModel, 'llama3.2')
        ..setString(WeftSettings.embeddingModel, 'nomic-embed-text');
      await pumpWeft(
        tester,
        const EndpointsScreen(),
        size: tall,
        stores: stores,
      );
      return stores;
    }

    Future<void> copyInto(
      WidgetTester tester,
      String target,
      String source,
    ) async {
      await tester.tap(find.byKey(ValueKey('copy-into-$target')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, source));
      await tester.pumpAndSettle();
    }

    testWidgets('fills the address and the stored key, and leaves the model', (
      tester,
    ) async {
      final stores = await pumpEndpoints(tester);
      // In memory only — the keychain's method channel never answers here.
      stores.llmApiKey = 'sk-stored';

      await copyInto(tester, 'embeddings', en.endpointsLlmTitle);

      // Section order on screen: embeddings, transcription, LLM.
      expect(
        field(tester, en.settingsBaseUrlField).controller!.text,
        'http://nas.local:11434/v1',
      );
      expect(
        field(tester, en.settingsApiKeyField).controller!.text,
        'sk-stored',
      );
      expect(
        field(tester, en.settingsModelField).controller!.text,
        'nomic-embed-text',
      );
      // Transcription was not the target and is untouched.
      expect(
        field(tester, en.settingsBaseUrlField, index: 1).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a typed key wins over the stored one', (tester) async {
      final stores = await pumpEndpoints(tester);
      stores.llmApiKey = 'sk-stored';

      await tester.enterText(
        find.byWidget(field(tester, en.settingsApiKeyField, index: 2)),
        'sk-typed',
      );
      await copyInto(tester, 'transcription', en.endpointsLlmTitle);

      expect(
        field(tester, en.settingsApiKeyField, index: 1).controller!.text,
        'sk-typed',
      );
    });

    testWidgets('a source without a key leaves the target key alone', (
      tester,
    ) async {
      await pumpEndpoints(tester);

      await tester.enterText(
        find.byWidget(field(tester, en.settingsApiKeyField)),
        'sk-mine',
      );
      await copyInto(tester, 'embeddings', en.endpointsLlmTitle);

      expect(
        field(tester, en.settingsBaseUrlField).controller!.text,
        'http://nas.local:11434/v1',
      );
      expect(field(tester, en.settingsApiKeyField).controller!.text, 'sk-mine');
    });

    testWidgets('an endpoint is never offered as its own source', (
      tester,
    ) async {
      await pumpEndpoints(tester);

      await tester.tap(find.byKey(const ValueKey('copy-into-llm')));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(MenuItemButton, en.endpointsLlmTitle),
        findsNothing,
      );
      expect(
        find.widgetWithText(MenuItemButton, en.endpointsEmbeddingsTitle),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(MenuItemButton, en.endpointsTranscriptionTitle),
        findsOneWidget,
      );
    });
  });
}
