# ONNX Runtime's native library looks its Java classes up through JNI
# FindClass/GetMethodID at run time; R8 sees no Java-side references and
# strips them, and the first OrtSession.run then aborts the whole process
# with "JNI DETECTED ERROR: java_class == null". Keep the lot.
-keep class ai.onnxruntime.** { *; }

# whisper.cpp's JNI bridge resolves its callback classes the same way.
-keep class com.whisper.** { *; }
-keep class io.github.** { *; }
