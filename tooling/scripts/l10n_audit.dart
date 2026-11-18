/// Finds every user-facing string literal in the app that is still hardcoded.
///
/// Run from the workspace root:
///
/// ```
/// dart run tooling/scripts/l10n_audit.dart
/// ```
///
/// It parses every Dart file under `apps/weft/lib/` and reports string literals
/// that reach a widget the user reads — a `Text`, a tooltip, a semantics label.
/// It also reads the Kotlin under `apps/weft/android/` and the layouts beside
/// it, where the same mistake looks different: a literal passed to
/// `setContentTitle` or written into `android:text` is a string no `values-de/`
/// can reach.
/// Literals already resolved through `context.l10n` are not literals at that
/// point and never appear; that is the whole design, and it is why the number
/// this prints falls as the extraction proceeds and reaches zero when it is
/// done.
///
/// Parsing, not resolving. `parseFile` needs no package config, no build and no
/// analysis context, so the whole app takes about a second — which is what lets
/// this run in CI on every pull request rather than nightly. The cost is that
/// the matcher is syntactic: it knows a constructor is called `Text` and cannot
/// know whether that `Text` is Flutter's. In this codebase nothing else is, and
/// a false positive here costs a line in a work-list rather than a broken build.
///
/// **Exits non-zero when anything is found**, which is what makes it a CI step
/// rather than a report nobody reads. A literal that is deliberately not
/// translated — a product name, a URL, an example identifier — is marked at the
/// call site:
///
/// ```dart
/// // l10n-ignore: the app's own name, never translated.
/// label: 'Sennit',
/// ```
///
/// The reason is required and lands in the inventory, so the exceptions stay a
/// short list somebody can read rather than a growing pile of suppressions.
///
/// Writes `docs/quality/l10n-inventory.md`. See
/// `docs/architecture/l10n-pipeline.md` for what the inventory is for.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

/// Constructors whose *first positional* argument is text the user reads.
const Set<String> _textConstructors = {'Text', 'SelectableText'};

/// Named arguments that carry user-facing text whatever the constructor is.
///
/// Deliberately keyed on the parameter name rather than on
/// `Constructor(param:)` pairs. `title:` is user-facing on an `AppBar`, a
/// `ListTile`, an `AlertDialog`, a `SettingsSectionHeader` and on the next
/// widget someone writes, and enumerating them was always going to lag the
/// codebase by one screen.
const Set<String> _textParameters = {
  // Semantics, and the two Flutter widgets that spell them differently.
  'label', 'hint', 'semanticsLabel', 'tooltip', 'message',
  'onTapHint', 'onLongPressHint',
  // List rows, app bars, dialogs, sheets.
  'title', 'subtitle', 'confirmLabel', 'cancelLabel', 'actionLabel',
  // Text fields.
  'labelText', 'hintText', 'helperText', 'errorText', 'fieldLabel',
  // Empty states and error panels.
  'emptyMessage', 'placeholder',
};

/// Functions whose given positional argument is a sentence shown to the user.
///
/// `showWeftMessage(context, 'Sennit was not allowed to read your contacts.')`
/// is a snack bar, and the literal is as user-facing as any `Text`, but nothing
/// about the syntax says so.
const Map<String, int> _messageFunctions = {
  'showWeftMessage': 1,
  'showWeftError': 1,
};

/// The marker that takes a literal off the list, and the reason it carries.
///
/// On the literal's own line or one of the two above it — an XML attribute
/// cannot carry a comment inside its element's start tag, so the marker for one
/// sits above the tag. The reason is not optional:
/// an unexplained suppression is indistinguishable from an oversight six months
/// later, and this file is the only place anyone will look for the difference.
final RegExp _ignoreMarker = RegExp(
  r'(?://|<!--)\s*l10n-ignore:\s*(.+?)\s*(?:-->)?$',
);

/// A literal that is a machine value rather than a sentence.
///
/// Three shapes, all of which appear as `hint:` on the endpoints screen and
/// none of which a translator should ever be handed: a URL, a bare identifier
/// (`whisper-1`, `text-embedding-3-small`, `llama3.2`), and a hostname. The
/// test is deliberately narrow — anything with a capital or a space is prose
/// again — because "looks technical" would swallow `Sennit` and `SMS`.
bool _isMachineValue(String value) {
  if (RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(value)) return true;
  return RegExp(r'^[a-z0-9][a-z0-9._/:@-]*$').hasMatch(value);
}

