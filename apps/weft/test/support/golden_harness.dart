import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:path/path.dart' as p;
import 'package:weft_design/weft_design.dart';

import 'package:weft_matrix/weft_matrix.dart'
    show DetectedBridge, DeviceManager, KeyBackup;
import 'package:weft_richtext/weft_richtext.dart' show LinkPreviewFetch;

import 'package:weft/app/localisation.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/app/settings.dart';
import 'package:weft/app/stores.dart';
import 'package:weft/data/chat_repository.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/data/matrix_chat_repository.dart'
    show AttachmentBytesLoader;
import 'package:weft/services/backup/backup_service.dart';
import 'package:weft/services/links/link_preview_service.dart';

bool _fontsLoaded = false;

/// Loads real text and icon fonts so golden images show actual glyphs.
///
/// `flutter_test` otherwise substitutes a placeholder that draws every glyph as
/// a filled box, which makes a golden useless for judging layout or catching a
/// text overflow. Both fonts ship inside the Flutter SDK, so this works on any
/// machine that can run the tests — no vendored font files, no network.
///
/// **Call this from `setUpAll`, never from inside `testWidgets`.** A test body
/// runs in a `FakeAsync` zone, and awaiting real file I/O there never completes
/// — the read finishes on a real timer that fake async will not advance, and
/// the test hangs until its timeout.
Future<void> loadGoldenFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;

  final root = _flutterRoot();
  if (root == null) return;

  final fonts = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!fonts.existsSync()) return;

  await _load('Roboto', [
    '${fonts.path}/Roboto-Regular.ttf',
    '${fonts.path}/Roboto-Medium.ttf',
    '${fonts.path}/Roboto-Bold.ttf',
  ]);
  await _load('MaterialIcons', ['${fonts.path}/MaterialIcons-Regular.otf']);
  // The desktop theme asks for the system face, which a test runner has no
  // copy of — every glyph in a macOS golden would be a placeholder box.
  // Registering Roboto under the family the theme names keeps the *layout*
  // honest, which is what an image of a layout is for; the shapes are not the
  // ones a Mac draws and are not what these goldens assert.
  for (final system in const ['.AppleSystemUIFont', 'CupertinoSystemText']) {
    await _load(system, [
      '${fonts.path}/Roboto-Regular.ttf',
      '${fonts.path}/Roboto-Medium.ttf',
      '${fonts.path}/Roboto-Bold.ttf',
    ]);
  }
  // The SDK cache ships no monospace face, and `monospace` is the first family
  // of the stack `rich_text_view.dart` asks for — so without this every inline
  // code run and every code block in a golden is a row of placeholder boxes,
  // which is the failure this whole function exists to prevent. Roboto
  // Condensed stands in: the glyphs are not the ones a device draws, but the
  // ink, the padding and the wrapping around them are the app's own, and those
  // are what the image is for.
  await _load('monospace', ['${fonts.path}/RobotoCondensed-Regular.ttf']);
  // Registered under the package-qualified family: an IconData carrying
  // `fontPackage` resolves to `packages/<pkg>/<family>`, so registering the
  // bare family name loads the font but never matches the glyphs.
  await _loadPackageFont(
    'packages/simple_icons/SimpleIcons',
    'simple_icons',
    'fonts/SimpleIcons.ttf',
  );
}

