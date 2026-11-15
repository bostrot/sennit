import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout, kPressTimeout, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:weft_design/weft_design.dart';

import 'package:weft/app/labels.dart';
import 'package:weft/app/localisation.dart';
import 'package:weft/app/providers.dart';
import 'package:weft/app/session_providers.dart';
import 'package:weft/features/bridges/bridges_screen.dart';
import 'package:weft/features/chat/chat_view.dart';
import 'package:weft/features/contact/contact_profile.dart';
import 'package:weft/features/inbox/inbox_shell.dart';
import 'package:weft/data/demo_repository.dart';
import 'package:weft/features/inbox/new_chat_sheet.dart';
import 'package:weft/features/inbox/requests_screen.dart';
import 'package:weft/features/merge/merge_screen.dart';
import 'package:weft/features/search/search_screen.dart';
import 'package:weft/features/settings/ai_screen.dart';
import 'package:weft/features/settings/auto_reply_screen.dart';
import 'package:weft/features/settings/backup_screen.dart';
import 'package:weft/features/settings/devices_screen.dart';
import 'package:weft/features/settings/endpoints_screen.dart';
import 'package:weft/features/settings/integrations_screen.dart';
import 'package:weft/features/settings/link_previews_screen.dart';
import 'package:weft/features/settings/mcp_screen.dart';
import 'package:weft/features/settings/models_screen.dart';
import 'package:weft/features/settings/notifications_screen.dart';
import 'package:weft/features/settings/security_screen.dart';
import 'package:weft/features/settings/settings_screen.dart';
import 'package:weft/features/settings/surfaces_screen.dart';
import 'package:weft/features/status/status_viewer.dart';
import 'package:weft/main.dart';

import '../test/support/ui_audit.dart';

