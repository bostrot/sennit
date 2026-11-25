import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_domain/weft_domain.dart';

import 'package:weft_store/weft_store.dart';
import '../../app/hidden_messages.dart';
import '../../app/localisation.dart';

import '../../app/settings.dart';
import '../../app/stores.dart';
import '../../app/text_size.dart';

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
    width: 460,
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

    // Scrolls: at twice the text size the sheet is taller than a phone.
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          // A phone's bottom sheet has a drag handle above this and needs no top
          // padding. A desktop panel has neither, and its heading was landing
          // flush against — and above — the panel's own top edge.
          padding: EdgeInsetsDirectional.fromSTEB(
            WeftSpace.xl,
            context.isDesktop ? WeftSpace.lg : 0,
            WeftSpace.xl,
            WeftSpace.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.commonAppearance,
                style: context.text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: context.isDesktop ? WeftSpace.lg : WeftSpace.xl),

              _SheetHeading('Theme'),
              const SizedBox(height: WeftSpace.sm),
              // Wrapped, and glyph-only where the labels do not fit. Four
              // labelled segments need about 460 points; in a 420-point panel
              // Flutter's answer is to break every label mid-word — "Au to",
              // "Lig ht", "A M OL ED" — which is worse than no label at all,
              // and each segment still carries its name as a tooltip.
              LayoutBuilder(
                builder: (context, constraints) {
                  final labelled = _themeLabelsFit(
                    context,
                    constraints.maxWidth,
                  );
                  return SegmentedButton<WeftThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final (mode, icon, label) in _themeSegments)
                        ButtonSegment(
                          value: mode,
                          icon: Icon(icon, size: context.isDesktop ? 15 : 18),
                          label: labelled ? Text(label) : null,
                          tooltip: label,
                        ),
                    ],
                    style: context.isDesktop
                        ? SegmentedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: WeftSpace.sm,
                              vertical: 4,
                            ),
                            textStyle: context.text.labelMedium,
                          )
                        : null,
                    selected: {appearance.mode},
                    onSelectionChanged: (s) => notifier.setMode(s.first),
                  );
                },
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
                title: Text(context.l10n.appearanceRailMultiSelectTitle),
                subtitle: Text(context.l10n.appearanceRailMultiSelectSubtitle),
                value: _railMultiSelect(ref),
                onChanged: (value) {
                  ref
                      .read(storesProvider)
                      .settings
                      .setBool(WeftSettings.railMultiSelect, value: value);
                  ref.read(settingsRevisionProvider.notifier).bump();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.appearanceHideDeletedTitle),
                subtitle: Text(context.l10n.appearanceHideDeletedSubtitle),
                value: ref.watch(hideDeletedMessagesProvider),
                onChanged: (value) {
                  ref
                      .read(storesProvider)
                      .settings
                      .setBool(WeftSettings.hideDeletedMessages, value: value);
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
              const SizedBox(height: WeftSpace.lg),
              const _TextSizeSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Text size and message text size, with a preview of both.
///
/// The sliders hold their value while they are dragged and store it on
/// release. Applied live, every step would re-lay-out the whole app behind
/// the sheet and the sheet itself, moving the slider out from under the
/// finger; the preview is what follows the drag instead.
class _TextSizeSection extends ConsumerStatefulWidget {
  const _TextSizeSection();

  @override
  ConsumerState<_TextSizeSection> createState() => _TextSizeSectionState();
}

class _TextSizeSectionState extends ConsumerState<_TextSizeSection> {
  double? _app;
  double? _message;

  @override
  Widget build(BuildContext context) {
    final double app = _app ?? ref.watch(textScaleProvider);
    final double message = _message ?? ref.watch(messageTextScaleProvider);
    final l10n = context.l10n;
    String percent(double value) =>
        l10n.appearanceTextSizePercent((value * 100).round());

    Widget slider({
      required String title,
      required double value,
      required ValueChanged<double> onChanged,
      required ValueChanged<double> onChangeEnd,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _SheetHeading(title)),
              Text(percent(value), style: context.text.labelLarge),
            ],
          ),
          Slider(
            value: value,
            min: kTextScaleMin,
            max: kTextScaleMax,
            divisions: kTextScaleDivisions,
            label: percent(value),
            semanticFormatterCallback: percent,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        slider(
          title: l10n.appearanceTextSize,
          value: app,
          onChanged: (v) => setState(() => _app = v),
          onChangeEnd: (v) {
            writeTextScale(ref, WeftSettings.textScale, v);
            setState(() => _app = null);
          },
        ),
        slider(
          title: l10n.appearanceMessageTextSize,
          value: message,
          onChanged: (v) => setState(() => _message = v),
          onChangeEnd: (v) {
            writeTextScale(ref, WeftSettings.messageTextScale, v);
            setState(() => _message = null);
          },
        ),
        Text(
          l10n.appearanceTextSizeHint,
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: WeftSpace.md),
        TextSizePreview(app: app, message: message),
      ],
    );
  }
}

