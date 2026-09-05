import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';

/// One way to put a screen on the glass for the accessibility suites.
///
/// The suites in `test/a11y/` all ask the same question of six screens, and the
/// question is only meaningful if every screen is pumped the same way — a
/// guideline sweep that ran against one screen at 1400×900 and another at the
/// default 800×600 would be reporting on the window as much as on the widget.
/// The two seams below are what the screens actually need to build without a
/// homeserver: what is in the rooms, and what the settings say.
///
/// [textScale] is the third, and it is why `text_scale_test.dart` measures the
/// real screens rather than a rebuilt copy of the box under test: the fixed
/// boxes in the text-scale register are all private widgets inside a feature,
/// reachable only by pumping the screen that owns them.
///
/// Deliberately *not* `pumpWeft` from `golden_harness.dart`. That one exists to
/// make a deterministic image — it loads fonts, settles animations and forces a
/// theme — and it returns nothing, whereas these tests need the container to
/// read a provider back afterwards.
///
/// The seams are named parameters rather than a general overrides list for the
/// same reason the golden harness gives: Riverpod's `Override` is not exported
/// from either barrel, so a typed `List<Override>` parameter cannot be written
/// at all — the container's own list only type-checks by inference.
Future<ProviderContainer> pumpScreen(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(1400, 900),
  ChatRepository? repository,
  WeftStores? stores,
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      if (repository != null)
        chatRepositoryProvider.overrideWithValue(repository),
      // Both faces of the same store. `storesProvider` is the synchronous one
      // and throws while the bootstrap future is pending, so a screen that
      // reads settings during its first build — search and every settings
      // screen do — needs the value override as well as the future.
      if (stores != null) ...[
        storesProvider.overrideWithValue(stores),
        storesBootstrapProvider.overrideWith((ref) async => stores),
      ],
    ],
  );
  addTearDown(container.dispose);
  if (stores != null) await container.read(storesBootstrapProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // The app's own delegates, because the screens under test read their
        // words from `context.l10n` and `AppL10n` is only in the tree if its
        // delegate put it there. Without these, a settings screen throws in
        // `build` and the suite reports an accessibility failure for what is
        // really a harness that is not the app.
        localizationsDelegates: weftLocalizationsDelegates,
        supportedLocales: weftSupportedLocales,
        theme: WeftTheme.build(brightness: brightness),
        // The scaler goes in the app's `builder`, not in a `MediaQuery` above
        // `MaterialApp`: `MediaQuery.fromView` rebuilds the data from the view
        // and would drop anything set over it. Same placement the golden
        // harness uses, for the same reason.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
