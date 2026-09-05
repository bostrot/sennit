// Appends a batch of new strings to every ARB file at once.
//
// Extraction adds one key to six files: the `app_en.arb` template with its
// `@key` description block, and five translations. By hand that is six edits
// per string which must not drift apart, and a key that lands in five files
// out of six fails `l10n_test.dart` rather than the build — a slower way to
// find out.
//
// A batch is a JSON list, one object per string:
//
//     [
//       {
//         "key": "inboxNewChat",
//         "desc": "Tooltip on the compose button ...",
//         "en": "New chat",
//         "es": "Chat nuevo", "de": "Neuer Chat",
//         "fr": "Nouvelle discussion", "pt": "Nova conversa", "zh": "新聊天",
//         "ph": {"name": {"type": "String", "description": "...", "example": "Anna"}}
//       }
//     ]
//
// `ph` is optional and becomes the template's `placeholders` metadata; the
// translations never carry it, nor a description. Run as:
//
//     dart run tooling/scripts/l10n_merge.dart batch.json
//
// The batch is spliced in as text before each file's closing brace rather than
// being re-encoded from a decoded map, because the template's blank-line
// grouping is written for the human reading it and a round-trip would flatten
// it. Appending a key that already exists is an error: overwriting one
// silently is how a reviewed translation gets replaced by a machine-seeded
// one. See `docs/architecture/l10n-pipeline.md`.
import 'dart:convert';
import 'dart:io';

const _locales = ['en', 'es', 'zh', 'pt', 'de', 'fr'];
const _arbDir = 'apps/weft/lib/l10n';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run tooling/scripts/l10n_merge.dart <batch.json>',
    );
    exit(64);
  }

  final batch = (jsonDecode(File(args.single).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  for (final locale in _locales) {
    final file = File('$_arbDir/app_$locale.arb');
    final source = file.readAsStringSync();
    final existing = (jsonDecode(source) as Map<String, dynamic>).keys.toSet();

    final block = StringBuffer();
    for (final entry in batch) {
      final key = entry['key'] as String;
      if (existing.contains(key)) {
        stderr.writeln('app_$locale.arb already has "$key"');
        exit(1);
      }
      final value = entry[locale] as String?;
      if (value == null) {
        stderr.writeln('$key: no $locale translation');
        exit(1);
      }
      block.writeln(',');
      block.write('  ${jsonEncode(key)}: ${jsonEncode(value)}');
      if (locale != 'en') continue;
      final meta = <String, dynamic>{'description': entry['desc']};
      if (entry['ph'] != null) meta['placeholders'] = entry['ph'];
      final encoded = const JsonEncoder.withIndent('  ').convert(meta);
      block.writeln(',');
      block.write('  ${jsonEncode('@$key')}: ${_indent(encoded)}');
    }

    // Everything up to the last `}` is the file minus its closing brace; the
    // last entry before it keeps whatever trailing whitespace it had.
    final close = source.lastIndexOf('}');
    final body = source.substring(0, close).trimRight();
    file.writeAsStringSync('$body$block\n}\n');
  }

  stdout.writeln(
    'appended ${batch.length} strings to ${_locales.length} files',
  );
}

/// Re-indents an encoded `@key` block so its inner lines sit under the key.
String _indent(String encoded) => encoded.split('\n').join('\n  ');
