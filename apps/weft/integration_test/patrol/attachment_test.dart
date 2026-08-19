import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:weft/features/chat/media_viewer.dart';
import 'package:weft_domain/weft_domain.dart';
import 'package:weft_matrix/weft_matrix.dart';

import 'support/support.dart';

/// A photo from the device's own gallery, all the way to the peer and back out.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/attachment_test.dart
///
/// The picker is the reason this is a Patrol test rather than an
/// `integration_test`. `../attachment_flow_test.dart` already drives the send
/// loop against a real engine — the header slice, the plan, the queue, the
/// progress stream, the settled bubble and the viewer — and it fakes exactly one
/// step, because a real picker is another application's activity and a widget
/// test cannot dismiss one. That step is what runs here for real.
///
/// **The gallery must not be empty.** `tooling/scripts/e2e.sh` pushes
/// [kSeededPhotoName] onto the device and registers it with the media store
/// before `patrol test` starts; a test process on a device has neither `adb` nor
/// `simctl`, so it cannot seed one for itself. An empty gallery is the worst of
/// the available failures — the picker opens on nothing and the scenario times
/// out pointing at the picker rather than at the missing file.
///
/// Every scenario asserts on the **peer's** received event as well as on the
/// screen. An upload that fails after the event is composed produces an
/// `m.image` with no file behind it and a perfectly convincing local bubble;
/// `requireAttachment` insists on the `url`/`file` block that only a real
/// upload puts there.
void main() {
  patrolTest(
    'a photo picked from the device gallery reaches the peer encrypted',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Attachments');
      await openChat($, scenario.room.title);

      await chooseAttachmentSource($, 'Photo or video');
      await pickFirstPhoto($);

      // The confirmation between the picker and the send. It names the file,
      // which is how the rest of this scenario refers to it: the name is the
      // content provider's to choose, not the test's.
      await awaitPreviewSheet($);
      final filename = previewFilenames($).single;
      expect(
        filename,
        isNotEmpty,
        reason: 'the preview names the file it is about to send',
      );
      await confirmPreviewSend($);

      // The bubble that stands in for the message while the file is going up.
      final upload = await watchUpload($, filename);
      expect(
        upload.statuses,
        isNotEmpty,
        reason:
            'the upload has to be visible while it happens — hashing, '
            'encrypting and uploading are not instantaneous, and a send that '
            'showed nothing at all until the event landed would be a send the '
            'user cannot tell from a dropped one',
      );
      expect(
        upload.statuses,
        isNot(contains('Cancelled')),
        reason: 'nothing cancelled this upload',
      );
      expect(
        showing(find.widgetWithText(TextButton, 'Retry')),
        isFalse,
        reason: 'a Retry button means the queue gave up and said so',
      );
      _expectNonDecreasing(upload.percentages);

      // And the settled attachment, decoded from bytes that came back down.
      await awaitDecodedPicture($);

      // The half that cannot be faked locally.
      final received = await scenario.bob.requireAttachment(scenario.room.id);
      expect(received.senderId, matrixUserId(kAppUser));
      expect(
        received.isAttachmentEncrypted,
        isTrue,
        reason:
            'the file itself has to have gone up encrypted, not just the '
            'event describing it',
      );

      // Read the way the peer's own screen would read it, through the same
      // mapper the app uses.
      final room = await scenario.bob.awaitRoom(scenario.room.id);
      final mapped = mapEvent(
        received,
        network: networkForRoom(room),
        ownUserId: scenario.bob.client.userID,
        timeline: await scenario.bob.timeline(scenario.room.id),
      );
      expect(mapped, isNotNull);
      expect(mapped!.kind, MessageKind.image);
      expect(mapped.attachmentUrl, isNotNull);
      expect(mapped.isOwn, isFalse);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'the sent photo opens full screen and can be handed back to the platform',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Attachment viewer');
      await openChat($, scenario.room.title);

      await chooseAttachmentSource($, 'Photo or video');
      await pickFirstPhoto($);
      await awaitPreviewSheet($);
      await confirmPreviewSend($);
      await awaitDecodedPicture($);

      // Asserted before the viewer is opened, because it is the reason the peer
      // matters at all: what fills the screen next is fetched and decrypted from
      // the homeserver, and a viewer over a file that never arrived would still
      // hero the thumbnail it was given.
      await scenario.bob.requireAttachment(scenario.room.id);

      await openFullScreenViewer($);
      await pumpUntil(
        $,
        () => showing(
          find.descendant(
            of: find.byType(MediaViewer),
            matching: find.byType(Image),
          ),
        ),
        within: kSyncDeadline,
        reason: 'the full-screen picture to be staged and decoded',
      );

      // Save is *absent* on a phone, and that is the app being right rather
      // than the test giving up. `MediaExporter.canSave` is false on Android and
      // iOS because `file_selector` has no save dialog there — the system share
      // sheet is how a file reaches Files or Photos — and the viewer reads that
      // flag instead of offering a button that throws when tapped. Saving back
      // out on a device *is* Share.
      expect(
        showing(find.byTooltip('Save')),
        isFalse,
        reason:
            'a mobile Weft has no save destination to offer; the export path '
            'is the platform share sheet',
      );

      await $.tap(find.byTooltip('Share'));
      final sheet = await awaitForeignWindow(
        $,
        reason: 'the system share sheet the viewer hands the file to',
      );
      expect(
        sheet,
        isNotEmpty,
        reason: 'the OS drew something over Weft, which is the hand-off',
      );

      // Left as it was found: a sheet still up is the next scenario's first
      // failure, on a screen it has no reason to look at.
      await dismissNativeSheet($);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'a photo shares the conversation with the text around it',
    ($) async {
      final scenario = await ChatScenario.start($, title: 'Attachment order');
      await openChat($, scenario.room.title);

      // Text first, then the file, then text again. The ordering assertion is
      // worth making on a device because the two go out through different
      // paths — `send` is one request, `sendAttachment` is an upload queue —
      // and the queue returning on *acceptance* is what is supposed to keep
      // them in the order the user did them.
      final before = uniqueBody('before the photo');
      await sendFromComposer($, before);
      await awaitBubble($, before);

      await chooseAttachmentSource($, 'Photo or video');
      await pickFirstPhoto($);
      await awaitPreviewSheet($);
      await confirmPreviewSend($);
      await awaitDecodedPicture($);

      final after = uniqueBody('after the photo');
      await sendFromComposer($, after);
      await awaitBubble($, after);

      final image = await scenario.bob.requireAttachment(scenario.room.id);
      final first = await scenario.bob.requireMessage(scenario.room.id, before);
      final last = await scenario.bob.requireMessage(scenario.room.id, after);

      expect(
        first.originServerTs.isAfter(image.originServerTs),
        isFalse,
        reason: 'the photo was picked after the first message was sent',
      );
      expect(
        last.originServerTs.isBefore(image.originServerTs),
        isFalse,
        reason: 'the photo was sent before the last message was typed',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

/// Asserts an upload's announced progress only ever went forward.
///
/// Not "these exact percentages": which ticks a test observes depends on the
/// size of the file and the speed of the machine, and a 36 KB photo against a
/// homeserver on the same host may report one. What a broken upload cannot do,
/// at any speed, is go backwards — which is what a queue that restarts a
/// transfer while still showing the old task's bar looks like from outside.
void _expectNonDecreasing(List<int> percentages) {
  var previous = -1;
  for (final percent in percentages) {
    expect(
      percent,
      greaterThanOrEqualTo(previous),
      reason: 'upload progress went backwards: ${percentages.join(' → ')}',
    );
    previous = percent;
  }
}
