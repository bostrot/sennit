/// The screen is the only place a companion surface is switched on by a human,
/// so what these tests pin is the round trip rather than the pixels: a control
/// moves, the blob in the real [SettingsStore] changes with it, and the writer
/// that feeds the shared container is told before the user puts the phone down.
/// A test that asserted only on `snapshotSettingsProvider` would pass just as
/// happily against a screen that persisted nothing.
///
/// The other half is the disclosure itself. This gate is unusual among Weft's:
/// every other one sends something to a service the user chose, and this one
/// writes conversation content to a file on their own phone — which sounds
/// harmless and is the larger of the two. So the warning being *reachable*, and
/// the live preview being built by the same function the writer calls, are
/// assertions rather than review comments.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/snapshot_providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/features/settings/settings_section.dart';
import 'package:weft/features/settings/surfaces_screen.dart';
import 'package:weft/services/snapshot/snapshot_writer.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_snapshot/weft_snapshot.dart';

import 'support/semantics_probe.dart';
import 'support/snapshot_fixtures.dart';

void main() {
  final en = lookupAppL10n(const Locale('en'));

  /// Pumps the screen over a real in-memory store, and hands back everything a
  /// test needs to ask what actually happened: the store the next launch would
  /// read, the container the widgets read, and the writer between them.
  ///
  /// The surface is made tall because the screen is a `ListView`: at the default
  /// 800×600 the sections below the two surface switches are never built, and a
  /// finder that cannot see a control is indistinguishable from a control that
  /// is not there.
  Future<
    ({
      WeftStores stores,
      RecordingSnapshotGateway gateway,
      SnapshotWriter writer,
      ProviderContainer container,
    })
  >
  pump(
    WidgetTester tester, {
    List<Chat> chats = const [],
    List<ChatNetwork> networks = const [
      ChatNetwork.whatsapp,
      ChatNetwork.signal,
    ],
    SnapshotSettings? settings,
  }) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    settings?.writeTo(stores.settings);

    final gateway = RecordingSnapshotGateway();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storesProvider.overrideWithValue(stores),
          chatRepositoryProvider.overrideWithValue(
            _FakeChatRepository(chats: chats, networks: networks),
          ),
          snapshotGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const SurfacesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(SurfacesScreen));
    final container = ProviderScope.containerOf(element, listen: false);
    return (
      stores: stores,
      gateway: gateway,
      writer: container.read(snapshotWriterProvider),
      container: container,
    );
  }

  /// The gate as it would be rebuilt from storage on the next launch — not the
  /// one held in memory. This is the assertion that matters: a widget process
  /// has only what was written.
  SnapshotSettings persisted(WeftStores stores) =>
      SnapshotSettings.fromStore(stores.settings);

  /// The switch tile carrying [title], which is a [PrivacyGatedTitle] rather
  /// than a `Text` and so is not found by `widgetWithText`.
  Finder switchFor(String title) => find.ancestor(
    of: find.widgetWithText(PrivacyGatedTitle, title),
    matching: find.byType(SwitchListTile),
  );

  group('the defaults', () {
    testWidgets('both surfaces are off, and nothing is written', (
      tester,
    ) async {
      // Every install before this build, and every install after it until
      // somebody comes here. Off is the only correct default for a switch whose
      // effect is content leaving the encrypted store.
      final (:stores, :gateway, writer: _, :container) = await pump(tester);

      // Both surfaces off — the gate. What a row would show once one is
      // switched on is already decided (names and words), and discloses
      // nothing while nothing is written.
      for (final settings in [
        container.read(snapshotSettingsProvider),
        persisted(stores),
      ]) {
        expect(settings.anySurface, isFalse);
        expect(settings.policy.enabled, isFalse);
      }
      expect(gateway.writes, isEmpty);
      for (final tile in tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      )) {
        expect(tile.value, isFalse);
      }
    });

    testWidgets('nothing below the surface switches is shown while both are off', (
      tester,
    ) async {
      // A "message previews" row that feeds nothing is a row teaching the user
      // that the setting is broken — and, worse here, a row that reads as though
      // something is already being written.
      await pump(tester);

      expect(find.text('What a row shows'), findsNothing);
      expect(find.text('Networks'), findsNothing);
      expect(find.text('What leaves the encrypted store'), findsNothing);
      expect(find.byType(SwitchListTile), findsNWidgets(2));
    });

    testWidgets('opens and closes without throwing', (tester) async {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            chatRepositoryProvider.overrideWithValue(_FakeChatRepository()),
            snapshotGatewayProvider.overrideWithValue(
              RecordingSnapshotGateway(),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SurfacesScreen(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Widgets & watch'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the warning', () {
    testWidgets('is read before either switch, and named as a warning', (
      tester,
    ) async {
      // The red box and the shield glyph are the whole signal that this is not
      // more explanatory copy, and both are invisible to a screen reader. A
      // reader walking the screen in order has to meet the cost before the
      // control that incurs it.
      final handle = tester.ensureSemantics();
      await pump(tester);

      final labels = labelsIn(tester);
      final warning = labels.indexWhere(
        (label) => label.startsWith('Privacy warning.'),
      );
      final widgets = labels.indexWhere(
        (label) => label.contains('Home screen widgets'),
      );

      expect(warning, isNonNegative, reason: 'the notice has no node at all');
      expect(widgets, isNonNegative);
      expect(warning, lessThan(widgets));
      expect(
        labels[warning],
        contains('outside the encrypted store'),
        reason: 'the sentence that would stop someone has to be in the label',
      );
      handle.dispose();
    });

    testWidgets('travels with the switch for a reader who lands on it', (
      tester,
    ) async {
      // A reader who arrives by heading jump or by touch exploration never sees
      // the notice above. The hint is what reaches them, and it is on the tile's
      // own node rather than on a sibling — which is the whole reason
      // `PrivacyGatedTitle` exists.
      final handle = tester.ensureSemantics();
      await pump(tester);

      for (final title in const ['Home screen widgets', 'Watch']) {
        expect(
          tester.getSemantics(switchFor(title)).hint,
          contains('outside the encrypted store'),
          reason: '$title has no warning on its own node',
        );
      }
      handle.dispose();
    });
  });

  group('the surface switches', () {
    testWidgets('a tap persists and reaches the writer', (tester) async {
      // Both halves matter, and the second is the one that is easy to leave out:
      // bumping the revision rebuilds this screen, it does not touch the file
      // the widget is reading. The next inbox tick may be minutes away.
      final (:stores, :gateway, :writer, :container) = await pump(tester);

      await tester.tap(switchFor('Home screen widgets'));
      await tester.pumpAndSettle();

      expect(persisted(stores).widgets, isTrue);
      expect(persisted(stores).watch, isFalse);
      expect(container.read(snapshotSettingsProvider).widgets, isTrue);
      expect(writer.settings.widgets, isTrue);
    });

    testWidgets('switching a surface on republishes the payload at once', (
      tester,
    ) async {
      // With an inbox already published, the toggle has to reach the container
      // rather than only the store: someone who has just switched previews off
      // must see the home screen stop showing them before they put the phone
      // down, or they will reasonably conclude the switch did nothing.
      final (stores: _, :gateway, :writer, container: _) = await pump(
        tester,
        chats: [snapshotChat(unreadCount: 2)],
      );
      await writer.refresh([snapshotChat(unreadCount: 2)], now: snapshotNow);
      expect(gateway.writes, hasLength(1));
      expect(gateway.last.widgets, isFalse);

      await tester.tap(switchFor('Watch'));
      await tester.pumpAndSettle();

      expect(gateway.writes, hasLength(2));
      expect(gateway.last.watch, isTrue);
      expect(const SnapshotCodec().decode(gateway.last.json)!.enabled, isTrue);
    });

    testWidgets('the content switches appear only once a surface is on', (
      tester,
    ) async {
      final (:stores, gateway: _, writer: _, container: _) = await pump(tester);

      await tester.tap(switchFor('Watch'));
      await tester.pumpAndSettle();

      expect(find.text('What a row shows'), findsOneWidget);
      // And they are on: a surface switched on shows who and what, and the two
      // switches now on screen are how to take either back off.
      expect(persisted(stores).includePreviews, isTrue);
      expect(persisted(stores).includeSenderNames, isTrue);
    });

    testWidgets('previews and names persist independently', (tester) async {
      // Two decisions, not one: "don't show what they said" and "don't show who
      // they are" are different worries, and a widget on a desk in an open-plan
      // office is where the difference bites.
      final (:stores, gateway: _, :writer, container: _) = await pump(
        tester,
        settings: const SnapshotSettings(widgets: true),
      );

      await tester.tap(switchFor('Message previews'));
      await tester.pumpAndSettle();

      expect(persisted(stores).includePreviews, isTrue);
      expect(persisted(stores).includeSenderNames, isFalse);
      expect(writer.settings.policy.includePreviews, isTrue);

      await tester.tap(switchFor('Names and faces'));
      await tester.pumpAndSettle();

      expect(persisted(stores).includePreviews, isTrue);
      expect(persisted(stores).includeSenderNames, isTrue);
    });
  });

  group('networks', () {
    testWidgets('an exclusion persists and reaches the policy', (tester) async {
      final (:stores, gateway: _, :writer, :container) = await pump(
        tester,
        settings: const SnapshotSettings(widgets: true),
      );

      // The row reads *allowed*, so turning it off is the exclusion.
      await tester.tap(
        find.ancestor(
          of: find.text('Signal'),
          matching: find.byType(SwitchListTile),
        ),
      );
      await tester.pumpAndSettle();

      expect(persisted(stores).excludedNetworks, {'signal'});
      expect(writer.settings.policy.allows(ChatNetwork.signal), isFalse);
      expect(writer.settings.policy.allows(ChatNetwork.whatsapp), isTrue);
      expect(container.read(snapshotSettingsProvider).excludedNetworks, {
        'signal',
      });
    });

    testWidgets('excluding a second network does not lift the first', (
      tester,
    ) async {
      final (:stores, gateway: _, writer: _, container: _) = await pump(
        tester,
        settings: const SnapshotSettings(
          widgets: true,
          excludedNetworks: {'signal'},
        ),
      );

      await tester.tap(
        find.ancestor(
          of: find.text('WhatsApp'),
          matching: find.byType(SwitchListTile),
        ),
      );
      await tester.pumpAndSettle();

      expect(persisted(stores).excludedNetworks, {'signal', 'whatsapp'});
    });

    testWidgets('an exclusion can be lifted again', (tester) async {
      final (:stores, gateway: _, writer: _, container: _) = await pump(
        tester,
        settings: const SnapshotSettings(
          widgets: true,
          excludedNetworks: {'signal'},
        ),
      );

      await tester.tap(
        find.ancestor(
          of: find.text('Signal'),
          matching: find.byType(SwitchListTile),
        ),
      );
      await tester.pumpAndSettle();

      expect(persisted(stores).excludedNetworks, isEmpty);
    });

    testWidgets('no bridges yet says so rather than showing an empty heading', (
      tester,
    ) async {
      await pump(
        tester,
        networks: const [],
        settings: const SnapshotSettings(widgets: true),
      );

      expect(
        find.textContaining('No bridges are configured yet'),
        findsOneWidget,
      );
    });
  });

  group('the live preview', () {
    /// A chat with something to disclose in every field the policy gates.
    /// [text] inside the example widget row, not elsewhere on the screen.
    Finder inPreview(String text) => find.descendant(
      of: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_WidgetRowCard',
      ),
      matching: find.text(text),
    );

    Chat grace({int unreadCount = 3}) => snapshotChat(
      title: 'Grace',
      unreadCount: unreadCount,
      lastMessage: snapshotMessage(body: 'the otter is loose'),
    );

    testWidgets('discloses nothing but the count with both flags off', (
      tester,
    ) async {
      // `SnapshotSettings(widgets: true)` alone. The row is still there — the
      // user asked not to have their conversations readable over a shoulder, not
      // to stop being told they have any.
      await pump(
        tester,
        chats: [grace()],
        settings: const SnapshotSettings(widgets: true),
      );

      // Called by its network, which its dots already show. Looked for inside
      // the example row: the screen names every network again further down.
      expect(inPreview('WhatsApp'), findsOneWidget);
      expect(find.text('Grace'), findsNothing);
      expect(find.textContaining('otter'), findsNothing);
      expect(find.text('No message text is written.'), findsOneWidget);
    });

    testWidgets(
      'shows the words once previews are on, and the name once names are',
      (tester) async {
        await pump(
          tester,
          chats: [grace()],
          settings: const SnapshotSettings(
            widgets: true,
            includePreviews: true,
            includeSenderNames: true,
          ),
        );

        expect(find.text('Grace'), findsOneWidget);
        expect(find.text('Grace: the otter is loose'), findsOneWidget);
        expect(inPreview('WhatsApp'), findsNothing);
      },
    );

    testWidgets('follows the policy as it is changed, not as it was loaded', (
      tester,
    ) async {
      // The reason the preview is built through `buildSnapshotRow` rather than
      // drawn by hand: a mock-up is a second answer to what the policy discloses,
      // and it is the answer nobody re-checks after the policy changes.
      await pump(
        tester,
        chats: [grace()],
        settings: const SnapshotSettings(widgets: true),
      );
      expect(find.textContaining('otter'), findsNothing);

      await tester.tap(switchFor('Message previews'));
      await tester.pumpAndSettle();

      expect(find.text('the otter is loose'), findsOneWidget);
    });

    testWidgets('shows the top conversation a surface is allowed to show', (
      tester,
    ) async {
      // Not the top conversation full stop: a preview of an excluded chat would
      // be showing something that is never written, which is the opposite of
      // what this section is for.
      await pump(
        tester,
        chats: [
          snapshotChat(
            id: '!signal:example.org',
            title: 'Ines',
            networks: const [ChatNetwork.signal],
            lastMessage: snapshotMessage(body: 'excluded'),
          ),
          grace(),
        ],
        settings: const SnapshotSettings(
          widgets: true,
          includePreviews: true,
          includeSenderNames: true,
          excludedNetworks: {'signal'},
        ),
      );

      expect(find.text('Grace'), findsOneWidget);
      expect(find.text('Ines'), findsNothing);
      expect(
        find.textContaining('Your most recent conversation'),
        findsOneWidget,
      );
    });

    testWidgets('says it is an example when nothing qualifies', (tester) async {
      // Every network excluded. The fallback says so rather than quietly
      // presenting a fiction as the user's own data.
      await pump(
        tester,
        chats: [grace()],
        settings: const SnapshotSettings(
          widgets: true,
          includePreviews: true,
          includeSenderNames: true,
          excludedNetworks: {'whatsapp', 'signal'},
        ),
      );

      expect(find.textContaining('An example'), findsOneWidget);
      expect(find.text(en.surfacesExampleChatTitle), findsOneWidget);
      expect(find.text('Grace'), findsNothing);
    });

    testWidgets('the badge is capped where the payload caps it', (
      tester,
    ) async {
      // `99+` is formatted in Dart precisely so a Glance composable and a
      // SwiftUI view cannot disagree about it, and this card reads the same
      // field they do rather than re-deriving it.
      await pump(
        tester,
        chats: [grace(unreadCount: 120)],
        settings: const SnapshotSettings(widgets: true),
      );

      expect(find.text('99+'), findsOneWidget);
      expect(find.text('120'), findsNothing);
    });

    testWidgets('is one semantics node, read as a quotation', (tester) async {
      // The card is an illustration of another device's screen. A reader walking
      // it as three separate labels would have no way to tell it from the
      // settings around it.
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        chats: [grace()],
        settings: const SnapshotSettings(
          widgets: true,
          includePreviews: true,
          includeSenderNames: true,
        ),
      );

      final example = labelsIn(
        tester,
      ).where((label) => label.startsWith('Example widget row.')).toList();
      expect(example, hasLength(1));
      expect(example.single, contains('Grace'));
      expect(example.single, contains('the otter is loose'));
      expect(example.single, contains('3 unread'));
      handle.dispose();
    });
  });
}

/// The slice of [ChatRepository] this screen touches. Everything else throws: a
/// settings screen that started calling the rest of the repository should fail
/// loudly.
class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({
    this.chats = const [],
    this.networks = const [ChatNetwork.whatsapp, ChatNetwork.signal],
  });

  final List<Chat> chats;
  final List<ChatNetwork> networks;

  @override
  List<ChatNetwork> get availableNetworks => networks;

  @override
  Stream<List<Chat>> watchChats() => Stream.value(chats);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
