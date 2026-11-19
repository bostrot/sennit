import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:weft_design/weft_design.dart';
import 'package:weft_store/weft_store.dart' show SettingsStore, WeftSettings;

import '../../app/localisation.dart';
import '../../app/stores.dart';
import '../../services/backup/backup_service.dart' show kSennitVersion;

/// The bundled release notes, written by CI before every store and release
/// build — see `tooling/scripts/release_notes.py`.
///
/// The committed file carries an empty version, so a build nobody wrote notes
/// into (`flutter run`, a fork) shows nothing rather than a stale page. Read
/// from the bundle and never from the network: an update is no reason for
/// Sennit to call anyone.
const String kReleaseNotesAsset = 'assets/release_notes.json';

/// Where "All changes" sends someone, for [version].
Uri releasePageFor(String version) =>
    Uri.parse('https://github.com/bostrot/sennit/releases/tag/v$version');

@immutable
class ReleaseNotes {
  const ReleaseNotes({required this.version, required this.notes});

  /// Null for a missing, malformed or empty asset: there is nothing to show.
  static ReleaseNotes? parse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final version = json['version'];
      final notes = json['notes'];
      if (version is! String || notes is! String) return null;
      if (version.isEmpty || notes.trim().isEmpty) return null;
      return ReleaseNotes(version: version, notes: notes.trim());
    } on FormatException {
      return null;
    }
  }

  final String version;

  /// Plain text, one item per line; bullets are already `•`.
  final String notes;
}

final releaseNotesProvider = FutureProvider<ReleaseNotes?>((ref) async {
  try {
    return ReleaseNotes.parse(await rootBundle.loadString(kReleaseNotesAsset));
  } on Object {
    return null;
  }
});

/// The running version, for [WhatsNewGate]. A provider so tests can be a
/// version other than the one in the pubspec.
final appVersionProvider = Provider<String>((_) => kSennitVersion);

/// Records this start's [version] and decides whether it is an update.
///
/// Called once per start, as soon as the settings are open — before sign-in
/// and setup, so a fresh install has recorded its version long before it
/// reaches the inbox and is never mistaken for an update. An install from
/// before this existed has no recorded version; one that finished setup is an
/// update, one that did not is new.
void recordLaunchVersion(SettingsStore settings, String version) {
  final last = settings.getString(WeftSettings.whatsNewLastVersion);
  final existingInstall =
      settings.getBool(WeftSettings.onboardingDone) ||
      settings.getBool(WeftSettings.walkthroughDone);
  final updated = last == null
      ? existingInstall
      : compareVersions(last, version) < 0;
  if (updated) {
    settings.setString(WeftSettings.whatsNewPendingVersion, version);
  }
  if (last != version) {
    settings.setString(WeftSettings.whatsNewLastVersion, version);
  }
}

/// Orders `1.0.9` before `1.0.12`. A part that is not a number counts as 0.
int compareVersions(String a, String b) {
  List<int> parts(String v) =>
      v.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// Shows the release notes once, over [child], on the first start after an
/// update — when [recordLaunchVersion] owes them and the bundle has notes for
/// exactly this version.
class WhatsNewGate extends ConsumerStatefulWidget {
  const WhatsNewGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WhatsNewGate> createState() => _WhatsNewGateState();
}

class _WhatsNewGateState extends ConsumerState<WhatsNewGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    final SettingsStore settings;
    try {
      settings = ref.read(storesProvider).settings;
    } on Object {
      return;
    }
    final version = ref.read(appVersionProvider);
    if (settings.getString(WeftSettings.whatsNewPendingVersion) != version) {
      return;
    }
    final notes = await ref.read(releaseNotesProvider.future);
    // Owed once, shown or not: notes this build does not carry are not going
    // to appear on the next start either.
    settings.remove(WeftSettings.whatsNewPendingVersion);
    if (notes == null || notes.version != version || !mounted) return;
    await showWhatsNewSheet(context, notes);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<void> showWhatsNewSheet(BuildContext context, ReleaseNotes notes) {
  return showWeftPanel<void>(
    context: context,
    showDragHandle: true,
    width: 480,
    builder: (_) => WhatsNewSheet(notes: notes),
  );
}

class WhatsNewSheet extends StatelessWidget {
  const WhatsNewSheet({super.key, required this.notes});

  final ReleaseNotes notes;

  Future<void> _openReleasePage(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.chatLinkNoHandler;
    var opened = false;
    try {
      opened = await launchUrl(
        releasePageFor(notes.version),
        mode: LaunchMode.externalApplication,
      );
    } on Exception {
      opened = false;
    }
    if (!opened) messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final body = context.text.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
      height: 1.4,
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          WeftSpace.xl,
          0,
          WeftSpace.xl,
          WeftSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.whatsNewTitle(notes.version),
                style: context.text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: WeftSpace.xs),
            Text(l10n.whatsNewIntro, style: body),
            const SizedBox(height: WeftSpace.lg),
            // The notes are written once, in English, for the stores and the
            // release page alike; the chrome around them is translated.
            Text(
              notes.notes,
              style: context.text.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: WeftSpace.xl),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.whatsNewDismiss),
            ),
            const SizedBox(height: WeftSpace.xs),
            TextButton.icon(
              onPressed: () => _openReleasePage(context),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(l10n.whatsNewAllChanges),
            ),
          ],
        ),
      ),
    );
  }
}
