import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import 'stores.dart';

/// The steps the text size sliders move in: 80 % to 160 % of what the system
/// asks for, in tens.
const double kTextScaleMin = 0.8;
const double kTextScaleMax = 1.6;
const int kTextScaleDivisions = 8;

/// Sennit's text size, as a factor on top of the system's. 1.0 until the user
/// moves the slider, which is what "follow the phone" means.
final textScaleProvider = Provider<double>((ref) {
  ref.watch(settingsRevisionProvider);
  return _read(storesOrNull(ref), WeftSettings.textScale);
});

/// Message text's own factor, on top of [textScaleProvider].
final messageTextScaleProvider = Provider<double>((ref) {
  ref.watch(settingsRevisionProvider);
  return _read(storesOrNull(ref), WeftSettings.messageTextScale);
});

double _read(WeftStores? stores, String key) {
  final value = stores?.settings.getDouble(key);
  // A value from a newer build, or typed into a synced document by hand, is
  // held to the slider's range rather than trusted: 0 would make every word
  // in the app vanish.
  if (value == null || !value.isFinite) return 1.0;
  return value.clamp(kTextScaleMin, kTextScaleMax);
}

/// Stores [key]'s factor and tells everything derived from settings — the
/// app root, and device sync — that it changed.
void writeTextScale(WidgetRef ref, String key, double value) {
  ref.read(storesProvider).settings.setDouble(key, value);
  ref.read(settingsRevisionProvider.notifier).bump();
}

/// [base] — the system's scaler, linear or not — multiplied by [factor].
///
/// Multiplied rather than replaced, so Android 14's non-linear scaling (big
/// headings grow less than body text) survives, and 100 % is exactly the
/// system's answer rather than an approximation of it.
@immutable
class MultipliedTextScaler extends TextScaler {
  const MultipliedTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is MultipliedTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

/// [child] with the ambient text scaler multiplied by [factor].
///
/// Wrapped even at 1.0: at the app root a `MediaQuery` that came and went with
/// the slider would change the tree's shape and throw away the state of
/// everything below it — the open chat, the scroll position, the sheet the
/// slider is in.
Widget scaleText(BuildContext context, double factor, Widget child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: MultipliedTextScaler(
        MediaQuery.textScalerOf(context),
        factor,
      ),
    ),
    child: child,
  );
}

/// Applies Sennit's text size to everything below it. The app root's.
class AppTextScale extends ConsumerWidget {
  const AppTextScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      scaleText(context, ref.watch(textScaleProvider), child);
}

/// Applies the message text size to the words of a message.
class MessageTextScale extends ConsumerWidget {
  const MessageTextScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      scaleText(context, ref.watch(messageTextScaleProvider), child);
}
