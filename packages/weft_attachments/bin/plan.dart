/// Prints exactly what Weft would send for a real file on disk.
///
/// ```sh
/// dart run weft_attachments:plan path/to/file.png --encrypted
/// ```
///
/// This is the only file in the package allowed to touch `dart:io`, and it lives
/// in `bin/` precisely so `lib/` stays pure: everything below is argument
/// parsing, a bounded read of the file's leading bytes, and printing. All of the
/// decisions come from [planUpload], unchanged.
///
/// Only the first [_headerBytes] of the file are read, which is the point — the
/// library is built so that a 400 MB video costs the same to plan as a 4 KB one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:weft_attachments/weft_attachments.dart';

/// How much of the file the CLI reads.
///
/// Generous next to what the probes need (a PNG resolves in 24 bytes) because a
/// faststart MP4 can carry its `moov` box a long way in, and reading 64 KiB of a
/// local file is free.
const int _headerBytes = 64 * 1024;

/// Stand-ins for values that only exist after work this package deliberately
/// does not do: the homeserver assigns the mxc URI, and the key material comes
/// from the crypto layer that encrypts the bytes.
const String _placeholderUri = 'mxc://example.org/AAAAAAAAAAAAAAAAAAAAAAAA';
const String _placeholderThumbnailUri =
    'mxc://example.org/BBBBBBBBBBBBBBBBBBBBBBBB';
const EncryptedFileInfo _placeholderFile = EncryptedFileInfo(
  key: 'PLACEHOLDER-attachment-key-not-real-key-material',
  iv: 'PLACEHOLDERiv0000',
  sha256: 'PLACEHOLDER-sha256-of-the-ciphertext',
);
const EncryptedFileInfo _placeholderThumbnailFile = EncryptedFileInfo(
  key: 'PLACEHOLDER-thumbnail-key-not-real-key-material',
  iv: 'PLACEHOLDERiv0001',
  sha256: 'PLACEHOLDER-sha256-of-the-thumbnail-ciphertext',
);

const String _usage = '''
Usage: dart run weft_attachments:plan [options] <file>

Prints what Weft would do with <file>: the sniffed mime type, the MessageKind,
the dimensions read from the header, the thumbnail decision, and the
m.room.message content that would be sent.

Options:
  --encrypted            Plan for an encrypted room (URI under `file.url`).
  --max-bytes=<n>        Homeserver m.upload.size. 0 or omitted means the limit
                         is unknown, so the size check is skipped.
  --mime=<type>          Mime type the sender claims, as a share intent would.
                         The bytes still win when the two disagree.
  --voice                Treat the file as a recorded voice note.
  --duration-ms=<n>      Playback length; no duration is readable from a header.
  --caption=<text>       Send with a caption (MSC2530).
  --json                 Print only the event content JSON.
  -h, --help             Show this help.

Exit codes: 0 planned, 1 usage or read error, 2 the file was rejected.''';

/// POSIX `EPIPE`, which is what `plan big.png | head` produces.
const int _brokenPipe = 32;

Future<void> main(List<String> argv) async {
  // Guarded rather than wrapped in a `try`: a closed stdout surfaces from the
  // sink's own zone, not through the `await` below, so a `catch` here never
  // sees it.
  await runZonedGuarded(() async {
    exitCode = await _run(argv);
  }, _onUncaught);
}

/// Piping into `head` closes stdout under us. The plan itself succeeded, and a
/// stack trace in place of the output the reader asked for is worse than saying
/// nothing at all. Anything else is a real bug and still reported.
void _onUncaught(Object error, StackTrace stack) {
  if (error is FileSystemException && error.osError?.errorCode == _brokenPipe) {
    return;
  }
  stderr
    ..writeln('weft_attachments:plan: $error')
    ..writeln(stack);
  exitCode = 1;
}

/// Split out from `main` so every exit path is a return value rather than a
/// call to `exit`, which makes the whole CLI reachable from a test.
Future<int> _run(List<String> argv) async {
  final _Args args;
  try {
    args = _Args.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('weft_attachments:plan: ${e.message}');
    stderr.writeln(_usage);
    return 1;
  }

  if (args.help) {
    stdout.writeln(_usage);
    return 0;
  }
  if (args.path == null) {
    stderr.writeln('weft_attachments:plan: expected exactly one file path.');
    stderr.writeln(_usage);
    return 1;
  }

  final AttachmentSource source;
  try {
    source = await _read(args.path!, declaredMimeType: args.mime);
  } on FileSystemException catch (e) {
    final why = e.osError?.message ?? e.message;
    stderr.writeln('weft_attachments:plan: cannot read ${args.path}: $why');
    return 1;
  }

  final decision = planUpload(
    source,
    encrypted: args.encrypted,
    maxUploadBytes: args.maxBytes,
    isVoiceNote: args.voice,
    durationMs: args.durationMs,
    caption: args.caption,
  );

  switch (decision) {
    case UploadRejection(:final reason, :final message):
      // The message is already user-facing; the reason name is for whoever is
      // reading the CLI rather than a chat.
      stderr.writeln('Rejected (${reason.name}): $message');
      return 2;
    case UploadPlan():
      final content = _contentFor(decision);
      if (!args.jsonOnly) _report(source, decision);
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(content));
      return 0;
  }
}