/// An inbox row and two bubbles, drawn at [app] × [message] of the system's
/// text size whatever the app is set to now.
///
/// Public for the golden tests, which photograph it at the sizes it offers.
class TextSizePreview extends StatelessWidget {
  const TextSizePreview({super.key, required this.app, required this.message});

  final double app;
  final double message;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    var system = MediaQuery.textScalerOf(context);
    // The sheet is already drawn at the stored size; the preview starts from
    // the phone's own and applies the slider's, so it shows the value being
    // dragged rather than that times the old one.
    if (system is MultipliedTextScaler) system = system.base;
    final at = DateTime(2026, 11, 22, 9, 41);
    final chat = Chat(
      id: 'preview',
      title: l10n.appearanceTextSizePreviewChat,
      sources: const [
        ChatSource(roomId: '!preview', network: ChatNetwork.signal),
      ],
      unreadCount: 1,
      lastMessage: WeftMessage(
        eventId: r'$preview',
        roomId: '!preview',
        network: ChatNetwork.signal,
        senderId: '@preview',
        senderName: l10n.appearanceTextSizePreviewChat,
        timestamp: at,
        kind: MessageKind.text,
        isOwn: false,
        body: l10n.appearanceTextSizePreviewIncoming,
      ),
    );

    Widget bubble(String text, {required bool own}) {
      return Align(
        alignment: own
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(
            horizontal: WeftSpace.md,
            vertical: WeftSpace.sm,
          ),
          decoration: BoxDecoration(
            color: own ? palette.ownBubble : palette.peerBubble,
            borderRadius: BorderRadius.circular(18),
          ),
          child: scaleText(
            context,
            message,
            Text(
              text,
              style: context.text.bodyMedium?.copyWith(
                color: own ? palette.ownBubbleText : palette.peerBubbleText,
              ),
            ),
          ),
        ),
      );
    }

    // Seen, not read out: it repeats the sliders' value in made-up words. Its
    // own layer, because it repaints on every step of a drag and the sheet
    // around it does not.
    return RepaintBoundary(
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: MultipliedTextScaler(system, app)),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.colors.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ChatTile(
                    chat: chat,
                    onTap: () {},
                    timeLabel: DateFormat.Hm().format(at),
                  ),
                  Divider(height: 1, color: context.colors.outlineVariant),
                  Padding(
                    padding: const EdgeInsets.all(WeftSpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        bubble(
                          l10n.appearanceTextSizePreviewIncoming,
                          own: false,
                        ),
                        bubble(
                          l10n.appearanceTextSizePreviewOutgoing,
                          own: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _themeSegments = [
  (WeftThemeMode.system, Icons.brightness_auto_rounded, 'Auto'),
  (WeftThemeMode.light, Icons.light_mode_rounded, 'Light'),
  (WeftThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
  (WeftThemeMode.amoled, Icons.contrast_rounded, 'AMOLED'),
];

/// Whether every theme segment's label fits on one line in [width] at the
/// current text size: the icon, the gap after it, the label and the padding,
/// four times over.
bool _themeLabelsFit(BuildContext context, double width) {
  final style = context.isDesktop
      ? context.text.labelMedium
      : context.text.labelLarge;
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final (_, _, label) in _themeSegments) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  final icon = context.isDesktop ? 15.0 : 18.0;
  final padding = context.isDesktop ? 2 * WeftSpace.sm : 2 * 24.0;
  // The icon's own gap is 8 in Material's segmented button, plus a hairline
  // border between segments.
  final segment = padding + icon + 8 + widest + 1;
  return segment * _themeSegments.length <= width;
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
      label: context.l10n.appearanceAccentSwatch(name),
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
        // A thumb's target on a phone, a pointer's on a desktop — six
        // swatches then fit on one row instead of five and an orphan.
        width: context.isDesktop ? 30 : kWeftMinTapTarget,
        height: context.isDesktop ? 30 : kWeftMinTapTarget,
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
