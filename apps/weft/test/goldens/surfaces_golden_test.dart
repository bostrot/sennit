import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/stores.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/settings/surfaces_screen.dart';
import 'package:weft/services/snapshot/snapshot_writer.dart';

import '../support/golden_harness.dart';

/// Goldens for the companion-surfaces gate built in Phase 10.
///
/// `surfaces_screen_test.dart` already pins the round trip — a switch moves, the
/// blob in the store changes, the writer hears about it — and none of it can see
/// what this screen is actually judged on. This is the screen where a person
/// decides whether their conversations may leave the encrypted store, and that
/// decision is made from a *picture*: a red warning box that has to read as a
/// warning before the switch beside it is touched, and a preview card that has
/// to read as another device's screen rather than as more settings. Both are
/// claims about ink and spacing, and an assertion that a string is on screen is
/// true of a layout where the warning is grey and below the fold.
///
/// **Two states, not one.** Off is what every install is in and the only frame
/// most users will ever see; on is where the four sections the gate hides behind
/// `anySurface` appear at once, including the live row. They are different
/// screens rather than the same screen with more of it, so a single image would
/// leave whichever one it was not.
///
/// **The variants are the ones Phase 08 pinned**, applied to the on state only:
/// off is three widgets and has nowhere to clip, while on is a warning
/// paragraph, four switch tiles whose titles wrap, seven network rows and a card
/// with a fixed-size avatar next to text that grows — which is where 2.0× and
/// Arabic actually have something to break. The right-to-left words draw as
/// placeholder boxes for the reason `a11y_golden_test.dart` gives: the SDK's
/// Roboto has no Arabic coverage, and the claim being made is about the
/// *arrangement* — a switch that stayed on the physical right, a preview card
/// whose avatar did not move to the trailing edge.
void main() {
  setUpAll(loadGoldenFonts);

  /// One window per state, held constant across the variants, so the variant is
  /// the only thing that differs between two images.
  ///
  /// Phone-width rather than the pane widths the app screens use: this is a
  /// settings screen reached from a rail, and its hardest line-breaking case is
  /// the narrow one. The on-state height fits the whole list at 1.0× — the
  /// preview card is the last thing in it and the point of the image — and
  /// leaves 2.0× somewhere to fail.
  const offWindow = Size(620, 420);
  const onWindow = Size(620, 1320);

  late DemoChatRepository demo;

  setUp(() => demo = DemoChatRepository(uploadTick: Duration.zero));
  tearDown(() => demo.dispose());

  /// The gate as a user who has opted all the way in would have left it.
  ///
  /// Discord is excluded rather than one of the networks the demo inbox
  /// actually carries: an exclusion that changed which conversation the preview
  /// showed would make the image a picture of two decisions at once. What it
  /// pins instead is that an excluded row and an allowed row are told apart by
  /// something other than the switch's own colour.
  const enabled = SnapshotSettings(
    widgets: true,
    watch: true,
    includePreviews: true,
    includeSenderNames: true,
    excludedNetworks: {'discord'},
  );

  /// Captures the screen in both themes under [variant].
  ///
  /// The settings are written into a real [WeftStores] rather than pushed
  /// through a provider override, because that is the only path the screen
  /// itself reads: `snapshotSettingsProvider` rebuilds from the store, so a
  /// golden that overrode the provider would be an image of a state the app
  /// cannot be launched into.
  Future<void> expectSurfacesGolden(
    WidgetTester tester,
    String state, {
    required SnapshotSettings settings,
    required Size size,
    WeftGoldenVariant variant = weftGoldenBaseline,
  }) async {
    for (final (mode, suffix) in const [
      (WeftThemeMode.dark, 'dark'),
      (WeftThemeMode.light, 'light'),
    ]) {
      final stores = WeftStores.inMemory();
      addTearDown(stores.dispose);
      settings.writeTo(stores.settings);

      // Keyed for the reason the accessibility goldens are: without it the
      // second `pumpWidget` reuses the first run's element, so the light image
      // would be taken against the dark run's scroll offset.
      await pumpWeft(
        tester,
        SurfacesScreen(key: ValueKey('${variant.name}_$suffix')),
        size: size,
        mode: mode,
        variant: variant,
        repository: demo,
        stores: stores,
      );

      await expectLater(
        find.byType(SurfacesScreen),
        matchesGoldenFile('surfaces_${state}_${variant.name}_$suffix.png'),
      );
    }
  }

  testWidgets('switched off, both themes', (tester) async {
    // The frame every install opens on. Nothing is written in this state, and
    // the screen has to say so before it offers the switch that changes it —
    // which is why the notice is above both tiles rather than beside them, and
    // why the four sections below are absent rather than greyed out. A disabled
    // control still tells you what it would disclose.
    await expectSurfacesGolden(
      tester,
      'off',
      settings: SnapshotSettings.off,
      size: offWindow,
    );
  });

  testWidgets('every surface and every disclosure on, both themes', (
    tester,
  ) async {
    // The whole gate open: both surfaces, both content switches, the network
    // list, and the live row built by `buildSnapshotRow` from the demo inbox's
    // top conversation — a merged chat, so the card carries three network dots
    // and an unread badge and is the one place the user can see what those
    // become on a home screen.
    await expectSurfacesGolden(tester, 'on', settings: enabled, size: onWindow);
  });

  group('on, under the accessibility variants', () {
    for (final variant in weftAccessibilityVariants) {
      testWidgets(variant.name, (tester) async {
        await expectSurfacesGolden(
          tester,
          'on',
          settings: enabled,
          size: onWindow,
          variant: variant,
        );
      });
    }
  });
}
