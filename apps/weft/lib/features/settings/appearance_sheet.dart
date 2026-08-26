import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft_store/weft_store.dart';

import '../../app/settings.dart';
import '../../app/stores.dart';

/// Live theme controls: mode, accent and density.
///
/// Everything applies instantly — picking a theme you then have to confirm is
/// a needless step when the whole app is visible behind the sheet.
///
/// [anchorContext] is the control this was opened from, where there is one. On
/// a Mac that turns the panel into a popover hanging off that button, which is
/// what the system does for a short set of live controls — and it keeps the
/// window visible behind it, which is the whole point of applying instantly.
Future<void> showAppearanceSheet(
  BuildContext context, {
  BuildContext? anchorContext,
}) {
  return showWeftPanel<void>(
    context: context,
    anchorContext: anchorContext,
    showDragHandle: true,
    isScrollControlled: true,
    width: 340,
    builder: (_) => const _AppearanceSheet(),
  );
}

class _AppearanceSheet extends ConsumerWidget {
  const _AppearanceSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    ref.watch(settingsRevisionProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Appearance',
              style: context.text.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: WeftSpace.xl),

            _SheetHeading('Theme'),
            const SizedBox(height: WeftSpace.sm),
            SegmentedButton<WeftThemeMode>(
              segments: const [
                ButtonSegment(
                  value: WeftThemeMode.system,
                  icon: Icon(Icons.brightness_auto_rounded, size: 18),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: WeftThemeMode.light,
                  icon: Icon(Icons.light_mode_rounded, size: 18),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: WeftThemeMode.dark,
                  icon: Icon(Icons.dark_mode_rounded, size: 18),
                  label: Text('Dark'),
                ),
                ButtonSegment(
                  value: WeftThemeMode.amoled,
                  icon: Icon(Icons.contrast_rounded, size: 18),
                  label: Text('AMOLED'),
                ),
              ],
              selected: {appearance.mode},
              onSelectionChanged: (s) => notifier.setMode(s.first),
            ),
            const SizedBox(height: WeftSpace.xl),

            _SheetHeading('Accent'),
            const SizedBox(height: WeftSpace.md),
            Wrap(
              spacing: WeftSpace.md,
              runSpacing: WeftSpace.md,
              children: [
                for (final preset in weftAccentPresets)
                  _SwatchButton(
                    color: preset.color,
                    name: preset.name,
                    selected:
                        preset.color.toARGB32() == appearance.seed.toARGB32(),
                    onTap: () => notifier.setSeed(preset.color),
                  ),
              ],
            ),
            const SizedBox(height: WeftSpace.xl),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Select several networks at once'),
              subtitle: const Text('Off: the rail is one-network-at-a-time.'),
              value: _railMultiSelect(ref),
              onChanged: (value) {
                ref
                    .read(storesProvider)
                    .settings
                    .setBool(WeftSettings.railMultiSelect, value: value);
                ref.read(settingsRevisionProvider.notifier).bump();
              },
            ),
            const SizedBox(height: WeftSpace.lg),

            _SheetHeading('Density'),
            Slider(
              value: appearance.densityScale,
              min: -2,
              max: 2,
              divisions: 4,
              label: _densityLabel(appearance.densityScale),
              // Without this a reader hears "minus two" through "two", which
              // are not the units the setting is in — the human words exist
              // already and lived only in the visual value indicator, the one
              // place a reader cannot go.
              semanticFormatterCallback: _densityLabel,
              onChanged: notifier.setDensity,
            ),
          ],
        ),
      ),
    );
  }
}

/// The three words the density slider is actually in.
String _densityLabel(double scale) => switch (scale) {
  <= -1 => 'Compact',
  >= 1 => 'Comfortable',
  _ => 'Default',
};

/// A group label inside the sheet, reachable by heading navigation.
///
/// "Theme", "Accent" and "Density" are what divide this sheet into its three
/// settings, and as bold runs of body text they divided it for one kind of user
/// only.
class _SheetHeading extends StatelessWidget {
  const _SheetHeading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(title, style: context.text.labelLarge),
    );
  }
}

bool _railMultiSelect(WidgetRef ref) {
  try {
    return ref
        .watch(storesProvider)
        .settings
        .getBool(WeftSettings.railMultiSelect);
  } on StateError {
    return false;
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return WeftFocusable(
      selected: selected,
      label: '$name accent',
      onTap: onTap,
      // Round, so no corner radius describes it — and the ring goes outside
      // the swatch rather than over it, because a ring drawn on top of a
      // saturated accent is measured against the wrong colour.
      shape: BoxShape.circle,
      // 48 rather than 44: the swatches sit in a `Wrap` with room to spare, so
      // the guideline is met by making the control the size it should be
      // instead of padding a smaller one out to it.
      child: AnimatedContainer(
        duration: context.motion.fast,
        curve: context.motion.spring,
        width: kWeftMinTapTarget,
        height: kWeftMinTapTarget,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? context.colors.onSurface : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected ? WeftShadow.glow(color) : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}
