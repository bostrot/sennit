import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'device_memory.dart' show parseMemTotal;

/// [deviceMemoryBytes] where there is a `dart:io` and a `dart:ffi`.
int? platformMemoryBytes() {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      return parseMemTotal(File('/proc/meminfo').readAsStringSync());
    }
    if (Platform.isIOS || Platform.isMacOS) return _sysctlMemsize();
  } on Object catch (error) {
    debugPrint('weft: device memory: ${error.runtimeType}');
  }
  return null;
}

typedef _SysctlNative =
    Int32 Function(
      Pointer<Utf8> name,
      Pointer<Void> oldp,
      Pointer<Size> oldlenp,
      Pointer<Void> newp,
      Size newlen,
    );
typedef _SysctlDart =
    int Function(
      Pointer<Utf8> name,
      Pointer<Void> oldp,
      Pointer<Size> oldlenp,
      Pointer<Void> newp,
      int newlen,
    );

int? _sysctlMemsize() {
  final sysctlbyname = DynamicLibrary.process()
      .lookupFunction<_SysctlNative, _SysctlDart>('sysctlbyname');
  return using((arena) {
    final name = 'hw.memsize'.toNativeUtf8(allocator: arena);
    final value = arena<Uint64>();
    final length = arena<Size>()..value = sizeOf<Uint64>();
    final result = sysctlbyname(name, value.cast(), length, nullptr, 0);
    return result == 0 ? value.value : null;
  });
}
