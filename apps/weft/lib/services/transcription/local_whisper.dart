/// On-device transcription: whisper.cpp natively, and an honest refusal in
/// the browser build, which cannot load a native library. The browser never
/// has a model installed, so the provider that picks this is never reached
/// there; the split exists so the native bindings stay out of that build.
library;

export 'local_whisper_provider.dart'
    if (dart.library.js_interop) 'local_whisper_web.dart';
