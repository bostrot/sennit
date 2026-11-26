import 'device_memory_native.dart'
    if (dart.library.js_interop) 'device_memory_web.dart';

/// The phone's (or Mac's) physical memory in bytes, or null where it cannot
/// be read.
///
/// Android exposes it in `/proc/meminfo`; Apple platforms through the
/// `hw.memsize` sysctl. Both are cheap, so this is read whenever it is asked
/// for rather than cached. The web has neither, and no on-device model.
int? deviceMemoryBytes() => platformMemoryBytes();

/// `MemTotal` of a `/proc/meminfo` in bytes, or null when it has none.
int? parseMemTotal(String meminfo) {
  final match = RegExp(
    r'^MemTotal:\s+(\d+)\s*kB',
    multiLine: true,
  ).firstMatch(meminfo);
  final kib = int.tryParse(match?.group(1) ?? '');
  return kib == null ? null : kib * 1024;
}
