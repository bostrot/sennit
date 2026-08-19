/// Attachments on a device: the photo a run seeds into the gallery, the
/// platform pickers Weft opens, the upload bubble, the full-screen viewer, and
/// the system share sheet.
///
/// This is the half of the suite that only exists because of Patrol. The picker
/// Weft opens is another application's activity, the dialog that sometimes
/// stands in front of it belongs to the system, and the sheet the viewer hands
/// a file to is drawn by the OS — none of them is a Flutter widget, so no
/// `flutter test` can see any of them however real its engine is.
///
/// Two facts about Weft's own picker shape everything here, and both were read
/// out of the plugin rather than assumed:
///
/// - **Weft does not use Android's photo picker.** `pickMultipleMedia()` goes
///   through `ImagePickerAndroid`, whose `useAndroidPhotoPicker` defaults to
///   `false` and which Weft never sets — so the intent is `ACTION_GET_CONTENT`
///   with `EXTRA_ALLOW_MULTIPLE`, served by **DocumentsUI** on every API level.
///   Patrol's own default gallery selectors switch to the photo picker's
///   resource ids at API 34, so on the A35 rows they would be looking for a
///   picker Weft never opened. [pickFirstPhoto] taps DocumentsUI directly
///   instead of going through `native.pickImageFromGallery()`.
/// - **Neither picker asks for a permission.** `ACTION_GET_CONTENT` is the
///   Storage Access Framework: the grant is per-URI and implicit in choosing
///   the file, and iOS's `PHPickerViewController` works the same way. Weft
///   declares no storage permission at all. `permissions_test.dart` asserts
///   that absence rather than a dialog the app has never raised.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as sharing;
import 'package:weft/features/chat/attachment_bubble.dart';
import 'package:weft/features/chat/media_viewer.dart';
import 'package:weft/services/attachments/media_exporter.dart';

import '../../../test/support/attachment_fixtures.dart' show kPhoto;
import 'app.dart';
import 'environment.dart';

// ------------------------------------------------------------- what is seeded

/// The photo `tooling/scripts/e2e.sh` puts in the device's gallery.
///
/// An empty gallery is the worst of the available failures: the picker opens on
/// nothing, the tap finds nothing, and the scenario times out sixty seconds
/// later pointing at the picker rather than at the missing file. Seeding it is
/// the host's job — a test process on a device has no `adb` and no `simctl` —
/// so this is the contract between the script and the suite, and it is passed
/// through rather than written twice: the script owns the name, the suite is
/// told it, and the two cannot drift.
const String kSeededPhotoName = String.fromEnvironment(
  'WEFT_SEEDED_PHOTO',
  defaultValue: 'weft-e2e-photo.png',
);

/// A photo written into the app's own cache, for the scenarios that share a
/// file *into* Weft rather than picking one.
///
/// [kPhoto] is the 400x225 fixture the goldens use: a real PNG that a real
/// codec decodes, which is what makes "the picture appeared" a claim about the
/// picture rather than about a placeholder. Registered for deletion here rather
/// than by the caller — a run that leaves files behind on a device leaves them
/// on every row of the matrix.
Future<List<File>> stageSharedPhotos({int count = 1}) async {
  final directory = Directory(
    p.join((await getTemporaryDirectory()).path, 'weft-e2e-share'),
  );
  if (!directory.existsSync()) directory.createSync(recursive: true);

  final files = <File>[];
  for (var i = 0; i < count; i++) {
    final file = File(p.join(directory.path, '${uniqueBody('shared')}.png'))
      ..writeAsBytesSync(kPhoto);
    files.add(file);
  }
  addTearDown(() {
    for (final file in files) {
      if (file.existsSync()) file.deleteSync();
    }
  });
  return files;
}

// ------------------------------------------------------------ the attach flow

/// The composer's Attach button, and the sheet it raises.
///
/// [row] is one of *Photo or video*, *File* or *Camera* — the three rows
/// `showAttachmentSourceSheet` builds, minus whichever the platform cannot
/// honour. The header is also the word "Attach", which is why the button is
/// found by its tooltip and the row by its text: a tooltip is not a `Text`
/// until it is shown, so the two never collide.
Future<void> chooseAttachmentSource(
  PatrolIntegrationTester $,
  String row,
) async {
  await $.tap(find.byTooltip('Attach'));
  await pumpUntil(
    $,
    () => showing(find.text(row)),
    within: kUiDeadline,
    reason: 'the attachment source sheet',
  );
  await $.tap(find.text(row));
}