/// Every surface in Sennit, visited, photographed and measured.
///
///   cd apps/weft
///   flutter test integration_test/route_walk_test.dart \
///     --dart-define=WEFT_DEMO=true
///
/// and, for images from a real rasteriser on a real machine:
///
///   flutter test integration_test/route_walk_test.dart -d macos \
///     --dart-define=WEFT_DEMO=true
///
/// ## Why this is here and not in `patrol/`
///
/// That directory's README states the rule and this file is the other side of
/// it: *"Scenarios whose assertions are all inside the view belong in `../`,
/// not here."* Every question below — did the screen draw, did anything
/// overflow, is that control big enough, is that gap a token — is answered from
/// the widget tree. None of them needs a platform automator, and running them
/// under one would cost a device, a homeserver and eleven minutes to learn
/// nothing extra.
///
/// ## What it is for
///
/// Three things the rest of the suite does not do.
///
/// **Coverage.** `test/a11y/semantics_test.dart` sweeps six screens and a
/// handful of sheets; the golden suites pin about twenty scenes. Neither knows
/// when a screen is *added*. This walks the list in
/// `docs/quality/route-inventory.md`, and a surface with no step there is a row
/// a reviewer can see.
///
/// **Overflow.** A `RenderFlex overflowed` is reported, never thrown, so a
/// screen that overflows passes every other test in this repository and ships
/// with stripes on it. [ExceptionRecorder] catches the report and attributes it
/// to the surface that produced it.
///
/// **Spacing.** [offScaleSpacingIn] scans the live tree for gaps that are not
/// on the [WeftSpace] scale. A token scale nobody checks is a suggestion.
///
/// ## Two shells, two runs
///
/// Sennit draws two layouts — `inbox_shell.dart:184` — and which one is chosen
/// comes from the theme's surface token, which comes from
/// `defaultTargetPlatform`. So *which* shell this walks is decided by the
/// device it is given: `-d macos` walks the Mac window, an Android emulator or
/// `-d linux` walks the touch shell. Both are needed for a complete pass, and
/// the two are named separately in `docs/quality/ui-audit.md`.
///
/// Deliberately not one run with [debugDefaultTargetPlatformOverride] flipped,
/// which is the obvious shortcut and is wrong here. `WeftApp` boots the real
/// notification stack, and `NotificationPlatform` reads the same
/// `defaultTargetPlatform`: claiming to be Android on a Mac makes
/// `UnifiedPush.initialize` call a plugin that is not registered, and the walk
/// dies in `initState` before it has drawn anything. The surface is a *design*
/// decision and the platform is not, but the app reads one from the other, so
/// the honest way to get both layouts is two targets.
///
/// ## Failure
///
/// A step that cannot reach its surface, and any framework exception raised
/// while it is open, fails the test: the whole point is that an overflow stops
/// being an ugly screenshot nobody opens. The *measurements* — small targets,
/// unnamed controls, off-scale gaps — are reported rather than fatal. They are
/// a work list, they are triaged into `docs/quality/ui-audit.md` by hand, and a
/// suite that failed on the first of two hundred would never reach the second.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const shotDirOverride = String.fromEnvironment('WEFT_SHOT_DIR');
  const passOverride = String.fromEnvironment('WEFT_WALK_PASSES');
  const holdSeconds = int.fromEnvironment('WEFT_WALK_HOLD');

  // Keeps the app alive after the last step, so its images can be collected.
  //
  // Only Android needs this, and it needs it badly. Every directory the app can
  // write to on a device is inside the app: the private one [_shotDirectory]
  // falls back to, and the external one it prefers, are *both* deleted when
  // `flutter test` uninstalls the app at the end of the run — so an Android walk
  // photographs thirty-one screens, reports a clean pass, and leaves nothing
  // behind. Holding here parks the run inside `tearDownAll`, which is before the
  // uninstall, long enough for an `adb pull`:
  //
  //   flutter test integration_test/route_walk_test.dart -d emulator-5554 \
  //     --dart-define=WEFT_DEMO=true --dart-define=WEFT_WALK_HOLD=90 &
  //   adb pull /sdcard/Android/data/com.bostrot.weft/files/route-walk .
  //
  // Zero by default, so CI never waits.
  tearDownAll(() async {
    if (holdSeconds <= 0) return;
    debugPrint(
      'weft: holding the app open for ${holdSeconds}s — pull the images now',
    );
    await Future<void>.delayed(Duration(seconds: holdSeconds));
  });

  setUpAll(() {
    expect(
      kDemoMode,
      isTrue,
      reason:
          'Run with --dart-define=WEFT_DEMO=true: without it the app reaches '
          'for a homeserver and every step below times out at the splash.',
    );
  });

  for (final pass in walkPasses(passOverride)) {
    testWidgets(
      'route walk — ${weftSurface.name}${pass.isDefault ? '' : ' (${pass.name})'}',
      (tester) async {
        final walker = RouteWalker(
          tester: tester,
          surface: weftSurface,
          shots: await _shotDirectory(shotDirOverride),
          pass: pass,
        );
        await walker.boot();

        for (final step in routeSteps) {
          if (!step.surfaces.contains(weftSurface)) continue;
          await walker.walk(step);
        }

        walker.report();
        walker.finish();
        expect(
          walker.failures,
          isEmpty,
          reason:
              'the route walk could not complete ${walker.failures.length} '
              'step(s):\n${walker.failures.join('\n')}',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  }
}

// ------------------------------------------------------------------ the passes

/// One trip through the inventory, under one set of viewing conditions.
///
/// The walk's default has always been a single 1400×900 light-mode English
/// pass, and [kDefaultPass] still is exactly that — CI's invocation is
/// unchanged and so are the filenames it writes. What this adds is the *other*
/// conditions the same surfaces have to survive, named so a person can ask for
/// them: a phone-width window, dark mode, the system font at double size, and a
/// right-to-left layout.
///
/// Passes rather than four separate `flutter test` runs because the expensive
/// part of a device run is the build and the install, not the walking. Four
/// passes in one invocation cost four boots; four invocations cost four
/// installs, and on a real Android device that is most of the wall clock.
///
/// Right-to-left is a *locale* here rather than a `Directionality` wrapper, and
/// `ar` specifically. `localisation.dart` explains why that works: Sennit
/// declares `ar` and `he` for layout with no ARB file behind them, so the app
/// turns right-to-left while its own words stay English — which is what keeps
/// every finder in this file, all of which name controls in English, still
/// matching under the mirrored pass.
@immutable
class WalkPass {
  const WalkPass({
    required this.name,
    this.size = const Size(1400, 900),
    this.locale = const Locale('en'),
    this.textScale = 1.0,
    this.brightness,
  });

  /// The pass's name, and the screenshot filename's suffix.
  final String name;

  /// The logical window the app is given.
  final Size size;

  /// The device locale. `ar` mirrors the layout; the words stay English.
  final Locale locale;

  /// `MediaQuery.textScaler`, as a linear multiplier.
  final double textScale;

  /// The system brightness, or null to leave the runner's own alone.
  ///
  /// Null rather than [Brightness.light] for the default pass: the setting is
  /// `WeftThemeMode.system` (`settings.dart:12`), so pinning it here would make
  /// the default walk stop matching what the machine running it actually draws
  /// — and the macOS artefacts in `Working/route-walk/` were captured without a
  /// pin.
  final Brightness? brightness;

  bool get isDefault => name == 'default';

  /// What this pass adds to a screenshot or findings filename.
  String get suffix => isDefault ? '' : '-$name';
}

const kDefaultPass = WalkPass(name: 'default');

/// A phone, near enough: a Pixel-class window in logical pixels.
const _phone = Size(412, 915);

/// Every pass that can be asked for by name.
///
/// The phone quartet is one variable at a time off the same 412×915 window, so
/// a difference between two of them is attributable. Comparing a dark phone
/// against a light tablet would not be.
final Map<String, WalkPass> kWalkPasses = {
  'default': kDefaultPass,
  'phone': const WalkPass(
    name: 'phone',
    size: _phone,
    brightness: Brightness.light,
  ),
  'phone-dark': const WalkPass(
    name: 'phone-dark',
    size: _phone,
    brightness: Brightness.dark,
  ),
  'phone-xl': const WalkPass(
    name: 'phone-xl',
    size: _phone,
    brightness: Brightness.light,
    // 2.0 rather than Android's 1.3 maximum slider: the font-size *and*
    // display-size sliders multiply, and the accessibility harness already
    // pins 2.0 (`a11y_harness.dart`), so a finding here is comparable with one
    // there.
    textScale: 2.0,
  ),
  'phone-rtl': const WalkPass(
    name: 'phone-rtl',
    size: _phone,
    brightness: Brightness.light,
    locale: Locale('ar'),
  ),
  // The two ends of a resizable Mac window. `desk-narrow` is deliberately below
  // `kTwoPaneBreakpoint`, which is where the Mac shell has to give up a pane.
  'desk-narrow': const WalkPass(
    name: 'desk-narrow',
    size: Size(720, 640),
    brightness: Brightness.light,
  ),
  'desk-wide': const WalkPass(
    name: 'desk-wide',
    size: Size(1800, 1150),
    brightness: Brightness.light,
  ),
  'desk-dark': const WalkPass(
    name: 'desk-dark',
    size: Size(1400, 900),
    brightness: Brightness.dark,
  ),
};

/// The passes to run, from a comma-separated `WEFT_WALK_PASSES`.
///
/// Empty means the single default pass, which is what every existing caller
/// passes and what CI still runs.
List<WalkPass> walkPasses(String spec) {
  final names = spec
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
  if (names.isEmpty) return const [kDefaultPass];
  return [
    for (final name in names)
      kWalkPasses[name] ??
          (throw ArgumentError(
            'unknown walk pass "$name" — '
            'WEFT_WALK_PASSES takes ${kWalkPasses.keys.join(', ')}',
          )),
  ];
}

/// Sennit's own words, in English.
///
/// Every finder below names a control the way the app names it, rather than
/// with a literal beside it: a renamed string then breaks the step that opens
/// the screen instead of silently matching nothing and reporting a clean walk.
final AppL10n _l10n = lookupAppL10n(const Locale('en'));

// ---------------------------------------------------------------- the entries

/// One surface, and how to get to it.
///
/// A record of finders rather than a test body, so the list reads as an
/// inventory and the driver owns everything every step does the same way —
/// reset, arrive, photograph, measure, leave. A step with its own driver would
/// be a step whose measurements are not comparable with the others'.
@immutable
class RouteStep {
  const RouteStep({
    required this.label,
    required this.open,
    required this.arrival,
    this.surfaces = WeftSurface.values,
    this.requires,
    this.close,
    this.settles = true,
  });

  /// The name in `docs/quality/route-inventory.md`, and the screenshot's.
  final String label;

  /// The taps from a cold inbox.
  final Future<void> Function(RouteWalker walker) open;

  /// What proves the surface actually rendered.
  ///
  /// Checked after [open] and before anything is measured: a photograph of the
  /// screen you were already on, audited and filed, is the failure this exists
  /// to prevent.
  final Finder Function() arrival;

  /// Which shells show it. See the Platforms column of the inventory.
  final List<WeftSurface> surfaces;

  /// What has to be on the inbox for the step to be possible at all.
  ///
  /// The status ring row draws nothing when nobody has posted, and a fixture
  /// that stops carrying a status should skip that step loudly rather than fail
  /// it — a skip is reported by name in [RouteWalker.report], never silent.
  final Finder Function()? requires;

  /// How to leave, when popping the route is not it — Escape for a menu or a
  /// popover, a named button for a mode. Null pops.
  final Future<void> Function(RouteWalker walker)? close;

  /// Whether the surface reaches a resting state.
  ///
  /// False for the ones that correctly never do: a typing indicator, a QR
  /// code's expiry clock, a probe with a spinner in it. Those get a fixed
  /// number of frames, which is the choice `pumpWeft` makes for the same
  /// screens.
  final bool settles;
}

const _touch = [WeftSurface.touch];
const _mac = [WeftSurface.mac];

/// The inventory, as steps, in the order `route-inventory.md` lists them.
final List<RouteStep> routeSteps = [
  // ----------------------------------------------------------------- the inbox
  RouteStep(
    label: '01-inbox',
    open: (w) async {},
    arrival: () => find.byType(ChatTile),
  ),
  RouteStep(
    label: '02-inbox-selection',
    surfaces: _touch,
    open: (w) async {
      await w.tapTooltip(_l10n.commonMore);
      await w.tapText(_l10n.inboxMenuSelect);
    },
    arrival: () => find.byType(InboxSelectionBar),
    close: (w) async => w.tapTooltip(_l10n.commonCancel),
  ),
  RouteStep(
    label: '03-inbox-archived',
    surfaces: _touch,
    open: (w) async {
      await w.tapTooltip(_l10n.commonMore);
      await w.tapText(_l10n.inboxMenuShowArchived);
    },
    // The demo fixtures archive nothing, so this is the *empty* inbox — which
    // is the state worth photographing here anyway: it is the one a person sees
    // the first time they go looking for something they archived.
    arrival: () => find.text(_l10n.inboxEmptyTitle),
  ),
  RouteStep(
    label: '05-status-viewer',
    surfaces: _touch,
    requires: () => find.bySemanticsLabel(RegExp('^Status from ')),
    open: (w) async =>
        w.tap(find.bySemanticsLabel(RegExp('^Status from ')).first),
    arrival: () => find.byType(StatusViewer),
    settles: false,
  ),
  RouteStep(
    label: '06-search',
    open: (w) async {
      if (w.isMac) {
        await w.submitInto(find.byType(TextField).first, 'roof');
      } else {
        await w.tapTooltip(_l10n.inboxSearchAll);
      }
    },
    // Never settles: the field autofocuses and its caret blinks for as long as
    // the screen is open.
    arrival: () => find.byType(SearchScreen),
    settles: false,
  ),
  RouteStep(
    label: '07-new-conversation',
    open: (w) async => w.tapTooltip(
      w.isMac ? _l10n.macNewConversation : _l10n.inboxNewChatTooltip,
    ),
    arrival: () => find.byType(NewChatScreen),
  ),
  RouteStep(
    label: '08-new-conversation-by-id',
    open: (w) async {
      await w.tapTooltip(
        w.isMac ? _l10n.macNewConversation : _l10n.inboxNewChatTooltip,
      );
      await w.tapText(_l10n.newChatByIdTitle);
    },
    arrival: () => find.byType(AlertDialog),
  ),
  RouteStep(
    label: '09-new-group',
    open: (w) async {
      await w.tapTooltip(
        w.isMac ? _l10n.macNewConversation : _l10n.inboxNewChatTooltip,
      );
      await w.tapText(_l10n.newChatNewGroup);
    },
    arrival: () => find.byType(AlertDialog),
  ),
  RouteStep(
    label: '11-message-requests',
    open: (w) async => w.tapText(_l10n.requestsTitle),
    arrival: () => find.byType(RequestsScreen),
  ),
  RouteStep(
    label: '10-appearance',
    open: (w) async => w.tapTooltip(_l10n.commonAppearance),
    // The sheet's own heading, which is the same word as the button's tooltip —
    // so this asserts the *text* rather than the tooltip that opened it.
    arrival: () => find.text(_l10n.commonAppearance),
    close: (w) async => w.escape(),
  ),

  // ---------------------------------------------------------- the conversation
  RouteStep(
    label: '20-chat',
    open: (w) async => w.openChat(),
    arrival: () => find.byType(ChatView),
    settles: false,
  ),
  RouteStep(
    label: '22-thread',
    // Opened by the topic's *name*, which is what the indicator leads with and
    // what a plain Matrix thread would not have — so a step that still passed
    // after the bridge's name key stopped being read would be a step asserting
    // the fallback.
    open: (w) async {
      await w.openChat(title: DemoChatRepository.kThreadChatTitle);
      await w.tapText('Deploy \u00b7 ${_l10n.threadReplyCount(3)}');
    },
    arrival: () =>
        find.text(_l10n.threadInChat(DemoChatRepository.kThreadChatTitle)),
    settles: false,
  ),
  RouteStep(
    label: '21-contact-details',
    // The avatar in the conversation's header, which is the button that opens
    // the profile on both shells. Found by position rather than by its
    // accessible name: `find.bySemanticsLabel` resolves to whichever *element*
    // owns the node, and on the touch shell that is the whole app bar — so the
    // tap landed in the middle of the title and did nothing.
    open: (w) async {
      await w.openChat();
      await w.tap(
        find
            .descendant(
              of: find.byType(w.isMac ? MacToolbar : AppBar),
              matching: find.byType(WeftAvatar),
            )
            .first,
      );
    },
    arrival: () => find.byType(ContactProfileScreen),
  ),
  RouteStep(
    label: '23-attach',
    open: (w) async {
      await w.openChat();
      await w.tapTooltip(_l10n.attachSheetTitle);
    },
    arrival: () => find.text(_l10n.attachSourceMedia),
    close: (w) async => w.escape(),
  ),
  RouteStep(
    label: '24-merged-chats',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsMergedChatsTitle);
    },
    arrival: () => find.byType(MergeScreen),
  ),

  // ------------------------------------------------------------------ settings
  RouteStep(
    label: '30-settings',
    open: (w) async => w.openSettings(),
    arrival: () => find.byType(SettingsScreen),
  ),
  RouteStep(
    label: '31-bridges',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsBridgesTitle);
    },
    arrival: () => find.byType(BridgesScreen),
    settles: false,
  ),
  RouteStep(
    label: '32-notifications',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsNotificationsTitle);
    },
    arrival: () => find.byType(NotificationsScreen),
    settles: false,
  ),
  RouteStep(
    label: '32a-ai',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsAiTitle);
    },
    arrival: () => find.byType(AiSettingsScreen),
  ),
  RouteStep(
    label: '33-endpoints',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsAiTitle);
      await w.tapText(_l10n.settingsEndpointsTitle);
    },
    arrival: () => find.byType(EndpointsScreen),
  ),
  RouteStep(
    label: '34-models',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsAiTitle);
      await w.tapText(_l10n.settingsModelsTitle);
    },
    arrival: () => find.byType(ModelsScreen),
    settles: false,
  ),
  RouteStep(
    label: '34a-auto-reply',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsAiTitle);
      await w.tapText(_l10n.settingsAutoReplyTitle);
    },
    arrival: () => find.byType(AutoReplyScreen),
  ),
  RouteStep(
    label: '34b-auto-reply-editor',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsAiTitle);
      await w.tapText(_l10n.settingsAutoReplyTitle);
      // No rules on a fresh demo profile, so the door into the editor is the
      // FAB rather than a pencil beside a row that does not exist.
      await w.tapText(_l10n.autoReplyNewRule);
    },
    arrival: () => find.byType(AutoReplyRuleEditor),
  ),
  RouteStep(
    label: '35-link-previews',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsLinkPreviewsTitle);
    },
    arrival: () => find.byType(LinkPreviewsScreen),
  ),
  RouteStep(
    label: '36-devices',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsDevicesTitle);
    },
    arrival: () => find.byType(DevicesScreen),
    settles: false,
  ),
  RouteStep(
    label: '37-encryption',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsEncryptionTitle);
    },
    arrival: () => find.byType(SecurityScreen),
    settles: false,
  ),
  RouteStep(
    label: '37a-backup',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsBackupTitle);
    },
    arrival: () => find.byType(BackupScreen),
    // The screen counts the store in `initState`, so there is an in-flight
    // future on arrival and `pumpAndSettle` would wait for a frame that the
    // count's completion is what schedules.
    settles: false,
  ),
  RouteStep(
    label: '38-companion-surfaces',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsSurfacesTitle);
    },
    arrival: () => find.byType(SurfacesScreen),
  ),
  RouteStep(
    label: '39-integrations',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsIntegrationsTitle);
    },
    arrival: () => find.byType(IntegrationsScreen),
  ),
  RouteStep(
    label: '40-mcp',
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsMcpTitle);
    },
    arrival: () => find.byType(McpScreen),
    settles: false,
  ),
  RouteStep(
    label: '41-keyboard-shortcuts',
    surfaces: _mac,
    open: (w) async {
      await w.openSettings();
      await w.tapText(_l10n.settingsShortcutsTitle);
    },
    arrival: () => find.text(_l10n.shortcutsTitle),
    close: (w) async => w.escape(),
  ),

  // ------------------------------------------------- the ones that hold a row
  //
  // Last, and the order is load-bearing rather than tidy. Under a live binding
  // a long press leaves the control it was performed on unable to receive a
  // *tap* for the rest of the run: the press is delivered, the recogniser wins,
  // the route it opens rebuilds the subtree under it, and every later tap on
  // that widget is hit-tested correctly and then swallowed by the arena. It is
  // an artefact of the harness — [RouteWalker.longPress] says what was tried —
  // and the cheap way around it is to spend each control's long press after
  // everything that needs to tap it.
  //
  // So: the bubble before the row, because reaching a bubble means tapping a
  // row first, and the row's own long press after both.
  // A live selection across two bubbles: the Mac's answer to long-press, and
  // the one state in a conversation that only a drag can reach.
  //
  // In this block because a drag is a gesture and spends the bubble the same
  // way a long press spends a row — but *first* in it, because reaching a
  // bubble means tapping a conversation row and `91` is about to spend that.
  RouteStep(
    label: '89-chat-selection',
    surfaces: _mac,
    open: (w) async {
      await w.openChat();
      await w.dragSelectMessages();
    },
    // The region itself, because "is something selected" is a fact about a
    // render object and not about the widget tree. The measurement this step
    // exists for is the *screenshot*: whether the highlight stays readable on
    // the own bubble's tinted fill and on the peer's, which is a question only
    // an eye answers.
    arrival: () => find.byType(SelectionArea),
  ),
  RouteStep(
    label: '90-message-actions',
    surfaces: _touch,
    // Touch is the *layout*, not the input: Linux and Windows draw this
    // surface and are driven with a mouse, where a long press on a bubble is
    // deliberately nothing and the same verbs sit behind the right button.
    open: (w) async {
      await w.openChat();
      if (weftHasPointer) {
        await w.secondaryTap(w.visible(w.bubbles));
      } else {
        await w.longPress(w.visible(w.bubbles));
      }
    },
    arrival: () => find.text(_l10n.messageActionReply),
    close: (w) async => w.escape(),
  ),
  RouteStep(
    label: '91-chat-preview',
    open: (w) async => w.longPress(find.byType(ChatTile).first),
    arrival: () => find.byType(ChatView),
  ),
];