/// One hardcoded literal, and where it is.
class Finding {
  Finding({
    required this.path,
    required this.line,
    required this.text,
    required this.reason,
  });

  /// Repo-relative, POSIX-separated.
  final String path;
  final int line;

  /// The literal's source, one line, already shortened for a table cell.
  final String text;

  /// Which rule matched — `Text(...)`, `title:`, and so on.
  final String reason;

  /// Set when a `// l10n-ignore:` marker took this off the list, and carrying
  /// the reason it gave. Reported, never counted.
  String? ignored;

  /// The feature the file belongs to: `features/settings`, `app`, `services/call`.
  String get area {
    final parts = path.split('/');
    final i = parts.indexOf('lib');
    if (i < 0 || i + 2 >= parts.length) return '(root)';
    final head = parts[i + 1];
    // `features/settings` rather than `features`, which would be one row for
    // three hundred findings; `app` rather than `app/localisation.dart`.
    if (i + 3 < parts.length) return '$head/${parts[i + 2]}';
    return head;
  }
}

void main(List<String> args) {
  final root = _repoRoot();
  final libDir = Directory('${root.path}/apps/weft/lib');
  if (!libDir.existsSync()) {
    stderr.writeln(
      'No apps/weft/lib at ${libDir.path}. Run from the workspace root.',
    );
    exit(2);
  }

  final findings = <Finding>[];
  final ignored = <Finding>[];
  var filesScanned = 0;

  final files =
      libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !_isGenerated(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    filesScanned++;
    final relative = _relative(file.path, root.path);
    final unit = parseFile(
      path: file.path,
      featureSet: FeatureSet.latestLanguageVersion(),
      throwIfDiagnostics: false,
    ).unit;
    final visitor = _LiteralVisitor(relative, unit.lineInfo);
    unit.accept(visitor);
    _partition(file, visitor.findings, findings, ignored);
  }

  // The native half. Kotlin and XML get a line scanner rather than a parser:
  // there is no Kotlin AST to hand, the shapes worth catching are a handful of
  // builder calls and one XML attribute, and a regex that is wrong is wrong in
  // the direction of a spurious work-list line.
  for (final native in _nativeFiles(root)) {
    filesScanned++;
    final relative = _relative(native.path, root.path);
    _partition(native, _scanNative(native, relative), findings, ignored);
  }

  findings.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.line.compareTo(b.line);
  });

  ignored.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.line.compareTo(b.line);
  });

  final reportPath =
      _flagValue(args, '--out') ?? 'docs/quality/l10n-inventory.md';
  final report = File('${root.path}/$reportPath')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_renderReport(findings, ignored, filesScanned));

  _printSummary(
    findings,
    ignored,
    filesScanned,
    _relative(report.path, root.path),
  );

  // The whole point of the exit code: a string that reaches a screen and not an
  // ARB file is a regression, and CI has to be able to say so.
  if (findings.isNotEmpty) exit(1);
}

/// Splits [found] into what is still outstanding and what a `// l10n-ignore:`
/// marker has excused, reading the marker off the file's own lines.
void _partition(
  File file,
  List<Finding> found,
  List<Finding> outstanding,
  List<Finding> ignored,
) {
  if (found.isEmpty) return;
  final lines = file.readAsLinesSync();
  for (final finding in found) {
    final own = finding.line - 1;
    for (final i in [own, own - 1, own - 2]) {
      if (i < 0 || i >= lines.length) continue;
      final match = _ignoreMarker.firstMatch(lines[i]);
      if (match != null) {
        finding.ignored = match.group(1)!.trim();
        break;
      }
    }
    (finding.ignored == null ? outstanding : ignored).add(finding);
  }
}

