import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft_design/weft_design.dart';

import 'support/golden_harness.dart';

/// A Mac window has no title bar: its close, minimise and zoom buttons float
/// over the top-left corner of whatever the app draws there. These pin what a
/// screen pushed over the whole window owes them, and the composer's size.
void main() {
  setUpAll(loadGoldenFonts);

  /// A first route with a button that pushes [screen], so it is a pushed
  /// route the way search and a notification open one.
  Widget launcher(Widget screen) => Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => screen)),
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, Widget screen) async {
    await pumpWeft(
      tester,
      launcher(screen),
      size: const Size(1280, 800),
      surface: WeftSurface.mac,
      stores: WeftStores.inMemory(),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a conversation opened over the window has a way back', (
    tester,
  ) async {
    await open(tester, const ChatView(chatId: 'merged:anna'));

    final back = find.byTooltip('Back');
    expect(back, findsOneWidget);
    // Clear of the traffic lights, not under them.
    expect(
      tester.getTopLeft(back).dx,
      greaterThanOrEqualTo(MacMetrics.trafficLightInset),
    );
    // And so is the face beside the name, which the lights used to cover.
    final avatar = find.byType(WeftAvatar).first;
    expect(
      tester.getTopLeft(avatar).dx,
      greaterThan(tester.getTopRight(back).dx),
    );

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byType(ChatView), findsNothing);
  });

  testWidgets('a conversation in the shell has no back button', (tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'merged:anna'),
      size: const Size(1280, 800),
      surface: WeftSurface.mac,
      stores: WeftStores.inMemory(),
    );
    expect(find.byTooltip('Back'), findsNothing);
  });

  testWidgets('Escape closes search', (tester) async {
    await open(tester, const SearchScreen());
    expect(find.byType(SearchScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsNothing);
  });

  testWidgets('the composer is a comfortable line tall', (tester) async {
    await pumpWeft(
      tester,
      const ChatView(chatId: 'merged:anna'),
      size: const Size(1280, 800),
      surface: WeftSurface.mac,
      stores: WeftStores.inMemory(),
    );
    final field = find.byType(TextField).last;
    expect(tester.getSize(field).height, greaterThanOrEqualTo(34));

    // Every control beside it sits on the same line as its text.
    final fieldCentre = tester.getCenter(field).dy;
    for (final tooltip in ['Attach', 'Record voice message']) {
      final control = find.byTooltip(tooltip);
      if (control.evaluate().isEmpty) continue;
      expect(
        tester.getCenter(control.first).dy,
        moreOrLessEquals(fieldCentre, epsilon: 1),
        reason: '$tooltip is not level with the field',
      );
    }
  });

  testWidgets('search results by name do not draw over one another', (
    tester,
  ) async {
    await pumpWeft(
      tester,
      const SearchScreen(initialQuery: 'a'),
      size: const Size(1280, 800),
      surface: WeftSurface.mac,
      stores: WeftStores.inMemory(),
    );
    final tiles = find.ancestor(
      of: find.byType(WeftAvatar),
      matching: find.byType(ListTile),
    );
    expect(tiles, findsAtLeastNWidgets(2));
    for (final tile in tiles.evaluate()) {
      final box = tester.getRect(find.byWidget(tile.widget));
      final avatar = tester.getRect(
        find.descendant(
          of: find.byWidget(tile.widget),
          matching: find.byType(WeftAvatar),
        ),
      );
      expect(avatar.top, greaterThanOrEqualTo(box.top));
      expect(avatar.bottom, lessThanOrEqualTo(box.bottom));
    }
  });
}
