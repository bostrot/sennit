import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/contact/chat_sound_tile.dart';
import 'package:weft/services/notifications/chat_sound_settings.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_notify/weft_notify.dart';
import 'package:weft_store/weft_store.dart';

void main() {
  const chat = Chat(
    id: '!grace:example.org',
    title: 'Grace',
    sources: [
      ChatSource(roomId: '!grace:example.org', network: ChatNetwork.signal),
    ],
  );

  Future<WeftStores> pump(WidgetTester tester) async {
    final stores = WeftStores.inMemory();
    addTearDown(stores.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storesProvider.overrideWithValue(stores)],
        child: MaterialApp(
          localizationsDelegates: weftLocalizationsDelegates,
          supportedLocales: weftSupportedLocales,
          theme: WeftTheme.build(),
          home: const Scaffold(body: ChatSoundTile(chat: chat)),
        ),
      ),
    );
    return stores;
  }

  NotificationPolicy persisted(WeftStores stores) =>
      NotificationPolicy.fromJson(
        stores.settings.getJson(WeftSettings.notifyPolicy),
      );

  testWidgets('a chat can be set to silent and back', (tester) async {
    final stores = await pump(tester);
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.text('Notification sound'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Silent').last);
    await tester.pumpAndSettle();

    expect(persisted(stores).overrideFor(chat.id).silent, isTrue);
    // The row behind the sheet follows.
    expect(find.text('Silent'), findsNWidgets(2));

    await tester.tap(find.text('Default').last);
    await tester.pumpAndSettle();
    expect(persisted(stores).overrideFor(chat.id).silent, isFalse);
    // Back to nothing at all, rather than an entry saying nothing.
    expect(persisted(stores).chats, isEmpty);
  });

  testWidgets('choosing a sound is offered only where the system keeps one', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(tester);
    await tester.tap(find.text('Notification sound'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a sound'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on Android, choosing a sound opens this conversation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('com.bostrot.weft/intents');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    expect(canChooseChatSound, isTrue);
    await pump(tester);
    await tester.tap(find.text('Notification sound'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a sound'));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'openConversationNotificationSettings');
    expect(calls.single.arguments, {
      'channelId': 'weft.messages.signal',
      'shortcutId': isNotEmpty,
    });
    debugDefaultTargetPlatformOverride = null;
  });
}
