/// Whether the platform asks apps not to track. Only a browser says so.
library;

export 'do_not_track_native.dart'
    if (dart.library.js_interop) 'do_not_track_web.dart';