/// Picks the first item out of whatever picker Weft has just opened.
///
/// Android is tapped directly rather than through `native.pickImageFromGallery`
/// for the reason in this library's header: Weft opens DocumentsUI, and
/// Patrol's defaults look for the photo picker from API 34 up. Tapping the
/// thumbnail is the whole interaction — `EXTRA_ALLOW_MULTIPLE` lets DocumentsUI
/// enter a selection mode, but it is entered by a *long* press, and a single tap
/// still returns the one file.
Future<void> pickFirstPhoto(PatrolIntegrationTester $) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      await $.platformAutomator.mobile.tap(
        Selector(resourceId: _documentsUiThumbnail),
        timeout: kNativeDeadline,
      );
    case TargetPlatform.iOS:
      // `PHPickerViewController`, which is what Patrol's iOS defaults drive.
      await $.platformAutomator.mobile.pickImageFromGallery(
        index: 0,
        timeout: kNativeDeadline,
      );
    case _:
      fail(
        'There is no system gallery to pick from on $defaultTargetPlatform. '
        'The MAC row does not run this scenario; see the applicability table '
        'in docs/quality/e2e-matrix.md.',
      );
  }
}

/// A file's thumbnail in Android's documents picker, in list and grid alike.
const String _documentsUiThumbnail =
    'com.google.android.documentsui:id/icon_thumb';

/// Waits for the confirmation sheet that stands between the picker and the
/// send, and says how many files it is holding.
Future<void> awaitPreviewSheet(
  PatrolIntegrationTester $, {
  int files = 1,
}) async {
  final headline = files == 1 ? 'Send 1 file' : 'Send $files files';
  await pumpUntil(
    $,
    () => showing(find.text(headline)),
    within: kNativeDeadline,
    reason: 'the attachment preview sheet to open on "$headline"',
  );
}

/// The names the preview sheet is showing, read off the one node that carries
/// each file's name unambiguously.
///
/// The Remove button is named per file — `Remove IMG_4021.jpg` — precisely
/// because eight identical "Remove" buttons are eight different consequences to
/// a reader. That makes it the handle a test wants too: the tile's title is a
/// `Text` among several, and the name is the thing being read.
List<String> previewFilenames(PatrolIntegrationTester $) {
  const prefix = 'Remove ';
  return [
    for (final element in find.byType(Tooltip).evaluate())
      if ((element.widget as Tooltip).message case final String message
          when message.startsWith(prefix))
        message.substring(prefix.length),
  ];
}

/// Sends what the preview sheet is holding.
Future<void> confirmPreviewSend(PatrolIntegrationTester $) =>
    $.tap(find.widgetWithText(FilledButton, 'Send'));

// ----------------------------------------------------------- the upload, live

/// The in-flight upload bubble for [filename], if it is on screen.
Finder uploadBubbleFor(String filename) => find.ancestor(
  of: find.text(filename),
  matching: find.byType(UploadProgressBubble),
);

/// What one upload was seen doing.
typedef UploadObservation = ({List<String> statuses, List<int> percentages});

/// Watches [filename]'s upload until its bubble is replaced by a real message.
///
/// Polled at a frame rather than at [pumpUntil]'s default, because the bubble is
/// genuinely short-lived: a 36 KB photo against a homeserver on the same machine
/// is hashed, encrypted, uploaded and echoed in well under a second, and the
/// point of watching is to catch the states rather than to wait out the file.
///
/// The states are collected rather than asserted one at a time, for the same
/// reason `observeDeliveryStates` collects them: which of `Waiting`, `Preparing`
/// and a percentage a test *sees* is a fact about the machine it ran on. What a
/// broken upload cannot do at any speed is report a failure, offer a Retry, or
/// go backwards — and that is what the caller asserts.
Future<UploadObservation> watchUpload(
  PatrolIntegrationTester $,
  String filename, {
  Duration? within,
}) async {
  final statuses = <String>[];
  final percentages = <int>[];
  final limit = within ?? kSyncDeadline;
  final deadline = DateTime.now().add(limit);

  while (DateTime.now().isBefore(deadline)) {
    final bubble = uploadBubbleFor(filename);
    if (showing(bubble)) {
      final status = _statusLineOf($, bubble);
      if (status != null && (statuses.isEmpty || statuses.last != status)) {
        statuses.add(status);
      }
      final percent = _percentOf($, bubble);
      if (percent != null &&
          (percentages.isEmpty || percentages.last != percent)) {
        percentages.add(percent);
      }
    } else if (statuses.isNotEmpty) {
      // Seen, and now gone: the settled event has replaced it.
      return (statuses: statuses, percentages: percentages);
    }
    await $.pump(const Duration(milliseconds: 16));
  }

  fail(
    'The upload of "$filename" never settled within ${limit.inSeconds}s. '
    'Seen: ${statuses.isEmpty ? '<no upload bubble>' : statuses.join(' → ')}',
  );
}