// ----------------------------------------------------------------- the driver

/// Boots Sennit once and walks it.
class RouteWalker {
  RouteWalker({
    required this.tester,
    required this.surface,
    required this.shots,
    this.pass = kDefaultPass,
  });

  final WidgetTester tester;
  final WeftSurface surface;
  final Directory? shots;

  /// The viewing conditions this trip is made under. See [WalkPass].
  final WalkPass pass;

  bool get isMac => surface == WeftSurface.mac;

  final _rootKey = GlobalKey();
  late final ProviderContainer _container;
  SemanticsHandle? _semantics;

  /// Steps that could not be reached, or that raised on the way.
  final List<String> failures = [];

  /// Steps whose precondition was not on screen, by name — reported, never
  /// quietly dropped.
  final List<String> skipped = [];

  /// Everything the four scanners saw, across every surface.
  final List<UiFinding> findings = [];

  /// The message bubbles in an open conversation.
  ///
  /// `_MessageBubble` by runtime type name, because it is private to
  /// `chat_view.dart` and should stay that way: widening a widget's visibility
  /// so a test can name it makes the test's convenience part of the app's API.
  ///
  /// The `WeftFocusable` *inside* it rather than the bubble widget itself, and
  /// that is the difference between this working and not. A bubble's own box is
  /// the full width of the thread — it is the row that aligns the bubble to one
  /// side — so its centre is in the empty gutter beside the bubble, and a long
  /// press there lands on nothing. The focusable is the painted bubble.
  Finder get bubbles => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_MessageBubble',
    ),
    matching: find.byType(WeftFocusable),
  );

  /// Puts the app on the glass under [pass]'s viewing conditions.
  ///
  /// The default pass is 1400×900 rather than a phone: it is what the golden
  /// and accessibility harnesses pump, so a measurement here is comparable with
  /// one there, and it is the only size at which the Mac window's three panes
  /// all exist. The touch shell is above `kTwoPaneBreakpoint` there and draws
  /// its two-pane form, which is the tablet layout and a real one — but it is
  /// *not* the phone, which is why the `phone*` passes exist and why the manual
  /// walkthrough is run on them.
  Future<void> boot() async {
    // English, whatever the machine is set to.
    //
    // Every finder below names a control by the word the app puts on it, and
    // on a German laptop the app puts *German* words on it — the first run of
    // this file failed twenty-three steps in a row looking for "Settings" on a
    // screen that said "Einstellungen". Pinned before the first pump, so the
    // resolution happens once. What the other locales do to the layout is
    // `test/l10n_overflow_test.dart` and `test/goldens/locale_golden_test.dart`,
    // which are built for that question; this file's question is the routes.
    tester.platformDispatcher.localesTestValue = [pass.locale];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    // The rest of the pass, applied before the first pump for the same reason
    // the locale is: a screen that draws once at one size and then again at
    // another is a screen whose first frame is in the screenshot.
    if (pass.textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = pass.textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    if (pass.brightness case final brightness?) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    }

    tester.view.physicalSize = pass.size;
    tester.view.devicePixelRatio = 1.0;
    // And the keyboard's inset with it, which is the other half of pinning the
    // view and was missing for one run.
    //
    // A view size set here is a fiction; `viewInsets` is not, and it keeps
    // arriving from the real device in *its* physical pixels. Divided by the
    // device pixel ratio this line also overrides, an Android emulator's soft
    // keyboard reported 800 of the 900 logical pixels the app had been told it
    // has — so `09-new-group`, whose name field autofocuses, drew an
    // `AlertDialog` into 52 pixels and reported a 107-pixel overflow. Nothing
    // was wrong with the dialog: at a real phone's geometry the same keyboard
    // leaves 600 pixels, and no device presents 800-of-900.
    //
    // Zero rather than a plausible keyboard, because what the keyboard does to
    // a screen is a question about one screen and this file's question is the
    // routes. A walk that fails on an inset it invented is a walk nobody runs
    // twice.
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    // Without this there is no node tree, and both semantics scanners return
    // an empty list — which reads exactly like a clean screen. Released by
    // [finish] rather than by `addTearDown`: the binding checks for a live
    // handle at the end of the *body*, which is before a teardown runs, and
    // fails the test for it — with a message the live binding does not print,
    // so it costs an afternoon to find. The a11y suites dispose theirs by hand
    // for the same reason.
    _semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(key: _rootKey, child: const WeftApp()),
      ),
    );
    await settle();

    _container = ProviderScope.containerOf(
      tester.element(find.byType(WeftApp)),
    );
    expect(
      find.byType(ChatTile),
      findsWidgets,
      reason: 'the walk starts from a cold inbox with conversations in it',
    );
  }

  /// Visits one surface: opens it, proves it arrived, photographs it, measures
  /// it, and leaves.
  ///
  /// Every phase is guarded. A step that throws is a failure *of that step* —
  /// recorded, reset out of, and the walk carries on — because a harness whose
  /// first broken finder hides the other forty findings is one nobody runs
  /// twice.
  Future<void> walk(RouteStep step) async {
    if (step.requires case final precondition?) {
      if (precondition().evaluate().isEmpty) {
        skipped.add('${step.label}: ${precondition()} was not on the inbox');
        return;
      }
    }

    final recorder = ExceptionRecorder();
    try {
      await step.open(this);
      await (step.settles ? settle() : pumpFrames());

      if (step.arrival().evaluate().isEmpty) {
        failures.add(
          '${step.label}: never arrived — ${step.arrival()}. $onScreen',
        );
        return;
      }

      await shoot(step.label);
      _measure(step.label);
    } on Object catch (error) {
      failures.add('${step.label}: ${_firstLine('$error')}. $onScreen');
      debugPrint(
        'weft: route walk step ${step.label} threw ${_firstLine('$error')}\n'
        '  $onScreen',
      );
    } finally {
      // The reset is inside the recording window on purpose: a framework error
      // raised while a step is being backed out of is still that step's, and
      // one that reached the binding instead would abort the whole walk at
      // whichever screen it happened on.
      await _reset(step);
      for (final error in recorder.stop()) {
        failures.add('${step.label}: ${_firstLine('${error.exception}')}');
      }
      findings.addAll(recorder.findingsFor(step.label));
    }
  }

  /// What a step could have tapped, for a failure message.
  ///
  /// A finder that matched nothing says what was looked for and not what was
  /// there, which is the wrong half — every one of these failures is *which
  /// screen am I actually on*. Tooltips and short text, because between them
  /// they name every control a step reaches for.
  String get onScreen {
    final names = <String>{
      for (final widget in find.byType(Tooltip).evaluate())
        (widget.widget as Tooltip).message ?? '',
      for (final widget in find.byType(Text).evaluate())
        (widget.widget as Text).data ?? '',
    }..removeWhere((name) => name.isEmpty || name.length > 40);
    return 'On screen: ${names.take(25).join(' · ')}';
  }

  /// Releases the semantics handle. Call at the end of the test body.
  void finish() {
    _semantics?.dispose();
    _semantics = null;
  }

  // ------------------------------------------------------------ the measuring

  void _measure(String label) {
    findings
      ..addAll(
        smallTapTargetsIn(
          tester,
          surface: label,
          minSize: minimumTapTargetFor(surface),
        ),
      )
      ..addAll(unnamedControlFindings(tester, surface: label));

    if (spacingScanAvailable) {
      findings.addAll(offScaleSpacingIn(tester, surface: label));
    }
  }

  /// Prints the whole work list, and writes it beside the screenshots.
  ///
  /// Printed rather than asserted: see the file header. The one thing it must
  /// not do is stay quiet — a scan that ran, found forty things, and passed is
  /// the shape of every audit that gets ignored.
  void report() {
    debugPrint(
      'weft: route walk (${surface.name}/${pass.name}) — ${findings.length} '
      'finding(s) across '
      '${routeSteps.where((s) => s.surfaces.contains(surface)).length} '
      'step(s), ${skipped.length} skipped',
    );
    for (final skip in skipped) {
      debugPrint('weft: skipped $skip');
    }
    for (final failure in failures) {
      debugPrint('weft: FAILED $failure');
    }
    debugPrint(describeFindings(findings));
    if (!spacingScanAvailable) {
      debugPrint(
        'weft: the spacing scan did not run — this build has no widget '
        'creation tracking, so no gap was looked at. Run it in debug.',
      );
    }

    final target = shots;
    if (target == null) return;
    try {
      File(
        p.join(target.path, 'findings-${surface.name}${pass.suffix}.tsv'),
      ).writeAsStringSync(findingsAsTsv(findings));
    } on FileSystemException catch (error) {
      debugPrint('weft: could not write the findings file — $error');
    }
  }

  // ------------------------------------------------------------- the plumbing

  /// Back to a cold inbox, whatever the step left behind.
  ///
  /// Two halves, and both are needed. The navigator is popped to its first
  /// route, which undoes every push and every panel; and the providers a step
  /// can move are invalidated, which undoes the state a pop does not — a
  /// selection mode entered, a network filtered, archived chats shown, a
  /// conversation selected into the Mac window's third pane.
  Future<void> _reset(RouteStep step) async {
    try {
      if (step.close case final close?) await close(this);
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .popUntil((route) => route.isFirst);
      for (final provider in [
        selectedChatProvider,
        chatSelectionProvider,
        networkFilterProvider,
        inboxQuickFilterProvider,
        showArchivedProvider,
        labelFilterProvider,
      ]) {
        _container.invalidate(provider);
      }
      await settle();

      // And the inbox's own scroll offset, which is the third kind of state a
      // step can leave behind and the one neither half above touches.
      //
      // The touch shell's header *scrolls away* — the route inventory's "a
      // scrolling header against a toolbar" — so an inbox left part-scrolled is
      // an inbox with no "More" button on it, and every step that opens the
      // overflow menu then fails with `Bad state: No element` about a control
      // that is merely off screen. Invisible at the default pass, where the rows
      // are short enough that nothing scrolls far; at `phone-xl` it took out all
      // sixteen surfaces behind that menu at once, which read as a large-text
      // bug in the app and was this.
      if (_mainScrollable()?.position case final position?
          when position.hasContentDimensions) {
        position.jumpTo(position.minScrollExtent);
        await settle();
      }
    } on Object catch (error) {
      failures.add('${step.label}: could not get back to the inbox — $error');
    }
  }

  /// Opens the first conversation, by whichever gesture this shell uses.
  ///
  /// On touch a tap pushes `ChatView`; in the Mac window it selects into the
  /// third pane, which is already on screen. One helper because six steps start
  /// this way and the difference between the two shells is not theirs to know.
  ///
  /// The *first* row is not the one to tap. `MacScrollEdge` runs the list under
  /// the toolbar and shows it through the glass, which is the whole Tahoe scroll
  /// edge effect — so row zero is partly behind a 52pt toolbar and a tap at its
  /// centre lands on the toolbar. [visible] picks the first row clear of it,
  /// which is also the one a person would click.
  /// Opens a conversation — the first one on screen, or the one called [title].
  ///
  /// Named when the step is about something only *that* conversation has. The
  /// thread step is the case: exactly one demo room carries a forum topic, and
  /// a step that opened whichever row happened to be on top would find no
  /// indicator and fail somewhere other than where the problem is.
  Future<void> openChat({String? title}) async {
    if (title == null) return tap(visible(find.byType(ChatTile)));
    Finder finder() =>
        find.ancestor(of: find.text(title), matching: find.byType(ChatTile));
    if (finder().evaluate().isEmpty) await scrollTo(finder);
    await tap(visible(finder()));
  }

  /// [finder]'s first match that is wholly on screen and not under the Mac
  /// toolbar.
  ///
  /// A tap or a press is delivered at a widget's *centre*, and a widget whose
  /// centre is off screen or behind the toolbar takes neither — silently, since
  /// `warnIfMissed` only reports a miss when the hit test finds nothing at all.
  /// The conversation list and the message list both matter here: the thread
  /// opens scrolled to the newest message, so its first bubble is far above the
  /// viewport.
  Finder visible(Finder finder) {
    final element = _onScreen(finder);
    return element == null ? finder.first : find.byWidget(element.widget);
  }

  /// [finder]'s first wholly-on-screen match, or null when it has none.
  ///
  /// Split out of [visible] because the two answers are different questions and
  /// only one of them can be asked of a `Finder`: [visible] has to return
  /// *something* to tap, so it falls back to the first match even when that
  /// match is off screen. Callers that need to know whether the fallback was
  /// taken — [tapText], so it can scroll further — ask here.
  Element? _onScreen(Finder finder) {
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final top = isMac ? MacMetrics.toolbarHeight : 0.0;
    for (final element in finder.evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.top >= top &&
          rect.bottom <= view.height &&
          rect.left >= 0 &&
          rect.right <= view.width) {
        return element;
      }
    }
    return null;
  }

  /// Opens the settings screen, by whichever door this shell has.
  Future<void> openSettings() async {
    if (isMac) {
      await tapText(_l10n.commonSettings);
    } else {
      await tapTooltip(_l10n.commonMore);
      await tapText(_l10n.commonSettings);
    }
  }

  Future<void> tap(Finder finder) async {
    await tester.tap(finder, warnIfMissed: false);
    await settle();
  }

  Future<void> tapTooltip(String tooltip) => tap(find.byTooltip(tooltip).first);

  /// Taps the control labelled [text], scrolling it into view first.
  ///
  /// The settings screen is a list of twenty rows in a 900pt window, so its
  /// last third — MCP, integrations, the companion surfaces — is below the
  /// fold. Tapping an off-screen `Text` does nothing at all and reports
  /// nothing, which is the quietest possible way for a walk step to lie about
  /// having visited a screen.
  Future<void> tapText(String text) async {
    // Rebuilt on every use, never held. `FinderBase.evaluate` memoises, so a
    // finder that was empty before the scroll stays empty after it — the row
    // arrives on screen and the tap still reports "No element", which reads as
    // a scroll that did not work.
    Finder finder() => find.text(text);
    if (finder().evaluate().isEmpty) await scrollTo(finder);
    await bringOnScreen(finder);
    await tap(visible(finder()));
  }

  /// Scrolls until [finder] is not merely *built* but wholly in the viewport.
  ///
  /// [scrollTo] stops the moment the finder matches, and in a `ListView` a row
  /// is built a little before it can be seen — the cache extent reaches past
  /// the bottom edge. So a row that lands in that band is found, is tapped at a
  /// centre outside the viewport, and takes nothing: `visible` falls back to the
  /// first match, `warnIfMissed` stays quiet because the hit test found *some*
  /// widget, and the step reports "never arrived" about a screen whose door was
  /// never actually pressed.
  ///
  /// That is not hypothetical. It is what adding one row to the settings screen
  /// did to the backup step, and it would have done it to whichever step was
  /// unlucky next — which is the reason this is fixed here rather than by
  /// reordering the list.
  Future<void> bringOnScreen(Finder Function() finder) async {
    if (finder().evaluate().isEmpty || _onScreen(finder()) != null) return;
    await tester.ensureVisible(finder().first);
    await settle();
  }

  /// Scrolls the screen's main list until [finder] matches, or gives up.
  ///
  /// Drives the scroll *position* rather than dragging. `scrollUntilVisible`
  /// works by repeated `drag`, and a drag is a gesture — under a live binding
  /// it needs real time to be recognised the same way a long press does, so it
  /// moved the settings list not at all and reported nothing. Jumping the
  /// position is what a scrollbar does and needs no arena.
  ///
  /// The finder is rebuilt on every turn because `FinderBase.evaluate`
  /// memoises: a finder that was empty before the first jump stays empty
  /// after the last one.
  Future<bool> scrollTo(Finder Function() finder) async {
    final position = _mainScrollable()?.position;
    if (position == null || !position.hasContentDimensions) return false;

    position.jumpTo(position.minScrollExtent);
    await settle();
    for (var step = 0; step < 60; step++) {
      if (finder().evaluate().isNotEmpty) return true;
      if (position.pixels >= position.maxScrollExtent) return false;
      position.jumpTo(
        (position.pixels + 200).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await settle();
    }
    return finder().evaluate().isNotEmpty;
  }

  /// The tallest vertical scroll view on screen, latest first.
  ///
  /// Not `find.byType(Scrollable).first`, which is what this was and which
  /// picked the network rail — a 72pt *horizontal* strip down the edge of the
  /// inbox — and then scrolled it sideways looking for a settings row.
  ///
  /// Ties go to the *last* match rather than the first, which is the other half
  /// of the same bug. A pushed route does not unbuild the one under it, so on
  /// the settings screen the inbox's own list is still in the tree at exactly
  /// the same height; the newer route is later in the overlay, so later in
  /// tree order.
  ScrollableState? _mainScrollable() {
    ScrollableState? best;
    var bestHeight = 0.0;
    for (final element in find.byType(Scrollable).evaluate()) {
      final state = (element as StatefulElement).state as ScrollableState;
      if (state.axisDirection != AxisDirection.down &&
          state.axisDirection != AxisDirection.up) {
        continue;
      }
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize) continue;
      if (box.size.height < bestHeight) continue;
      bestHeight = box.size.height;
      best = state;
    }
    return best;
  }

  /// Holds a control down long enough for a real long-press timer to fire.
  ///
  /// Not [WidgetTester.longPress], and this is the sharpest edge in the file.
  /// That helper holds the pointer for `kLongPressTimeout` of *pumped* time,
  /// which under a live binding is not time at all — the recogniser's timer is
  /// a real one and had not fired when the pointer came back up. The press
  /// therefore resolved as a tap, the step passed for the wrong reason, and the
  /// timer fired afterwards into a gesture arena that had already closed:
  /// every later tap on that same control was swallowed, and the walk failed
  /// four steps later on a screen that had nothing wrong with it.
  ///
  /// So the wait is real, and the pump after it is what lets the frame the
  /// timer scheduled actually draw.
  Future<void> longPress(Finder finder) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    await Future<void>.delayed(kLongPressTimeout + kPressTimeout);
    // Settled *before* the finger comes up, which is both what a person does —
    // hold, look, let go — and what leaves the recogniser's own state machine
    // finished rather than half-way through a tree that has been rebuilt under
    // it.
    await settle();
    await gesture.up();
    await settle();
  }

  /// A right-click, which is what raises a context menu on a machine with a
  /// pointer.
  Future<void> secondaryTap(Finder finder) async {
    await tester.tapAt(
      tester.getCenter(finder),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await settle();
  }

  /// Drags a mouse across the two newest bubbles, the way a reader lifts a
  /// couple of lines out of a thread.
  ///
  /// Its own helper rather than a call to [WidgetTester.drag] for the reason
  /// [longPress] is: a drag is a gesture, and under a live binding the moves
  /// have to arrive over real time or the recogniser never sees a drag at all.
  /// It moves in steps for a second reason — a single jump can pass over every
  /// selectable between the two ends and leave the region holding one edge.
  Future<void> dragSelectMessages() async {
    final rows = bubbles.evaluate().toList();
    if (rows.length < 2) return;
    Rect rectOf(Element element) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    // Newest first in tree order, and the newest is at the bottom of a
    // reversed list — so `rows[1]` is the message above `rows[0]`.
    final from = rectOf(rows[1]).topLeft + const Offset(12, 12);
    final to = rectOf(rows.first).bottomRight - const Offset(12, 12);

    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    for (var step = 1; step <= 6; step++) {
      await gesture.moveTo(Offset.lerp(from, to, step / 6)!);
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await tester.pump();
    }
    await gesture.up();
    await settle();
  }

  /// Types [text] into [field] and presses Return, the way the Mac toolbar's
  /// search field is actually used — it hands its query to the search screen
  /// on submit rather than filtering the list in place.
  Future<void> submitInto(Finder field, String text) async {
    await tester.tap(field, warnIfMissed: false);
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
  }

  /// Dismisses a menu, popover or sheet the way a keyboard does.
  Future<void> escape() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
  }

  Future<void> settle() async {
    try {
      // The third argument is the one that matters, and its default is ten
      // *minutes*. The first is only the interval between pumps — so a screen
      // that never rests does not fall through to the fixed-frame pump below,
      // it hangs the run for ten minutes and then does. Five seconds is longer
      // than any entry animation in the app and short enough that a walk of
      // forty screens cannot quietly become an hour.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    } on FlutterError {
      // A surface that never rests — a typing indicator, an expiry clock, a
      // probe — is one `pumpAndSettle` times out on, and that is not a defect.
      // Fall back to the fixed-frame pump the golden harness uses for exactly
      // the same screens.
      await pumpFrames();
    }
  }

  Future<void> pumpFrames() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Writes what is on screen to the shot directory, if there is one.
  ///
  /// The app's own repaint boundary rather than the root view: a live binding
  /// paints its test scaffolding around the tree, and a record of the run
  /// should show Sennit and not the harness. Failures are logged and swallowed
  /// — a runner with no rasteriser can still answer every other question this
  /// file asks, and losing the images should not lose the audit.
  Future<void> shoot(String label) async {
    final target = shots;
    if (target == null) return;
    try {
      final boundary =
          _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      File(
        p.join(target.path, '$label-${surface.name}${pass.suffix}.png'),
      ).writeAsBytesSync(data.buffer.asUint8List());
    } on Object catch (error) {
      debugPrint('weft: no screenshot for $label — $error');
    }
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.length > 200 ? '${line.substring(0, 200)}…' : line;
  }
}

