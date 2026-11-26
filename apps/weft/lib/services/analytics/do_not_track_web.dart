import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The two privacy signals `package:web` does not declare.
extension type _PrivacyNavigator(JSObject _) implements JSObject {
  external JSString? get doNotTrack;
  external JSBoolean? get globalPrivacyControl;
}

/// A browser set to send "Do Not Track" or Global Privacy Control.
///
/// Either one keeps Sennit Web from sending usage statistics, even where the
/// user said yes in the app: the browser setting is the more specific answer.
bool platformAsksNotToTrack() {
  final navigator = _PrivacyNavigator(web.window.navigator);
  if (navigator.doNotTrack?.toDart == '1') return true;
  return navigator.globalPrivacyControl?.toDart ?? false;
}
