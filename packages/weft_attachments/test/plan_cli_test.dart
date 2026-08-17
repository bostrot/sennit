/// End-to-end tests for `bin/plan.dart`.
///
/// The CLI is the one part of this package that touches `dart:io`, so it is the
/// one part that cannot be tested by calling a function: these spawn it as a
/// real process against real files and assert on what it printed and what it
/// exited with. Everything the CLI decides is already covered by
/// `plan_test.dart`; what is covered here is the wiring — argument parsing, the
/// bounded header read, and the exit codes a script would branch on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('weft_attachments_cli');
  });

  tearDownAll(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Writes [bytes] to [name] in the temp directory and returns its path.
  String file(String name, List<int> bytes) {
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  /// Runs the CLI the way `dart run weft_attachments:plan` would.
  ProcessResult run(List<String> argv) => Process.runSync(
    Platform.resolvedExecutable,
    ['run', 'bin/plan.dart', ...argv],
    workingDirectory: Directory.current.path,
  );

  /// The JSON object the CLI printed, which is always the tail of stdout.
  Map<String, Object?> contentOf(ProcessResult result) {
    final out = result.stdout as String;
    final start = out.indexOf('{');
    expect(start, isNonNegative, reason: 'no JSON in output:\n$out');
    return jsonDecode(out.substring(start)) as Map<String, Object?>;
  }

  group('a real file on disk', () {
    test('plans a PNG into an m.image event with the URI under url', () {
      final path = file('shot.png', png(width: 1400, height: 900));

      final result = run([path]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, contains('image/png'));
      expect(result.stdout, contains('MessageKind.image'));
      expect(result.stdout, contains('1400x900'));

      final content = contentOf(result);
      expect(content['msgtype'], 'm.image');
      expect(content['body'], 'shot.png');
      expect(content['url'], startsWith('mxc://'));
      expect(content.containsKey('file'), isFalse);
      final info = content['info']! as Map<String, Object?>;
      expect(info['mimetype'], 'image/png');
      expect(info['w'], 1400);
      expect(info['h'], 900);
    });

    test('--encrypted moves the URI under file.url and nothing else', () {
      final path = file('secret.png', png(width: 1400, height: 900));

      final plain = contentOf(run([path]));
      final encrypted = contentOf(run(['--encrypted', path]));

      expect(encrypted['url'], isNull);
      final block = encrypted['file']! as Map<String, Object?>;
      expect(block['url'], startsWith('mxc://'));
      expect((block['key']! as Map)['k'], isNotEmpty);
      // The two shapes must differ in exactly one place: where the URI lives.
      expect(encrypted['msgtype'], plain['msgtype']);
      expect(encrypted['body'], plain['body']);
    });

    test('rejects an empty file with exit code 2 and says why', () {
      final path = file('nothing.bin', const []);

      final result = run([path]);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('empty'));
      expect(result.stdout, isEmpty);
    });

    test('rejects a file over --max-bytes with exit code 2', () {
      final path = file('big.png', png(width: 10, height: 10));

      final result = run(['--max-bytes=8', path]);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('accepts at most'));
    });

    test('reads only the header, not the whole file', () {
      // A megabyte of PNG: the dimensions still resolve, from the first 24
      // bytes, and the size in the event is the size on disk rather than the
      // slice that was read.
      final bytes = <int>[
        ...png(width: 640, height: 480),
        ...List<int>.filled(1024 * 1024, 0),
      ];
      final path = file('padded.png', bytes);

      final result = run([path]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Header read   64.0 KiB'));
      final info = contentOf(result)['info']! as Map<String, Object?>;
      expect(info['size'], bytes.length);
      expect(info['w'], 640);
    });
  });

  group('arguments', () {
    test('a declared type never beats the bytes', () {
      final path = file('lying.pdf', pdf());

      final result = run(['--mime=*/*', path]);

      expect(result.stdout, contains('overridden by the bytes'));
      expect(contentOf(result)['msgtype'], 'm.file');
      final info = contentOf(result)['info']! as Map<String, Object?>;
      expect(info['mimetype'], 'application/pdf');
    });

    test('--caption moves the filename out of body, per MSC2530', () {
      final path = file('holiday.png', png(width: 10, height: 10));

      final content = contentOf(run(['--caption=at the beach', path]));

      expect(content['body'], 'at the beach');
      expect(content['filename'], 'holiday.png');
    });

    test('--json prints the event content and nothing else', () {
      final path = file('bare.png', png(width: 10, height: 10));

      final out = run(['--json', path]).stdout as String;

      expect(out.trimLeft(), startsWith('{'));
      expect(jsonDecode(out), isA<Map<String, Object?>>());
    });

    test('--help succeeds and an unknown flag does not', () {
      expect(run(['--help']).exitCode, 0);

      final bad = run(['--nope', 'x.png']);
      expect(bad.exitCode, 1);
      expect(bad.stderr, contains('unknown option'));
    });

    test('a missing path and a missing file both exit 1', () {
      expect(run(const []).exitCode, 1);

      final missing = run(['${dir.path}/not-here.png']);
      expect(missing.exitCode, 1);
      expect(missing.stderr, contains('cannot read'));
    });
  });
}
