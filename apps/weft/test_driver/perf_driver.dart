// The driver's own two packages come in with `integration_test`, which is
// declared; naming them a second time in the pubspec would be a second
// constraint on a workspace that resolves as one unit.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Host side of `integration_test/perf/perf_test.dart`; see that file for the
/// command.
///
/// Besides waiting for the run, this reads the VM's CPU samples for the UI
/// isolate once it is over and prints where the time went — which is the half
/// of the answer a frame timing cannot give. A frame that took 40ms says the
/// screen is slow; the sample table says which function made it so, including
/// work that ran *between* frames and so never shows up as a slow build.
///
/// Set `PERF_CPU_TOP` to change how many rows are printed (default 45), or to
/// 0 to skip the table.
Future<void> main() async {
  final driver = await FlutterDriver.connect();
  final vm = driver.serviceClient;
  final isolateId = driver.appIsolate.id!;
  final top = int.tryParse(Platform.environment['PERF_CPU_TOP'] ?? '') ?? 45;

  if (top > 0) await vm.clearCpuSamples(isolateId);

  final raw = await driver.requestData(
    null,
    timeout: const Duration(minutes: 20),
  );
  final response = Response.fromJson(raw);

  if (top > 0) {
    try {
      final samples = await vm.getCpuSamples(isolateId, 0, 1 << 52);
      _report(samples, top);
    } on Object catch (error) {
      stdout.writeln('CPU samples unavailable: $error');
    }
  }

  await driver.close();

  if (response.data != null) {
    final out = File('build/perf_response_data.json')
      ..createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(response.data),
    );
  }
  if (!response.allTestsPassed) {
    stdout.writeln('Failure details:\n${response.formattedFailureDetails}');
    exit(1);
  }
  stdout.writeln('All tests passed.');
}

void _report(vms.CpuSamples samples, int top) {
  final functions = samples.functions ?? const <vms.ProfileFunction>[];

  /// A Dart function's name with its file, or null for a native frame: the
  /// engine's run loop is in every stack and says nothing about the app.
  String? name(int index) {
    final profiled = functions[index];
    final f = profiled.function;
    if (f is! vms.FuncRef) return null;
    final owner = f.owner;
    final ownerName = switch (owner) {
      vms.ClassRef(:final name?) => '$name.',
      _ => '',
    };
    final url = profiled.resolvedUrl ?? '';
    final file = url.isEmpty ? '' : '  (${url.split('/').last})';
    return '$ownerName${f.name}$file';
  }

  final self = <int, int>{};
  final inclusive = <int, int>{};
  var total = 0;
  for (final sample in samples.samples ?? const <vms.CpuSample>[]) {
    final stack = sample.stack;
    if (stack == null || stack.isEmpty) continue;
    total++;
    // The innermost *Dart* frame owns the sample; native leaves (malloc, the
    // GC) are charged to whoever called them.
    for (final index in stack) {
      if (name(index) == null) continue;
      self[index] = (self[index] ?? 0) + 1;
      break;
    }
    for (final index in stack.toSet()) {
      inclusive[index] = (inclusive[index] ?? 0) + 1;
    }
  }
  if (total == 0) {
    stdout.writeln('CPU: no samples');
    return;
  }

  void table(String title, Map<int, int> counts) {
    final rows = [
      for (final entry in counts.entries)
        if (name(entry.key) case final label?) (label, entry.value),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    stdout.writeln(
      'CPU $title — $total samples, ${samples.samplePeriod}µs period',
    );
    for (final (label, count) in rows.take(top)) {
      final pct = (count * 100 / total).toStringAsFixed(1).padLeft(5);
      stdout.writeln('CPU   $pct%  $label');
    }
  }

  table('self', self);
  table('inclusive', inclusive);
}
