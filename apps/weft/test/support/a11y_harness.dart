import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

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
        theme: WeftTheme.build(brightness: brightness),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
