import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:weft/services/attachments/attachment_picker.dart';

/// Which Android picker "send a photo" opens.
///
/// `image_picker` asks for the photo library either way; how it gets there is a
/// flag that defaults to off, and off means `ACTION_GET_CONTENT` — the
/// documents browser. So the button that says photos opened a file manager at
/// Downloads, with the gallery several taps further on. The flag is easy to
/// lose again in a plugin upgrade and impossible to notice in a widget test, so
/// it is asserted rather than trusted.
void main() {
  test('picking media asks Android for the system photo picker', () async {
    final android = ImagePickerAndroid();
    ImagePickerPlatform.instance = android;
    expect(
      android.useAndroidPhotoPicker,
      isFalse,
      reason: 'the plugin default, and the thing being corrected',
    );

    // The pick itself needs a platform channel and will throw; the flag is set
    // before that happens, which is the whole of what this pins.
    try {
      await const PlatformAttachmentPicker().pick(AttachmentPickSource.media);
    } on Object {
      // A missing plugin, as expected off-device.
    }

    expect(android.useAndroidPhotoPicker, isTrue);
  });
}
