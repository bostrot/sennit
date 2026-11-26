import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/nickname_providers.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft/features/contact/nickname_dialog.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_sync/weft_sync.dart' show SyncPolicy;

import 'support/attachment_fixtures.dart';

/// The user's own name and picture for a chat: private, kept per room, and
/// carried to their other devices by settings sync.
void main() {
  /// One person on two networks, merged into one chat.
  const merged = Chat(
    id: 'merged:grace',
    title: 'Grace Hopper',
    sources: [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
      ChatSource(roomId: '!wa:example.org', network: ChatNetwork.whatsapp),
    ],
  );

  /// The same person on one device that has not merged the two.
  const signalOnly = Chat(
    id: '!signal:example.org',
    title: 'Grace H.',
    sources: [
      ChatSource(roomId: '!signal:example.org', network: ChatNetwork.signal),
    ],
  );

  group('ChatNicknames', () {
    test('reads names and photos out of settings rows', () {
      final nicknames = ChatNicknames.fromSettings({
        '${ChatNicknames.namePrefix}!signal:example.org': 'Amazing Grace',
        '${ChatNicknames.photoPrefix}!wa:example.org': 'data:image/png;base64,',
        '${ChatNicknames.namePrefix}!empty:example.org': '',
        'inbox.something_else': 'x',
      });

      expect(nicknames.names, {'!signal:example.org': 'Amazing Grace'});
      expect(nicknames.photos.keys, ['!wa:example.org']);
    });

    test('a merged chat takes the nickname of any of its rooms', () {
      final nicknames = ChatNicknames.fromSettings({
        '${ChatNicknames.namePrefix}!wa:example.org': 'Amazing Grace',
      });

      final shown = nicknames.apply(merged);
      expect(shown.title, 'Amazing Grace');
      expect(shown.id, merged.id);
      expect(nicknames.apply(signalOnly).title, 'Grace H.');
    });

    test('leaves chats without one untouched', () {
      const nicknames = ChatNicknames();
      expect(nicknames.isEmpty, isTrue);
      expect(identical(nicknames.apply(merged), merged), isTrue);
    });

    test('lives under settings that sync between devices', () {
      expect(
        SyncPolicy.syncsSetting('${ChatNicknames.namePrefix}!a:example.org'),
        isTrue,
      );
      expect(
        SyncPolicy.syncsSetting('${ChatNicknames.photoPrefix}!a:example.org'),
        isTrue,
      );
    });
  });

  group('on a contact', () {
    late WeftStores stores;
    late StubChatRepository repository;

    setUp(() {
      stores = WeftStores.inMemory();
      repository = StubChatRepository();
      weftAvatarImageOverride = (_) => MemoryImage(kPixel);
    });

    tearDown(() {
      weftAvatarImageOverride = null;
      repository.dispose();
      stores.dispose();
    });

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storesProvider.overrideWithValue(stores),
            chatRepositoryProvider.overrideWithValue(repository),
            chatsProvider.overrideWith((ref) {
              final nicknames = ref.watch(chatNicknamesProvider);
              return Stream.value(nicknames.applyTo([merged]));
            }),
          ],
          child: MaterialApp(
            localizationsDelegates: weftLocalizationsDelegates,
            supportedLocales: weftSupportedLocales,
            theme: WeftTheme.build(),
            home: ContactProfileScreen(chatId: merged.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(ContactProfileScreen)),
      );
    }

    Future<void> openDialog(WidgetTester tester) async {
      // In the profile's Chat settings group, closed until opened.
      final group = find.text('Chat settings');
      await tester.scrollUntilVisible(group, 200);
      await tester.tap(group);
      await tester.pumpAndSettle();
      final tile = find.text('Nickname and photo');
      await tester.scrollUntilVisible(tile, 200);
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }

    testWidgets('a nickname is written under every room and shown', (
      tester,
    ) async {
      final container = await pump(tester);
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), '  Amazing Grace ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      for (final room in merged.roomIds) {
        expect(
          stores.settings.getString('${ChatNicknames.namePrefix}$room'),
          'Amazing Grace',
        );
      }
      expect(container.read(chatNicknamesProvider).nameFor(merged), isNotNull);
      // The name at the top of the profile, scrolled away to reach the row.
      await tester.scrollUntilVisible(find.text('Amazing Grace'), -200);
      expect(find.text('Amazing Grace'), findsOneWidget);
    });

    testWidgets('clearing the field brings the network name back', (
      tester,
    ) async {
      for (final room in merged.roomIds) {
        stores.settings.setString(
          '${ChatNicknames.namePrefix}$room',
          'Amazing Grace',
        );
      }
      await pump(tester);
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      for (final room in merged.roomIds) {
        expect(
          stores.settings.getString('${ChatNicknames.namePrefix}$room'),
          isNull,
        );
      }
      await tester.scrollUntilVisible(find.text('Grace Hopper'), -200);
      expect(find.text('Grace Hopper'), findsOneWidget);
    });

    testWidgets('a photo of their own can be removed again', (tester) async {
      final photo = 'data:image/png;base64,${base64Encode(kPixel)}';
      for (final room in merged.roomIds) {
        stores.settings.setString('${ChatNicknames.photoPrefix}$room', photo);
      }
      await pump(tester);
      await openDialog(tester);

      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      expect(find.text('Remove photo'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      for (final room in merged.roomIds) {
        expect(
          stores.settings.getString('${ChatNicknames.photoPrefix}$room'),
          isNull,
        );
      }
    });
  });

  testWidgets('a chosen picture is stored as a small square PNG', (
    tester,
  ) async {
    final uri = await tester.runAsync(() => avatarDataUri(kPixel));
    expect(uri, startsWith('data:image/png;base64,'));
    final undecodable = await tester.runAsync(
      () => avatarDataUri(Uint8List.fromList([1, 2, 3])),
    );
    expect(undecodable, isNull);
  });
}