/// The one line under an upload's filename saying what is happening to it.
///
/// The second `Text` of the bubble by construction: the first is the filename
/// and any third is the Retry label, which only exists on a task that has
/// already failed.
String? _statusLineOf(PatrolIntegrationTester $, Finder bubble) {
  final texts = [
    for (final element
        in find.descendant(of: bubble, matching: find.byType(Text)).evaluate())
      (element.widget as Text).data,
  ].whereType<String>().toList();
  return texts.length < 2 ? null : texts[1];
}

/// The progress the bubble is *announcing*, 0–100.
///
/// Read off the semantics value rather than off the bar's geometry, because a
/// `LinearProgressIndicator` carries no semantics of its own and the one here
/// was added deliberately so a reader is told what the bar shows. Reading it is
/// therefore reading the number the app publishes, not measuring a rectangle.
int? _percentOf(PatrolIntegrationTester $, Finder bubble) {
  final bar = find.descendant(
    of: bubble,
    matching: find.byType(LinearProgressIndicator),
  );
  if (!showing(bar)) return null;
  final value = $.tester.getSemantics(bar.first).value;
  final match = RegExp(r'^(\d+)%$').firstMatch(value);
  return match == null ? null : int.parse(match.group(1)!);
}

// ------------------------------------------------------- the settled picture

/// Every decoded picture in the open conversation.
///
/// [MediaAttachment] rather than a semantics label, because on a two-pane row
/// the inbox is on screen too and its row for this conversation describes the
/// same photo in the same words. The `Image` descendant is what separates a
/// decoded picture from the grey box that reserves its shape: the placeholder
/// draws an `Icon` or a spinner, and only real bytes become an `Image`.
final Finder pictureBubbles = find.byType(MediaAttachment);

/// Pictures that have actually decoded, rather than reserved their shape.
final Finder decodedPictures = find.descendant(
  of: pictureBubbles,
  matching: find.byType(Image),
);

/// Waits for a picture in the conversation to finish decoding.
Future<void> awaitDecodedPicture(
  PatrolIntegrationTester $, {
  Duration? within,
}) => pumpUntil(
  $,
  () => showing(decodedPictures),
  within: within ?? kSyncDeadline,
  reason: 'the attachment to arrive and decode into a picture',
);

/// Opens the picture full screen, the way a tap on the bubble does.
Future<void> openFullScreenViewer(PatrolIntegrationTester $) async {
  await $.tap(pictureBubbles.first);
  await pumpUntil(
    $,
    () => showing(find.byType(MediaViewer)),
    within: kUiDeadline,
    reason: 'the full-screen viewer',
  );
}

// -------------------------------------------------------- the native surfaces

/// Waits until a window that is **not** Weft owns the screen, and says whose.
///
/// The suite's one general-purpose assertion about a native surface, and it is
/// deliberately not "the share sheet has a header saying Share": that header is
/// `com.android.intentresolver` on API 34, the framework's own chooser below
/// it, and something else again on iOS — three strings for one fact. What every
/// hand-off has in common is that Weft stopped being the thing on screen, which
/// is checkable on both platforms and on every API level.
Future<Set<String>> awaitForeignWindow(
  PatrolIntegrationTester $, {
  required String reason,
  Duration? within,
}) async {
  final limit = within ?? kNativeDeadline;
  final deadline = DateTime.now().add(limit);
  var seen = <String>{};
  while (DateTime.now().isBefore(deadline)) {
    seen = await _visiblePackages($);
    final foreign = seen.where((package) => package != kAppId).toSet();
    if (foreign.isNotEmpty) return foreign;
    await $.pump(const Duration(milliseconds: 250));
  }
  fail(
    'Weft still owned the screen after ${limit.inSeconds}s, waiting for '
    '$reason. Visible packages: ${seen.isEmpty ? '<none>' : seen.join(', ')}',
  );
}

/// Waits until Weft owns the screen again — the other half of a hand-off.
Future<void> awaitWeftForeground(
  PatrolIntegrationTester $, {
  Duration? within,
}) async {
  final limit = within ?? kNativeDeadline;
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    final packages = await _visiblePackages($);
    if (packages.contains(kAppId)) return;
    await $.pump(const Duration(milliseconds: 250));
  }
  fail('Weft never came back to the foreground within ${limit.inSeconds}s');
}