/// Every Kotlin source and Android layout under `apps/weft/android`.
///
/// The `values*/strings.xml` catalogues are skipped: that is where a string is
/// *supposed* to be, and auditing them would report the answer as the problem.
List<File> _nativeFiles(Directory root) {
  final android = Directory('${root.path}/apps/weft/android');
  if (!android.existsSync()) return const [];
  return android
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (f) =>
            f.path.endsWith('.kt') ||
            (f.path.endsWith('.xml') && !f.path.contains('/res/values')),
      )
      .where((f) => !f.path.contains('/build/'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Kotlin builder calls and XML attributes that draw text.
///
/// `setContentTitle("Listening for messages")` is the Android half of a `Text`
/// widget, and `android:text="Recent"` is the same mistake in a layout. Both
/// have an `@string/` form, and this is what says so.
const Map<String, String> _nativePatterns = {
  r'\.setContentTitle\(\s*"([^"]{2,})"': 'setContentTitle(...)',
  r'\.setContentText\(\s*"([^"]{2,})"': 'setContentText(...)',
  r'\.setShortDescription\(\s*"([^"]{2,})"': 'setShortDescription(...)',
  r'\.setSubText\(\s*"([^"]{2,})"': 'setSubText(...)',
  r'\bdescription\s*=\s*"([^"]{2,})"': 'description =',
  r'\bcontentDescription\s*=\s*"([^"]{2,})"': 'contentDescription =',
  r'android:text\s*=\s*"([^"@][^"]*)"': 'android:text',
  r'android:contentDescription\s*=\s*"([^"@][^"]*)"':
      'android:contentDescription',
  r'android:label\s*=\s*"([^"@][^"]*)"': 'android:label',
  r'android:hint\s*=\s*"([^"@][^"]*)"': 'android:hint',
};

List<Finding> _scanNative(File file, String relative) {
  final findings = <Finding>[];
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // A `NotificationChannel(id, name, importance)` positional name would need
    // a parser to find; the builder calls above are what a channel's *words*
    // actually go through, and the third argument is caught by the review that
    // adds one.
    for (final entry in _nativePatterns.entries) {
      final match = RegExp(entry.key).firstMatch(line);
      if (match == null) continue;
      final value = match.group(1)!.trim();
      if (value.isEmpty) continue;
      // `@string/…` and `@plurals/…` are the answer, not the problem: an XML
      // attribute pointing at a resource is exactly what this is asking for.
      if (value.startsWith('@')) continue;
      if (!RegExp('[A-Za-z]').hasMatch(value)) continue;
      if (_isMachineValue(value)) continue;
      findings.add(
        Finding(
          path: relative,
          line: i + 1,
          text: "'$value'",
          reason: entry.value,
        ),
      );
    }
  }
  return findings;
}

/// Walks up from the current directory to the folder holding the workspace
/// pubspec, so the script works from `apps/weft` as well as from the root.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/apps/weft').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

/// Generated Dart is not anyone's to translate, and `lib/l10n/gen` is where the
/// English *is* the ARB — auditing it would report every string in the app back
/// at itself.
bool _isGenerated(String path) =>
    path.contains('/lib/l10n/gen/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart');

String _relative(String path, String root) {
  final p = path.startsWith(root) ? path.substring(root.length) : path;
  return p.replaceAll(r'\', '/').replaceFirst(RegExp('^/'), '');
}

String? _flagValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// Collects the literals, and — as much of the work as anything — decides what
/// is not one.
class _LiteralVisitor extends RecursiveAstVisitor<void> {
  _LiteralVisitor(this.path, this.lineInfo);

  final String path;
  final LineInfo lineInfo;
  final List<Finding> findings = [];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkArguments(node.constructorName.type.name.lexeme, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    // `Text(...)` written without `new` parses as a method invocation only when
    // it is a factory or a function; a constructor call reaches the visitor
    // above. Both are covered so neither spelling escapes.
    _checkArguments(name, node.argumentList);

    final at = _messageFunctions[name];
    if (at != null) {
      final positional = node.argumentList.arguments
          .where((a) => a is! NamedExpression)
          .toList();
      if (at < positional.length) {
        _record(positional[at], '$name(...)');
      }
    }

    // `label: semanticsSentence(['Replying to a message', ...])` is a label
    // built from parts, and the parts are what a screen reader says. The
    // `label:` rule above sees a call, not a literal, so without this every
    // clause inside one was read out in English whatever the app's language.
    if (name == 'semanticsSentence') {
      final parts = node.argumentList.arguments.firstOrNull;
      if (parts is ListLiteral) _recordElements(parts.elements);
    }
    super.visitMethodInvocation(node);
  }

  void _recordElements(Iterable<CollectionElement> elements) {
    for (final element in elements) {
      switch (element) {
        case Expression():
          _record(element, 'semanticsSentence([...])');
        case IfElement(:final thenElement, :final elseElement):
          _recordElements([thenElement, ?elseElement]);
        default:
          break;
      }
    }
  }

  void _checkArguments(String constructor, ArgumentList arguments) {
    final isTextWidget = _textConstructors.contains(constructor);
    for (final argument in arguments.arguments) {
      if (argument is NamedExpression) {
        final name = argument.name.label.name;
        if (_textParameters.contains(name)) {
          _record(argument.expression, '$name:');
        }
      } else if (isTextWidget && argument == arguments.arguments.first) {
        _record(argument, '$constructor(...)');
      }
    }
  }

  void _record(Expression expression, String reason) {
    final literal = _unwrap(expression);
    if (literal == null) return;

    final text = _sourceOf(literal);
    if (!_isProse(literal, text)) return;

    findings.add(
      Finding(
        path: path,
        line: lineInfo.getLocation(literal.offset).lineNumber,
        text: _shorten(text),
        reason: reason,
      ),
    );
  }

  /// The literal inside an expression, or null if there is not one.
  ///
  /// A conditional is unwrapped to *both* branches by the caller being called
  /// twice — that is what the recursion below does for `on ? 'a' : 'b'`, which
  /// is a real shape in the settings screen and two separate strings.
  StringLiteral? _unwrap(Expression expression) {
    if (expression is StringLiteral) return expression;
    if (expression is ConditionalExpression) {
      // Report the branches, then report nothing for the node itself.
      for (final branch in [
        expression.thenExpression,
        expression.elseExpression,
      ]) {
        final inner = _unwrap(branch);
        if (inner != null && _isProse(inner, _sourceOf(inner))) {
          findings.add(
            Finding(
              path: path,
              line: lineInfo.getLocation(inner.offset).lineNumber,
              text: _shorten(_sourceOf(inner)),
              reason: 'ternary branch',
            ),
          );
        }
      }
      return null;
    }
    return null;
  }

  /// Whether a literal is something a translator would be given.
  ///
  /// The rules that matter, in the order they earn their keep:
  ///
  /// - Empty and whitespace-only. `semanticsLabel: ''` is a deliberate *removal*
  ///   of a label, not a missing translation.
  /// - No letters at all. Separators, bullets, `'•'`, `' — '`.
  /// - A single character. Never a sentence, always punctuation or an initial.
  /// - An argument to an `l10n` call. `l10n.showNetworkInAll(network.label)`
  ///   passes data through a translated frame; a literal there is the data.
  bool _isProse(StringLiteral literal, String text) {
    if (_isInsideL10nCall(literal)) return false;

    if (literal is SimpleStringLiteral) {
      final value = literal.value.trim();
      if (value.length < 2) return false;
      if (!RegExp('[A-Za-z]').hasMatch(value)) return false;
      // A URL or a bare identifier is the *value* a field takes, not a sentence
      // about it: `hint: 'whisper-1'` names a model, and translating it would
      // break the request it goes into.
      if (_isMachineValue(value)) return false;
      return true;
    }
    // Interpolations and adjacent strings: judge the source, which still
    // contains the prose around the `$slot`s.
    if (!RegExp('[A-Za-z]').hasMatch(text)) return false;
    return text.replaceAll(RegExp(r'''[\$\{\}'"]'''), '').trim().length >= 2;
  }

  /// Whether the literal sits inside a `context.l10n.x(...)` argument list.
  bool _isInsideL10nCall(AstNode node) {
    for (AstNode? n = node.parent; n != null; n = n.parent) {
      if (n is MethodInvocation) {
        final target = n.target?.toSource() ?? '';
        if (target.endsWith('l10n') || n.methodName.name == 'l10n') return true;
      }
      if (n is InstanceCreationExpression) return false;
    }
    return false;
  }

  String _sourceOf(AstNode node) =>
      node.toSource().replaceAll(RegExp(r'\s+'), ' ');

  String _shorten(String text) {
    // Pipes would split the markdown table cell this ends up in.
    final flat = text.replaceAll('|', r'\|');
    return flat.length <= 110 ? flat : '${flat.substring(0, 107)}…';
  }
}

void _printSummary(
  List<Finding> findings,
  List<Finding> ignored,
  int filesScanned,
  String reportPath,
) {
  final byArea = <String, int>{};
  for (final f in findings) {
    byArea[f.area] = (byArea[f.area] ?? 0) + 1;
  }
  final areas = byArea.keys.toList()
    ..sort((a, b) => byArea[b]!.compareTo(byArea[a]!));

  stdout.writeln('l10n audit — $filesScanned files scanned');
  stdout.writeln('${findings.length} hardcoded user-facing literals remain');
  if (ignored.isNotEmpty) {
    stdout.writeln(
      '${ignored.length} deliberately untranslated — see the report',
    );
  }
  if (areas.isNotEmpty) stdout.writeln('');
  for (final area in areas.take(15)) {
    stdout.writeln('  ${byArea[area]!.toString().padLeft(5)}  $area');
  }
  if (areas.length > 15) {
    stdout.writeln('  ${(areas.length - 15)} more areas — see the report');
  }
  stdout.writeln('');
  stdout.writeln('Report: $reportPath');
}

String _renderReport(
  List<Finding> findings,
  List<Finding> ignored,
  int filesScanned,
) {
  final byArea = <String, List<Finding>>{};
  for (final f in findings) {
    (byArea[f.area] ??= []).add(f);
  }
  final areas = byArea.keys.toList()
    ..sort((a, b) {
      final byCount = byArea[b]!.length.compareTo(byArea[a]!.length);
      return byCount != 0 ? byCount : a.compareTo(b);
    });

  final buffer = StringBuffer()
    ..writeln('---')
    ..writeln('type: analysis')
    ..writeln('title: Localization String Inventory')
    ..writeln('created: 2026-08-28')
    ..writeln('tags: [l10n, i18n, audit]')
    ..writeln("related: ['[[l10n-pipeline]]']")
    ..writeln('---')
    ..writeln()
    ..writeln('# Localization String Inventory')
    ..writeln()
    ..writeln(
      'Generated by `dart run tooling/scripts/l10n_audit.dart`, which CI runs '
      'and which exits non-zero on a single row. Do not edit by hand — rerun '
      'it. Every row is a literal that reaches something the user reads and is '
      'not in a catalogue yet: a Dart widget that should read from '
      '`context.l10n`, or Kotlin and Android XML that should read from '
      '`@string/`. See [[l10n-pipeline]] for how to move one.',
    )
    ..writeln()
    ..writeln(
      '**${findings.length}** hardcoded literals across '
      '**${byArea.length}** areas, in $filesScanned files scanned.',
    )
    ..writeln();

  if (findings.isEmpty) {
    buffer
      ..writeln(
        'Nothing left. Every user-facing string in `apps/weft/lib` is resolved '
        'through `context.l10n`, every one in `apps/weft/android` through '
        '`@string/`, and the only literals below are the ones deliberately '
        'left alone.',
      )
      ..writeln()
      ..write(_renderIgnored(ignored));
    return buffer.toString();
  }

  buffer
    ..writeln('## By area')
    ..writeln()
    ..writeln('| Area | Literals |')
    ..writeln('| --- | ---: |');
  for (final area in areas) {
    buffer.writeln('| `$area` | ${byArea[area]!.length} |');
  }
  buffer
    ..writeln()
    ..writeln('## By file')
    ..writeln()
    ..writeln(
      'Column three is the rule that matched: `Text(...)` is a first positional '
      'argument, `title:` a named one.',
    )
    ..writeln();

  for (final area in areas) {
    buffer
      ..writeln('### `$area` — ${byArea[area]!.length}')
      ..writeln();
    String? currentFile;
    for (final f in byArea[area]!) {
      if (f.path != currentFile) {
        currentFile = f.path;
        buffer
          ..writeln()
          ..writeln('#### `${f.path}`')
          ..writeln()
          ..writeln('| Line | Literal | Matched |')
          ..writeln('| ---: | --- | --- |');
      }
      buffer.writeln('| ${f.line} | `${f.text}` | `${f.reason}` |');
    }
    buffer.writeln();
  }

  buffer.write(_renderIgnored(ignored));

  return buffer.toString();
}

/// The literals a `// l10n-ignore:` marker has excused, as a table.
String _renderIgnored(List<Finding> ignored) {
  if (ignored.isEmpty) return '';
  final buffer = StringBuffer();
  {
    buffer
      ..writeln()
      ..writeln('## Deliberately untranslated')
      ..writeln()
      ..writeln(
        'Marked with `// l10n-ignore:` at the call site. Not outstanding work: '
        'each is a value rather than a sentence — a product name, an example '
        'identifier, a fixture — and the reason is the one the marker gives.',
      )
      ..writeln()
      ..writeln('| File | Line | Literal | Why |')
      ..writeln('| --- | ---: | --- | --- |');
    for (final f in ignored) {
      buffer.writeln(
        '| `${f.path}` | ${f.line} | `${f.text}` | ${f.ignored} |',
      );
    }
  }
  return buffer.toString();
}