/// Loads a font shipped inside a pub package, read from its resolved location
/// on disk.
///
/// Network brand glyphs come from `simple_icons`; without this every logo in a
/// golden is an empty box, which hides exactly the layout problems goldens
/// exist to catch. The asset bundle is not used because package assets are not
/// resolvable from the `flutter test` runner — reading the file the way the
/// SDK fonts are read is both simpler and actually works.
Future<void> _loadPackageFont(
  String family,
  String package,
  String assetPath,
) async {
  final root = _packageRoot(package);
  if (root == null) return;

  final file = File(p.join(root, assetPath));
  if (!file.existsSync()) return;

  final bytes = await file.readAsBytes();
  await (FontLoader(
    family,
  )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

/// Resolves a package's root directory from the workspace package config.
String? _packageRoot(String package) {
  var dir = Directory.current;
  for (var depth = 0; depth < 5; depth++) {
    final config = File(p.join(dir.path, '.dart_tool', 'package_config.json'));
    if (config.existsSync()) {
      final decoded =
          jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
      for (final entry in (decoded['packages'] as List? ?? const [])) {
        if (entry is! Map || entry['name'] != package) continue;
        final uri = Uri.parse(entry['rootUri'] as String);
        return uri.scheme == 'file'
            ? uri.toFilePath()
            : p.normalize(p.join(config.parent.path, uri.path));
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    any = true;
    loader.addFont(file.readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  if (any) await loader.load();
}

/// `flutter test` exports FLUTTER_ROOT; the executable path is the fallback for
/// a bare `dart test` run.
String? _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  final exe = File(Platform.resolvedExecutable).parent.parent.parent.path;
  return Directory('$exe/bin/cache/artifacts/material_fonts').existsSync()
      ? exe
      : null;
}

/// An accessibility condition a golden is captured under.
///
/// Three of Weft's four accessibility knobs are things a *user* turns on and a
/// widget test never sees unless it says so: the device's locale, the system
/// text scale and the platform's high-contrast switch. Each one is a whole
/// class of layout failure that no other test in the suite can catch, because
/// every one of them is a question about pixels — a right-to-left screen with
/// one row still anchored to the physical left, a label clipped at 2.0×, a
/// hairline that vanishes when the palette is pushed apart.
///
/// Held as a value rather than as three parameters so a suite can iterate the
/// set. [name] is the golden filename's middle segment, which is why the
/// variants are snake_case: `a11y_inbox_large_text_dark.png` sorts next to its
/// siblings in a directory listing and in a review diff.
@immutable
class WeftGoldenVariant {
  const WeftGoldenVariant({
    required this.name,
    this.locale = const Locale('en'),
    this.textScale = 1.0,
    this.highContrast = false,
  });

  /// Filename segment, and the test description.
  final String name;

  /// The locale the app is put into — which is what resolves [Directionality],
  /// and the only thing that does. See `app/localisation.dart`.
  final Locale locale;

  /// Multiplier for `MediaQuery.textScaler`.
  final double textScale;

  /// `MediaQuery.highContrast`, fed to both the theme and the subtree — the app
  /// root reads it from the query and folds it into the theme, so a golden that
  /// set only one of the two would be an image of a state the app cannot be in.
  final bool highContrast;
}

/// The default condition: English, unscaled, ordinary contrast.
///
/// Every golden written before this phase is captured under it, and it is
/// deliberately the default of [pumpWeft] so that none of them moved.
const weftGoldenBaseline = WeftGoldenVariant(name: 'baseline');

/// The four conditions Phase 08 pins.
///
/// `ar` rather than `he` for the right-to-left case: Arabic is right-to-left
/// *and* joining *and* has its own digits, so it exercises strictly more of the
/// layout than Hebrew does. Hebrew's own case is covered by content — the
/// mixed-direction thread carries it — rather than by chrome.
///
/// 2.0× and 0.85× are the ends of the range the phase names. The large end is
/// where clipping and overflow live; the small end is where a container sized
/// for its text stops being tall enough to hold a 48dp tap target.
const weftAccessibilityVariants = <WeftGoldenVariant>[
  WeftGoldenVariant(name: 'rtl', locale: Locale('ar')),
  WeftGoldenVariant(name: 'large_text', textScale: 2.0),
  WeftGoldenVariant(name: 'small_text', textScale: 0.85),
  WeftGoldenVariant(name: 'high_contrast', highContrast: true),
];

/// Pumps [child] inside a themed [ProviderScope] at a fixed logical size.
///
/// [repository] and [fileReader] are named rather than a general overrides list
/// because Riverpod's `Override` is not exported from either barrel, so a typed
/// `List<Override>` parameter cannot be written at all — the scope's own list
/// only type-checks by inference. Four named seams now cover everything the
/// golden suites need to state: what is in the rooms, what a picked file's
/// bytes are, what the settings say, and what the homeserver answers when it is
/// asked about a link.
///
/// [stores] and [linkPreviewFetch] are what make a link-preview card drawable
/// at all: with no settings store the gate fails closed, and the card is silent
/// until a homeserver answers, so a golden of one has to state both. They are
/// applied only when non-null — a scene that passes neither is a scene where
/// the preview path is off, which is the right background for every other
/// image here.
///
/// [deviceManager] and [keyBackup] are the same idea for the two settings
/// screens that draw the *account* rather than a room. Both providers reach for
/// a live Matrix session and throw without one, so a golden of either screen has
/// to state what the homeserver would have said — which is also the only way to
/// pin a scene the account cannot be put into on demand, like "no backup and
/// nowhere else signed in".
///
/// [variant] is the accessibility condition — locale, text scale and contrast.
/// It defaults to [weftGoldenBaseline], which is what every golden taken before
/// Phase 08 was captured under.
Future<void> pumpWeft(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1400, 900),
  WeftThemeMode mode = WeftThemeMode.dark,
  Color seed = WeftTheme.defaultSeed,
  WeftGoldenVariant variant = weftGoldenBaseline,
  WeftSurface surface = WeftSurface.touch,

  /// Whether the scene is driven with a pointer and a hardware keyboard.
  ///
  /// Null means "whatever [surface] implies", which is what nearly every test
  /// wants: a Mac has a mouse and a phone does not. Pass it explicitly for the
  /// case the two come apart — Windows and Linux, which draw the touch layout
  /// and still right-click, hover and drag-select.
  bool? pointer,
  ChatRepository? repository,
  AttachmentBytesLoader? fileReader,
  WeftStores? stores,
  LinkPreviewFetch? linkPreviewFetch,
  DeviceManager? deviceManager,
  KeyBackup? keyBackup,

  /// The backup screen's export and restore, which otherwise reach the file
  /// system, the share sheet and a file dialog — three method channels a
  /// golden has none of. The same idea as [deviceManager] and [keyBackup]:
  /// state what the platform would have said, so a scene can be pinned that
  /// the app cannot be put into on demand.
  BackupService? backupService,
  List<DetectedBridge>? detectedBridges,

  /// Whether the account sends public read receipts.
  ///
  /// A named parameter rather than a general overrides list because Riverpod's
  /// `Override` is not exported from either barrel — which is also why the list
  /// below is never given an explicit type — so a scene cannot hand one over.
  /// Null leaves the real provider in place, which reads the settings store and
  /// defaults to on.
  bool? readReceipts,

  /// Whether the scene is still waiting on its first sync of the run.
  ///
  /// Overridden even when false: the real provider waits on the session
  /// bootstrap, and a scene has no session to boot.
  bool catchingUp = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await _applyLocale(variant.locale);

  await tester.pumpWidget(
    ProviderScope(
      // Goldens always run on fixtures. Without this the widget tree would
      // reach for a live Matrix session and throw. Note the overrides list is
      // never given an explicit type: Riverpod's `Override` is not exported
      // from either barrel, so it can only be produced by inference.
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          repository ?? DemoChatRepository(),
        ),
        // Held at the instant the demo fixtures are dated against. A real
        // clock here would label the inbox "16:40" today and "8/15/2026" next
        // week — a golden that fails on a Tuesday.
        clockProvider.overrideWithValue(() => DemoChatRepository.fixtureNow),
        catchingUpProvider.overrideWith((ref) => Stream.value(catchingUp)),
        if (fileReader != null)
          attachmentFileReaderProvider.overrideWithValue(fileReader),
        // Both faces of the same store. `storesProvider` is the synchronous one
        // and throws while the bootstrap future is pending, so a screen that
        // reads settings in `initState` — search and every settings screen do —
        // needs the value override as well as the future.
        if (stores != null) ...[
          storesProvider.overrideWithValue(stores),
          storesBootstrapProvider.overrideWith((ref) async => stores),
        ],
        // The provider this replaces reaches for a live Matrix session, so a
        // scene that wants a card has to bring its own answers rather than let
        // the real one be read.
        if (linkPreviewFetch != null)
          linkPreviewFetchProvider.overrideWithValue(linkPreviewFetch),
        if (deviceManager != null)
          deviceManagerProvider.overrideWithValue(deviceManager),
        if (keyBackup != null) keyBackupProvider.overrideWithValue(keyBackup),
        if (backupService != null)
          backupServiceProvider.overrideWithValue(backupService),
        // What the homeserver appears to run. Without this the bridges screen
        // can only ever be drawn empty, which is the one state a person who
        // runs bridges never sees.
        if (detectedBridges != null)
          detectedBridgesProvider.overrideWithValue(detectedBridges),
        // The ticks read this as well as the sender does: with receipts off,
        // two grey ticks mean "we are not being told" rather than "they have
        // not looked at it", and the bubble says so.
        if (readReceipts != null)
          sendReadReceiptsProvider.overrideWithValue(readReceipts),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // The three lines `main.dart` carries, for the reason it carries them:
        // `Directionality` has no other source, so without the delegates a
        // golden asked for in Arabic would be an English-looking image with an
        // Arabic filename — a passing test of nothing.
        locale: variant.locale,
        localizationsDelegates: weftLocalizationsDelegates,
        supportedLocales: weftSupportedLocales,
        theme: WeftAppearance(mode: mode, seed: seed).themeFor(
          Brightness.dark,
          highContrast: variant.highContrast,
          surface: surface,
          pointer: pointer,
        ),
        // Under the navigator rather than over the app, which is where the app
        // itself reads these: a `MediaQuery` above `MaterialApp` is rebuilt
        // from the view by `MediaQuery.fromView`, so a text scaler set there
        // reaches the tree only by the platform-data back door and a route
        // pushed later would not see it at all.
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(variant.textScale),
            highContrast: variant.highContrast,
          ),
          child: app ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    ),
  );

  // Settle the entry animations rather than capturing them mid-flight, which
  // would make every golden non-deterministic.
  //
  // Some screens never settle, and correctly so: a typing indicator and a QR
  // code's expiry clock both animate for as long as they are true. Those pump
  // a fixed number of frames instead.
  if (settle) {
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Points `intl` at [locale] for the duration of one test.
///
/// Every `DateFormat` in Weft is built without a locale and reads
/// `Intl.defaultLocale`, which `main` sets from the resolved locale — so a
/// golden that mirrored the layout and left the clock in English would be an
/// image of a screen the app never draws. [applyFormattingLocale] is the app's
/// own function, and it is guarded on the symbol data having been loaded:
/// `main` awaits [initializeDateFormatting] and a widget test does not, so the
/// load happens here.
///
/// Restored on teardown because `Intl.defaultLocale` is global. A suite that
/// left it at `ar` would hand the next file's goldens Arabic-Indic timestamps,
/// and the failure would land in whichever test happened to run next.
Future<void> _applyLocale(Locale locale) async {
  await initializeDateFormatting(locale.languageCode);
  final previous = Intl.defaultLocale;
  addTearDown(() => Intl.defaultLocale = previous);
  applyFormattingLocale(locale);
}

/// Decodes [provider] into the shared image cache before a golden is pumped.
///
/// `Image.memory` resolves its frame through the engine's codec, which is real
/// asynchronous work — and a widget test's `FakeAsync` zone never advances it.
/// Pumped the ordinary way, a golden of a photo therefore captures an *empty*
/// box where the picture should be, which looks enough like a deliberate layout
/// to be accepted by whoever reviews the image. Resolving under
/// [WidgetTester.runAsync] first puts the decoded frame in the cache, so the
/// widget's own resolve is a hit and completes synchronously.
///
/// Takes an [ImageProvider] rather than bytes because the cache key must match
/// the one the widget builds: `Image.memory(bytes, cacheWidth: n)` is a
/// `ResizeImage` wrapping a `MemoryImage`, and priming the bare `MemoryImage`
/// would leave the thumbnail as unresolved as before.
Future<void> primeImage(WidgetTester tester, ImageProvider provider) async {
  await tester.runAsync(() async {
    final done = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void finish() {
      stream.removeListener(listener);
      if (!done.isCompleted) done.complete();
    }

    listener = ImageStreamListener(
      (_, _) => finish(),
      // A fixture that fails to decode must not hang the suite until its
      // timeout: the golden then fails on the picture being missing, which
      // says what actually went wrong.
      onError: (_, _) => finish(),
    );
    stream.addListener(listener);
    await done.future;
  });
}
