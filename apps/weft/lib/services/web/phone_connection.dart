/// The browser build's way to its phone. Native builds never call it.
library;

export 'phone_connection_native.dart'
    if (dart.library.js_interop) 'phone_connection_web.dart';
