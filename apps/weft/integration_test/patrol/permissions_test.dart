import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'support/support.dart';

/// The runtime permission dialogs in the attachment path, answered by the
/// native automator — including the deny that has to leave the app usable.
///
///   ./tooling/scripts/e2e.sh --target integration_test/patrol/permissions_test.dart
///
/// ## The dialog Weft does not raise
///
/// Phase 09's task list asks for "the storage/photos permission dialog". Weft
/// does not have one, and that is worth asserting rather than pretending
/// otherwise. Two independent reasons:
///
/// - **Android.** `AttachmentPicker` calls `ImagePicker().pickMultipleMedia()`,
///   and `ImagePickerAndroid.useAndroidPhotoPicker` defaults to `false` — which
///   Weft never changes — so the intent is `ACTION_GET_CONTENT`. That is the
///   Storage Access Framework: the user picks the file in another app's
///   activity and the grant is per-URI, implicit in the choosing. The manifest
///   declares no `READ_EXTERNAL_STORAGE` and no `READ_MEDIA_IMAGES`, so there is
///   nothing to prompt for on any API level, 28 included.
/// - **iOS.** `PHPickerViewController` runs out of process for exactly the same
///   reason, and needs no `NSPhotoLibraryUsageDescription` prompt.
///
/// So the first scenario asserts the *absence*: opening the gallery raises no
/// permission dialog, and the pick still works. An app that quietly regressed to
/// a permission-gated picker — by turning the photo picker on, or by adding a
/// media permission to the manifest — would start failing it, which is the point.
///
/// The dialog Weft *does* raise in this flow is the camera's. `image_picker`
/// asks for `CAMERA` whenever the manifest declares it, and Weft's does, because
/// calls need it. That is a real system dialog on every Android from 23 up and
/// on iOS, and it is where the grant and deny paths are exercised.
///
/// ## Permission state outlives a test
///
/// A granted permission survives `adb install -r`, and so does a denial. The
/// deny and grant halves are therefore one scenario in one order — deny, check
/// the app survived it, ask again, grant — because that sequence is the only one
/// that is true of a device in any starting state except "already granted".
/// `tooling/scripts/e2e.sh` clears the app before the run for that reason; if
/// this file fails saying no dialog appeared, that clear is what did not happen.
void main() {
  patrolTest(
    'picking from the gallery asks for no permission at all',
    ($) async {
      final scenario = await ChatScenario.start(
        $,
        title: 'Permissions gallery',
      );
      await openChat($, scenario.room.title);

      await chooseAttachmentSource($, 'Photo or video');

      // The picker is another application's activity, so the wait is for the
      // hand-off rather than for a widget: what is being asserted is that
      // nothing stood between the tap and it.
      await awaitForeignWindow($, reason: "the platform's file picker");
      expect(
        await $.platformAutomator.mobile.isPermissionDialogVisible(
          timeout: const Duration(seconds: 3),
        ),
        isFalse,
        reason:
            'the Storage Access Framework grants per URI, so a picker that '
            'prompts is a picker Weft did not mean to open',
      );

      await pickFirstPhoto($);
      await awaitPreviewSheet($);
      await confirmPreviewSend($);
      await awaitDecodedPicture($);

      // Asserted on the peer, because a picker that returned a URI the app
      // cannot read produces a bubble and no upload.
      await scenario.bob.requireAttachment(scenario.room.id);
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );

  patrolTest(
    'the camera permission is denied, the app survives it, then granted',
    ($) async {
      if (await _hasNoCamera($)) {
        markTestSkipped(
          'No camera on this device. An iOS simulator has none at all, and '
          '`UIImagePickerController` cannot be opened on one — the camera rows '
          'of this scenario are not-executed rather than passing.',
        );
        return;
      }

      final scenario = await ChatScenario.start($, title: 'Permissions camera');
      await openChat($, scenario.room.title);

      // --- denied ----------------------------------------------------------

      await chooseAttachmentSource($, 'Camera');
      expect(
        await $.platformAutomator.mobile.isPermissionDialogVisible(
          timeout: kNativeDeadline,
        ),
        isTrue,
        reason:
            'the manifest declares CAMERA, and `image_picker` will not start '
            'the capture intent until it has been granted',
      );
      await $.platformAutomator.mobile.denyPermission();
      await awaitWeftForeground($);

      // The refusal is reported and nothing else happens: no preview sheet, no
      // half-built send, no crash. `pick` throws on a denial and the composer
      // catches it deliberately, because a picker is a method channel and a
      // platform that says no says it that way.
      await pumpUntil(
        $,
        () => showing(find.text('Could not open the picker.')),
        within: kUiDeadline,
        reason: 'Weft to say the picker could not be opened',
      );

      // Usable, which is the whole assertion: a conversation the user is still
      // in, a composer that still sends, and a message that still arrives.
      final afterDenial = uniqueBody('after refusing the camera');
      await sendFromComposer($, afterDenial);
      await awaitBubble($, afterDenial);
      await scenario.bob.requireMessage(scenario.room.id, afterDenial);

      // --- granted ---------------------------------------------------------

      // Asked a second time, which is what a user who changed their mind does.
      // Android shows the dialog again after a single denial; it is the *second*
      // refusal that makes it permanent, and this scenario never gives one.
      await chooseAttachmentSource($, 'Camera');
      expect(
        await $.platformAutomator.mobile.isPermissionDialogVisible(
          timeout: kNativeDeadline,
        ),
        isTrue,
        reason: 'one denial does not silence the prompt',
      );
      await $.platformAutomator.mobile.grantPermissionWhenInUse();

      // The camera app, then the shutter and the confirmation it puts up.
      await $.platformAutomator.mobile.takeCameraPhoto(
        timeout: kNativeDeadline,
      );
      await awaitWeftForeground($);

      await awaitPreviewSheet($);
      await confirmPreviewSend($);
      await awaitDecodedPicture($);

      final photo = await scenario.bob.requireAttachment(scenario.room.id);
      expect(photo.senderId, matrixUserId(kAppUser));
      expect(
        photo.isAttachmentEncrypted,
        isTrue,
        reason:
            'a photo taken by the camera takes the same send path as one '
            'picked from the gallery',
      );
    },
    config: kWeftPatrolConfig,
    timeout: kScenarioTimeout,
  );
}

/// Whether this device has no camera for `image_picker` to open.
///
/// The one branch in this file, and it is about hardware rather than about the
/// app: an iOS simulator has no camera and `UIImagePickerController` refuses the
/// camera source outright, so the scenario has nothing to grant a permission
/// *for*. Android emulators do have an emulated camera and are not skipped.
Future<bool> _hasNoCamera(PatrolIntegrationTester $) async =>
    defaultTargetPlatform == TargetPlatform.iOS &&
    await $.platformAutomator.mobile.isVirtualDevice();