/// Every application the automator can currently see a window of.
///
/// Split per platform because the two answer with different objects and call
/// the same field two different things — `applicationPackage` against a
/// `bundleId` — and there is no cross-platform view type that carries either
/// outside the automator surface that is on its way out.
Future<Set<String>> _visiblePackages(PatrolIntegrationTester $) {
  final automator = $.platformAutomator;
  return automator.action(
    android: () async {
      final views = await automator.android.getNativeViews(null);
      return {
        for (final root in views.roots)
          if (root.applicationPackage case final String package) package,
      };
    },
    ios: () async {
      final views = await automator.ios.getNativeViews(null);
      return {
        for (final root in views.roots)
          if (root.bundleId case final String bundle) bundle,
      };
    },
  );
}

/// Dismisses whatever native sheet is up, in the way the platform offers.
Future<void> dismissNativeSheet(PatrolIntegrationTester $) async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      await $.platformAutomator.android.pressBack();
    case TargetPlatform.iOS:
      // The activity sheet's own dismissal. iOS has no Back, and a swipe on a
      // sheet whose height varies by content is a gesture with a guess in it.
      await $.platformAutomator.mobile.tap(
        Selector(text: 'Close'),
        timeout: kNativeDeadline,
      );
    case _:
      fail('No native sheet to dismiss on $defaultTargetPlatform');
  }
  await awaitWeftForeground($);
}

// ------------------------------------------------------------- sharing *into*

/// Raises the platform's own share sheet over [files].
///
/// The same call `PlatformMediaExporter.share` makes, and deliberately so:
/// there is no way for a test process *on a device* to fire an arbitrary
/// intent — `am start` needs a shell this binary does not have, and Patrol's
/// automator exposes `openUrl`, which is `ACTION_VIEW`. What it can do is ask
/// the OS to start a share, and then choose Weft out of the chooser with the
/// native automator.
///
/// So the originating application is Weft rather than a third party, and that
/// is the one seam in `share_in_test`. Everything after the tap is the real
/// thing: the system resolves the intent against the manifest's filter, grants
/// a `content://` URI the app cannot otherwise read, starts `MainActivity`, and
/// the platform side hands the payload to Dart. That is the delivery path the
/// scenario is about, and none of it is short-circuited by who asked for it.
///
/// Not awaited: the future completes when the sheet is *dismissed*, which is
/// several taps from here.
void raiseSystemShareSheet(List<File> files) {
  unawaited(
    sharing.SharePlus.instance.share(
      sharing.ShareParams(
        files: [
          for (final file in files)
            sharing.XFile(file.path, mimeType: stagedMimeType(file)),
        ],
      ),
    ),
  );
}

/// Chooses Weft out of the system chooser.
///
/// By the launcher label rather than by an id, because the row is drawn by the
/// chooser out of the manifest's `android:label`. The Direct Share rows above
/// it carry *conversation* titles — Weft publishes them — and every title this
/// suite makes is unique per run, so there is nothing for this to hit by
/// accident.
Future<void> chooseWeftInChooser(PatrolIntegrationTester $) async {
  await $.platformAutomator.mobile.tap(
    Selector(text: kAndroidAppLabel),
    timeout: kNativeDeadline,
  );
}

/// Weft's own share-target sheet: the one it draws when an intent arrives.
final Finder shareTargetSheet = find.text('Share to…');

/// Waits for the share-target sheet, and for it to have finished reading the
/// files out of their grants.
///
/// Both, because they are two different waits: the sheet opens immediately and
/// says *"Reading 3 files…"* while the platform copies each `content://` URI
/// into the cache — which for a video is a real pause — and a test that chose a
/// conversation in between would be choosing one for a share with nothing in it
/// yet.
Future<void> awaitShareTargetSheet(PatrolIntegrationTester $) async {
  await pumpUntil(
    $,
    () => showing(shareTargetSheet),
    within: kNativeDeadline,
    reason: "Weft's share-target sheet to open",
  );
  await pumpUntil(
    $,
    () => !showing(find.textContaining('Reading ')),
    within: kNativeDeadline,
    reason: 'the shared files to be read out of their grants',
  );
}

/// Chooses [title] in the share sheet and sends to it.
///
/// Two steps because the sheet has two: the first tap picks the conversation
/// and moves to the confirmation, where a caption can be written and a merged
/// chat's outgoing network chosen, and the second is the send.
Future<void> shareToChat(PatrolIntegrationTester $, String title) async {
  await pumpUntil(
    $,
    () => showing(find.text(title)),
    within: kSyncDeadline,
    reason: 'the conversation "$title" to be offered as a share target',
  );
  await $.tap(find.text(title).first);

  final send = find.widgetWithText(FilledButton, 'Send to $title');
  await pumpUntil(
    $,
    () => showing(send),
    within: kUiDeadline,
    reason: 'the share confirmation step for "$title"',
  );
  await $.tap(send);
}
