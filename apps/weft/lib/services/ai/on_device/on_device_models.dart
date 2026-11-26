import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/model_catalog.dart';

/// The base URL the AI settings store for the "On this phone" provider.
///
/// Every AI feature reads one base URL and posts OpenAI-style chat
/// completions to it, so the on-device model is given one too: `.invalid` is
/// reserved and never resolves, and [llmHttpClient] answers this host itself
/// from the model on the phone instead of sending anything anywhere.
const String kOnDeviceLlmBaseUrl = 'http://on-device.invalid/v1';

/// The host of [kOnDeviceLlmBaseUrl].
const String kOnDeviceLlmHost = 'on-device.invalid';

/// Whether [baseUrl] is the on-device provider's.
bool isOnDeviceLlm(String? baseUrl) =>
    Uri.tryParse((baseUrl ?? '').trim())?.host.toLowerCase() ==
    kOnDeviceLlmHost;

/// Whether this build can run a model on the device at all.
///
/// Android and iOS, the point of the feature, and macOS on Apple silicon,
/// where the same llama.cpp runtime comes for free with Metal. Windows and
/// Linux bundle no runtime (see `hooks.user_defines` in the workspace
/// pubspec) and keep the server providers only; so does the web. On iOS the
/// runtime is built for 16.4 and later, newer than the app's own floor, so
/// an older iPhone keeps the server too.
bool get onDeviceLlmSupported {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => true,
    TargetPlatform.iOS => iosRunsOnDeviceLlm(_osVersion),
    TargetPlatform.macOS => !_isIntelMac,
    _ => false,
  };
}

/// Whether an iOS whose `Platform.operatingSystemVersion` is [version] can
/// load the llama.cpp framework: 16.4 or later. An unreadable version is
/// given the benefit of the doubt — a failed load is reported, not a crash.
@visibleForTesting
bool iosRunsOnDeviceLlm(String version) {
  final match = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
  if (match == null) return true;
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  return major > 16 || (major == 16 && minor >= 4);
}

String get _osVersion {
  try {
    return Platform.isIOS ? Platform.operatingSystemVersion : '';
  } on Object {
    return '';
  }
}

bool get _isIntelMac {
  try {
    return Platform.isMacOS && !Platform.version.contains('arm64');
  } on Object {
    return false;
  }
}

/// What the on-device provider needs to know about a model beyond its files.
class OnDeviceLlmSpec {
  const OnDeviceLlmSpec({
    required this.model,
    required this.kvBytesPerToken,
    required this.recommendedRamBytes,
    required this.minimumRamBytes,
    required this.maxContextTokens,
  });

  final ModelSpec model;

  /// What one token of context costs in the KV cache at f16: layers with
  /// attention × KV heads × head size × 2 (K and V) × 2 bytes.
  final int kvBytesPerToken;

  /// Memory below which the model runs but the phone has little to spare:
  /// the settings warn.
  final int recommendedRamBytes;

  /// Memory below which the system is likely to close Sennit while the model
  /// is loaded: the settings warn louder and suggest the smaller model.
  final int minimumRamBytes;

  /// The longest context the model was trained for.
  final int maxContextTokens;

  String get id => model.id;

  /// The model file's size on disk, which is about what it takes in memory.
  int get weightBytes => model.totalBytes;

  static const OnDeviceLlmSpec bonsai8b = OnDeviceLlmSpec(
    model: ModelCatalog.bonsai8b,
    // Qwen3-8B: 36 layers, 8 KV heads of 128.
    kvBytesPerToken: 36 * 8 * 128 * 2 * 2,
    recommendedRamBytes: 8 * _gib,
    minimumRamBytes: 6 * _gib,
    maxContextTokens: 65536,
  );

  static const OnDeviceLlmSpec ternaryBonsai2b = OnDeviceLlmSpec(
    model: ModelCatalog.ternaryBonsai2b,
    // Qwen3.5-2B: only every fourth of its 24 layers has attention — 6, with
    // 2 KV heads of 256; the others keep a fixed-size recurrent state.
    kvBytesPerToken: 6 * 2 * 256 * 2 * 2,
    recommendedRamBytes: 4 * _gib,
    minimumRamBytes: 3 * _gib,
    maxContextTokens: 262144,
  );

  static const List<OnDeviceLlmSpec> all = [bonsai8b, ternaryBonsai2b];

  static OnDeviceLlmSpec? byId(String? id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}

const int _gib = 1024 * 1024 * 1024;

/// The context the on-device model runs with when the user has set none.
///
/// A phone's CPU reads a prompt at tens of tokens a second, not thousands, so
/// a big window is mostly a slow one; 4096 holds every feature's prompt with
/// room for its answer.
const int kOnDeviceDefaultContextTokens = 4096;

/// The smallest context worth loading the model for.
const int kOnDeviceMinContextTokens = 1024;

/// The longest answer an on-device feature asks for when the user has set
/// none: a quick message or a reply, not an essay.
const int kOnDeviceAnswerTokens = 1024;

/// How the phone's memory compares with what [OnDeviceLlmSpec] needs.
enum OnDeviceRamFit {
  /// Comfortably enough.
  fits,

  /// Enough to run, little to spare.
  tight,

  /// Likely too little: the system may close the app while the model runs.
  tooLittle,

  /// The memory could not be read.
  unknown,
}

OnDeviceRamFit ramFitFor(OnDeviceLlmSpec spec, int? ramBytes) {
  if (ramBytes == null || ramBytes <= 0) return OnDeviceRamFit.unknown;
  if (ramBytes < spec.minimumRamBytes) return OnDeviceRamFit.tooLittle;
  if (ramBytes < spec.recommendedRamBytes) return OnDeviceRamFit.tight;
  return OnDeviceRamFit.fits;
}

/// The largest context [spec] may have on a device with [ramBytes] of memory.
///
/// An app gets about half of a phone's memory before the system starts
/// closing it, and Sennit itself needs some of that; so the model may have
/// 40 % of it, of which the weights and llama.cpp's working buffers come
/// first and the KV cache gets what is left. Rounded down to 512, never
/// below [kOnDeviceMinContextTokens] nor above 16384 or what the model was
/// trained for. Unknown memory is treated as 4 GB.
int onDeviceContextCap(OnDeviceLlmSpec spec, int? ramBytes) {
  final ram = (ramBytes == null || ramBytes <= 0) ? 4 * _gib : ramBytes;
  const working = 400 * 1024 * 1024;
  final forCache = (ram * 0.4).floor() - spec.weightBytes - working;
  final tokens = forCache <= 0 ? 0 : forCache ~/ spec.kvBytesPerToken;
  final capped = math.min(tokens, math.min(16384, spec.maxContextTokens));
  return math.max(kOnDeviceMinContextTokens, capped ~/ 512 * 512);
}

/// The context the model runs with: what the user asked for, or the default,
/// within [onDeviceContextCap].
int onDeviceContextTokens(
  OnDeviceLlmSpec spec, {
  int? requested,
  int? ramBytes,
}) {
  final cap = onDeviceContextCap(spec, ramBytes);
  final wanted = requested ?? kOnDeviceDefaultContextTokens;
  return math.max(kOnDeviceMinContextTokens, math.min(wanted, cap));
}

/// How many threads generation uses.
///
/// Half the cores, two to four on a phone: the big cores do the work, and
/// putting the little ones on it too makes it slower and hotter, not faster.
/// A desktop gets up to eight.
int onDeviceThreads({int? cores, bool? mobile}) {
  final count = cores ?? Platform.numberOfProcessors;
  final phone =
      mobile ??
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  return (count ~/ 2).clamp(2, phone ? 4 : 8);
}