/// Where the images go.
///
/// `WEFT_SHOT_DIR` wins; otherwise the phase's own working directory, found by
/// walking up for the repository root; otherwise a temp directory whose real
/// path is printed.
///
/// The last case is not a fallback for nothing — it is the macOS run. A macOS
/// app is sandboxed, so a path outside its container is not writable however
/// absolute it looks, and `Directory.current` is not the checkout. Writing
/// nothing and saying nothing would look exactly like a passing run with
/// images in it, which is why this prints where it actually went.
Future<Directory?> _shotDirectory(String override) async {
  Directory? make(String path) {
    try {
      final dir = Directory(path)..createSync(recursive: true);
      // Created is not the same as writable: the sandbox refuses at the write.
      final probe = File(p.join(dir.path, '.weft-writable'))
        ..writeAsStringSync('');
      probe.deleteSync();
      return dir;
    } on FileSystemException catch (error) {
      // Said out loud, because the silent version of this line cost an hour.
      // An unwritable override falls through to [scratch], which on Android is
      // inside the app's own sandbox and is deleted with the app the moment the
      // run finishes uninstalling it — so the run looks like it passed, prints a
      // directory, and leaves no images anywhere a person can reach. Knowing
      // *which* candidate failed and why is the difference between fixing the
      // path and concluding the device cannot screenshot.
      debugPrint('weft: cannot write route-walk images to $path — $error');
      return null;
    }
  }

  /// The app's own directory on the shared volume, which is Android's answer.
  ///
  /// `/sdcard/Android/data/<pkg>/files` cannot be *created* from inside the
  /// sandbox — the parent is not writable, which is what the three
  /// `Permission denied`s above a first attempt at this said — but the platform
  /// will hand it over already made. It is the only place on the device that is
  /// both writable by the app and readable by `adb pull` afterwards, and
  /// "afterwards" is the whole point: `flutter test` uninstalls the app when the
  /// run ends and takes everything under [scratch] with it.
  Future<Directory?> external() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final root = await getExternalStorageDirectory();
      if (root == null) return null;
      return make(p.join(root.path, 'route-walk'));
    } on Object catch (error) {
      debugPrint('weft: no external storage for route-walk images — $error');
      return null;
    }
  }

  Directory? scratch() {
    try {
      final dir = Directory.systemTemp.createTempSync('weft-route-walk-');
      debugPrint('weft: writing route-walk images to ${dir.path}');
      return dir;
    } on FileSystemException {
      return null;
    }
  }

  if (override.isNotEmpty) {
    // Comma-separated, tried in order. One path is the common case; the list is
    // for Android, where the writable spelling of the app's own external
    // directory depends on which of `/sdcard`, `/storage/self/primary` and
    // `/storage/emulated/0` the app's mount namespace resolves — and the only
    // way to find out from here is to try them.
    for (final candidate in override.split(',').map((path) => path.trim())) {
      if (candidate.isEmpty) continue;
      if (make(candidate) case final dir?) return dir;
    }
    return await external() ?? scratch();
  }

  var dir = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    if (Directory(p.join(dir.path, '.git')).existsSync()) {
      return make(
            p.join(
              dir.path,
              '.maestro',
              'playbooks',
              '2026-08-28-Localization-UI-Audit-Features',
              'Working',
              'route-walk',
            ),
          ) ??
          await external() ??
          scratch();
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return await external() ?? scratch();
}