/// Reads at most [_headerBytes] from [path], plus the real length from the
/// filesystem rather than from what was read.
Future<AttachmentSource> _read(String path, {String? declaredMimeType}) async {
  final file = File(path);
  final size = await file.length();
  final handle = await file.open();
  try {
    final header = await handle.read(size < _headerBytes ? size : _headerBytes);
    return AttachmentSource(
      filename: path,
      sizeBytes: size,
      header: Uint8List.fromList(header),
      declaredMimeType: declaredMimeType,
    );
  } finally {
    await handle.close();
  }
}

/// The event content, with the placeholders the plan cannot supply itself.
///
/// The thumbnail block is filled in whenever the plan asks for one so that the
/// `thumbnail_url` / `thumbnail_file` split — the half of the shape that leaks
/// an unencrypted preview when it is wrong — is visible in the output.
Map<String, Object?> _contentFor(UploadPlan plan) {
  final thumbnail = plan.thumbnail;
  return plan.toEventContent(
    uri: _placeholderUri,
    file: plan.encrypted ? _placeholderFile : null,
    thumbnailUri: thumbnail.shouldGenerate ? _placeholderThumbnailUri : null,
    thumbnailFile: thumbnail.shouldGenerate && plan.encrypted
        ? _placeholderThumbnailFile
        : null,
  );
}

/// The human-readable half of the output, on stdout above the JSON.
void _report(AttachmentSource source, UploadPlan plan) {
  final thumbnail = plan.thumbnail;
  stdout
    ..writeln('File          ${plan.filename}')
    ..writeln('Size          ${_bytes(plan.sizeBytes)}')
    ..writeln('Header read   ${_bytes(source.header.length)}')
    ..writeln(
      'Declared      ${source.declaredMimeType ?? '(none)'}'
      '${_conflicts(source, plan) ? '  <- overridden by the bytes' : ''}',
    )
    ..writeln('Mime type     ${plan.mimeType}')
    ..writeln('Kind          MessageKind.${plan.kind.name}')
    ..writeln('Msgtype       ${plan.msgtype}')
    ..writeln(
      'Dimensions    ${plan.dimensions ?? '(not readable from header)'}',
    )
    ..writeln('Duration      ${_duration(plan.durationMs)}')
    ..writeln('Caption       ${plan.caption ?? '(none)'}')
    ..writeln('Thumbnail     ${_thumbnail(thumbnail)}')
    ..writeln('Room          ${plan.encrypted ? 'encrypted' : 'plain'}')
    ..writeln(
      'URI goes to   ${plan.encrypted ? 'file.url' : 'url'}'
      '${plan.isVoiceNote ? '   (voice note: MSC3245 + MSC1767)' : ''}',
    )
    ..writeln('')
    ..writeln(
      'm.room.message content (mxc URIs and key material are '
      'placeholders):',
    );
}

bool _conflicts(AttachmentSource source, UploadPlan plan) {
  final declared = source.declaredMimeType;
  return declared != null && declared != plan.mimeType;
}

String _thumbnail(ThumbnailSpec spec) => spec.shouldGenerate
    ? '${spec.width}x${spec.height} ${spec.mimeType}'
    : 'none';

String _duration(int? ms) => ms == null ? '(not supplied)' : '$ms ms';

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// Hand-rolled rather than pulled from `package:args`, to keep the package's
/// dependency list to the three the library needs.
class _Args {
  _Args({
    required this.path,
    required this.encrypted,
    required this.maxBytes,
    required this.voice,
    required this.jsonOnly,
    required this.help,
    this.mime,
    this.durationMs,
    this.caption,
  });

  /// Throws [FormatException] with a message fit to print for anything it does
  /// not understand — an unrecognised flag is far more likely to be a typo than
  /// a filename.
  factory _Args.parse(List<String> argv) {
    String? path;
    var encrypted = false;
    var voice = false;
    var jsonOnly = false;
    var help = false;
    var maxBytes = 0;
    String? mime;
    int? durationMs;
    String? caption;

    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      String next(String name) {
        final eq = arg.indexOf('=');
        if (eq >= 0) return arg.substring(eq + 1);
        if (i + 1 >= argv.length) {
          throw FormatException('$name needs a value.');
        }
        return argv[++i];
      }

      final name = arg.startsWith('--') && arg.contains('=')
          ? arg.substring(0, arg.indexOf('='))
          : arg;
      switch (name) {
        case '-h':
        case '--help':
          help = true;
        case '--encrypted':
          encrypted = true;
        case '--voice':
          voice = true;
        case '--json':
          jsonOnly = true;
        case '--max-bytes':
          maxBytes = _int(next('--max-bytes'), '--max-bytes');
        case '--duration-ms':
          durationMs = _int(next('--duration-ms'), '--duration-ms');
        case '--mime':
          mime = next('--mime');
        case '--caption':
          caption = next('--caption');
        default:
          if (arg.startsWith('-') && arg != '-') {
            throw FormatException('unknown option $arg.');
          }
          if (path != null) {
            throw const FormatException('expected exactly one file path.');
          }
          path = arg;
      }
    }

    return _Args(
      path: path,
      encrypted: encrypted,
      maxBytes: maxBytes,
      voice: voice,
      jsonOnly: jsonOnly,
      help: help,
      mime: mime,
      durationMs: durationMs,
      caption: caption,
    );
  }

  final String? path;
  final bool encrypted;
  final int maxBytes;
  final bool voice;
  final bool jsonOnly;
  final bool help;
  final String? mime;
  final int? durationMs;
  final String? caption;

  static int _int(String raw, String name) {
    final value = int.tryParse(raw);
    if (value == null) throw FormatException('$name expects a number: $raw.');
    return value;
  }
}
