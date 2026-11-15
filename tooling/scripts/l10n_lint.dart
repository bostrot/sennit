/// Checks the translations against the template, mechanically.
///
/// Run from the workspace root:
///
/// ```
/// dart run tooling/scripts/l10n_lint.dart
/// ```
///
/// Its sibling `l10n_audit.dart` asks whether a string reached a catalogue at
/// all. This asks whether the string that reached it is *usable*: whether the
/// translation still carries the placeholders the call site passes, whether its
/// ICU parses, whether it was translated at all, and whether it fits the space
/// the widget has. None of those is visible in a diff, and all of them are
/// invisible in English.
///
/// Eight checks, and each catches something a human reviewer reliably misses:
///
/// * **`missing-key` / `extra-key`** — key parity with the template.
///   `l10n_test.dart` checks this too; repeating it here costs a set
///   comparison and means the lint is worth running on its own.
/// * **`placeholder`** — the placeholder *set* differs from the template's.
///   A dropped `{name}` compiles, ships, and reads as a sentence with a hole
///   in it. Compared after an ICU parse, so a plural's branch text is not
///   mistaken for an argument.
/// * **`icu`** — the message does not parse: an unbalanced brace, a plural
///   with no branches. `gen-l10n` catches most of these, but only for the
///   locales it generates, and only once the ARB is otherwise valid.
/// * **`untranslated`** — byte-identical to English. Most are legitimate
///   (`SMS`, `{count}`, `Bluetooth`), which is why the rule allows anything
///   that is pure placeholders and punctuation, plus [_neverTranslated];
///   what is left is a string a machine pass skipped.
/// * **`too-long`** — wider than the template's `@key.maxLength`. See
///   [_visualWidth]: the budget is about *space*, so a CJK glyph counts two
///   columns and a combining mark none, and an ICU message is measured at its
///   widest branch rather than at its source length.
/// * **`fr-spacing`** — French needs a non-breaking space before `: ; ! ?` and
///   inside `« »`, and an ordinary space there is both wrong and a line-break
///   opportunity in the wrong place.
/// * **`zh-traditional`** — a Traditional character in `app_zh.arb`, which is
///   Simplified. See [_traditionalOnly].
/// * **`zh-plural`** — Chinese has one plural category. An `=1`/`one` branch
///   in `app_zh.arb` is a branch that can never be selected, and its presence
///   means somebody translated the English structure rather than the message.
///
/// **Exits non-zero on any finding**, so it is a gate rather than a report.
///
/// See `docs/architecture/l10n-pipeline.md` and `docs/TRANSLATING.md`.
library;

import 'dart:convert';
import 'dart:io';

/// Where the catalogues live, relative to the workspace root.
const String _arbDir = 'apps/weft/lib/l10n';
const String _templateLocale = 'en';

/// Per-locale exceptions to the `untranslated` rule, each with its reason.
const String _allowFile = '$_arbDir/lint_allow.json';

/// Strings a translation is allowed to leave in English.
///
/// Product names, protocol names and units. Everything else that comes back
/// byte-identical is a string the translator's eye slid over — which is the
/// failure this check exists for, and an allowlist that grows to cover it
/// would delete the check instead.
const Set<String> _neverTranslated = {
  'Sennit',
  'Matrix',
  'MCP',
  'SMS',
  'RCS',
  'MMS',
  'PDF',
  'Push',
  'Bluetooth',
  'OK',
  'Home Assistant',
  'paperless-ngx',
  'UnifiedPush',
  'Sam',
  'Original',
  // The paid tier's name, like Sennit itself.
  'Pro',
};

/// French: a non-breaking space belongs before each of these.
const String _nbsp = ' ';
const String _narrowNbsp = ' ';

/// Characters that exist only in Traditional Chinese.
///
/// `app_zh.arb` is Simplified — the `@@x-variant` line says so, and a device
/// asking for `zh-Hant` gets it because there is nothing else to give. A
/// Traditional character in it is therefore always a mistake, and always one
/// nobody who does not read Chinese can see in a diff.
///
/// Every entry here has a *different* Simplified form. That is the whole
/// selection rule, and it is why the list cannot be extended by eye: 息, 案,
/// 行 and 束 look Traditional to a reader who does not know better and are
/// spelled identically in both.
const String _traditionalOnly =
    '們個來時這說話讀語訊發開關聯絡歡樂號碼設備網選項確認檔錄製機構學習於將實現產內權對畫聲斷還經過覺總數線電腦視頻連結資軟體歷鍵錯誤變單樣義議傳處遠營運業務準當頁載閉啟執兒區靜檢驗歸稱擇擊標籤刪複貼尋幫幾點動應間顯螢盤掃攝續換讓誰為從買賣費貨質銀錢鐘針鎖門問聞閱際隨險陸陽陰雲靈頭顏願類風飛飯館馬髮魚鳥麗齊龍龜億儀償優傷債僅側偽兩冊淨凍劃劇剛創劍勞勢勵勸匯華協場圖團園圓國壓墳壞夢奮婦孫寧寫寬導屬層島崗廠廢廣廳彈彌徑復態憂慶憲懷戰戶護掛揀損據擁擔攔敵斂曆極樓樹橋歐歲殘殺氣決溫滅滿漢潔濟濤濕瀉災熱燈燒爺牽獨獲獻環畢異療盡監眾睜矯礦禮種積窪竊競筆節範築簡籃糧級紀紅納純紙細終組統絲綠維綜緊緣編縣縮績織繼罰罷羅聖聰職聽肅臉臨舉舊藝藥蘇蘭蟲蠻補裝見規覽觀觸訂計討訓記許訴診註評詞試詩詳誠誌誘課調談請論諸謀講謝證識譯讚豐財責貧貪販賀賊賓賠賞賦賺購贈贊贏車軍軌軒較輔輕輛輪輸轉農迴適遲遷邊鄉鄰醜醫釋鋼鍋鎮鏡鐵鑰長陣隊階隱雖雙雜難霧韓響頂順預領題顧飄養餘驚髒鬥鮮鹽麼黃黨齒';

class Finding {
  Finding(this.locale, this.key, this.rule, this.detail);

  final String locale;
  final String key;
  final String rule;
  final String detail;

  @override
  String toString() => '$locale  $key  [$rule] $detail';
}

void main(List<String> args) {
  final dir = Directory(_arbDir);
  if (!dir.existsSync()) {
    stderr.writeln(
      'No $_arbDir. Run this from the workspace root, not from apps/weft.',
    );
    exit(2);
  }

  final template = _readArb('$_arbDir/app_$_templateLocale.arb');
  final templateKeys = template.keys.where((k) => !k.startsWith('@')).toSet();
  final allow = _readArb(_allowFile);

  final findings = <Finding>[];
  final locales = <String>[];

  for (final file
      in dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path))) {
    final name = file.uri.pathSegments.last;
    if (!name.startsWith('app_') || !name.endsWith('.arb')) continue;
    final locale = name.substring(4, name.length - 4);
    if (locale == _templateLocale) continue;
    locales.add(locale);
    final allowed = allow[locale];
    findings.addAll(
      _lintLocale(
        locale,
        _readArb(file.path),
        template,
        templateKeys,
        allowed is Map ? allowed.keys.cast<String>().toSet() : const <String>{},
      ),
    );
  }

  _report(findings, locales, templateKeys.length);
  exit(findings.isEmpty ? 0 : 1);
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

String _sorted(Set<String> values) => (values.toList()..sort()).join(', ');

Map<String, dynamic> _readArb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

List<Finding> _lintLocale(
  String locale,
  Map<String, dynamic> arb,
  Map<String, dynamic> template,
  Set<String> templateKeys,
  Set<String> allowedUntranslated,
) {
  final findings = <Finding>[];
  final keys = arb.keys.where((k) => !k.startsWith('@')).toSet();

  for (final key in templateKeys.difference(keys).toList()..sort()) {
    findings.add(Finding(locale, key, 'missing-key', 'not in this locale'));
  }
  for (final key in keys.difference(templateKeys).toList()..sort()) {
    findings.add(Finding(locale, key, 'extra-key', 'not in the template'));
  }

  for (final key in (templateKeys.intersection(keys).toList()..sort())) {
    final source = template[key] as String;
    final translated = arb[key] as String;
    final attrs = template['@$key'] as Map<String, dynamic>?;

    final Message? parsedSource = _parse(source);
    final Message? parsed = _parse(translated);
    if (parsed == null) {
      findings.add(Finding(locale, key, 'icu', 'does not parse: $translated'));
      continue;
    }

    if (parsedSource != null &&
        !_sameSet(parsedSource.arguments, parsed.arguments)) {
      findings.add(
        Finding(
          locale,
          key,
          'placeholder',
          'template has {${_sorted(parsedSource.arguments)}}, '
              'translation has {${_sorted(parsed.arguments)}}',
        ),
      );
    }

    if (translated == source &&
        !allowedUntranslated.contains(key) &&
        !_mayStayEnglish(source, attrs)) {
      findings.add(
        Finding(locale, key, 'untranslated', 'identical to English: $source'),
      );
    }

    final budget = attrs?['maxLength'];
    if (budget is int) {
      final examples = _examples(attrs);
      final widest = parsed
          .renderings(examples)
          .map(_visualWidth)
          .fold<int>(0, (a, b) => a > b ? a : b);
      if (widest > budget) {
        findings.add(
          Finding(
            locale,
            key,
            'too-long',
            '$widest columns, budget $budget: $translated',
          ),
        );
      }
    }

    if (locale == 'fr') {
      final where = _frenchSpacingProblem(translated);
      if (where != null) {
        findings.add(Finding(locale, key, 'fr-spacing', '$where: $translated'));
      }
    }

    if (locale == 'zh') {
      final traditional = translated.split('').where(_traditionalOnly.contains);
      if (traditional.isNotEmpty) {
        findings.add(
          Finding(
            locale,
            key,
            'zh-traditional',
            'Traditional characters in a Simplified catalogue: '
                '${traditional.toSet().join()}',
          ),
        );
      }
      final extra = parsed.pluralCategories.difference({'other'});
      if (extra.isNotEmpty) {
        findings.add(
          Finding(
            locale,
            key,
            'zh-plural',
            'Chinese has only "other"; found ${_sorted(extra)}',
          ),
        );
      }
    }
  }

  return findings;
}

/// True when leaving [source] in English is not evidence of a skipped string.
///
/// Two shapes qualify. A message made only of placeholders and punctuation
/// (`{network} · {id}`, `{count}`) has no words to translate. And a message
/// whose every word is in [_neverTranslated] is a name, not a sentence.
bool _mayStayEnglish(String source, Map<String, dynamic>? attrs) {
  final description = attrs?['description'] as String? ?? '';
  if (RegExp(
    'not translated|never translated|literal syntax|as they are',
    caseSensitive: false,
  ).hasMatch(description)) {
    return true;
  }
  final words = RegExp(r"[A-Za-z][A-Za-z'’-]*");
  final stripped = source.replaceAll(RegExp(r'\{[^{}]*\}'), '');
  final found = words.allMatches(stripped).map((m) => m.group(0)!).toList();
  if (found.isEmpty) return true;
  if (_neverTranslated.contains(source)) return true;
  // "Home Assistant" and "paperless-ngx" are two words and one word; check the
  // whole run of words rather than each in turn.
  final joined = found.join(' ');
  return _neverTranslated.contains(joined);
}

Map<String, String> _examples(Map<String, dynamic>? attrs) {
  final placeholders = attrs?['placeholders'];
  if (placeholders is! Map) return const {};
  return {
    for (final entry in placeholders.entries)
      entry.key
          as String: (entry.value is Map && entry.value['example'] != null)
          ? '${entry.value['example']}'
          : entry.key as String,
  };
}

/// Where the space before French punctuation is an ordinary one, or null.
///
/// French sets a non-breaking space before `; ! ? :` and inside `« »`. An
/// ordinary space is wrong twice over: the line may break there, leaving the
/// punctuation stranded at the start of the next one. A missing space is
/// equally wrong, so both are reported.
///
/// A colon inside a clock time, a URL or an `@user:server` handle is not
/// punctuation and is skipped.
String? _frenchSpacingProblem(String message) {
  for (var i = 0; i < message.length; i++) {
    final c = message[i];
    if (c == '«') {
      final next = i + 1 < message.length ? message[i + 1] : '';
      if (next != _nbsp && next != _narrowNbsp) return 'ordinary space after «';
      continue;
    }
    if (!';!?:»'.contains(c)) continue;
    if (i == 0) continue;
    final before = message[i - 1];
    if (c == ':' && _isColonInAToken(message, i)) continue;
    if (before == _nbsp || before == _narrowNbsp) continue;
    if (before == ' ') return 'ordinary space before "$c"';
    if (c == '»') return 'no space before »';
    // `?` and `!` inside a placeholder-free word are still punctuation, but a
    // `!` in `foo!bar` is not French prose — only flag when a space would fit.
    if (RegExp(r'[\p{L}\p{N}»)\]]', unicode: true).hasMatch(before)) {
      return 'no space before "$c"';
    }
  }
  return null;
}

/// True when the `:` at [index] belongs to a token rather than to the prose.
///
/// `19:30`, `127.0.0.1:8080`, `https://…` and `@anna:matrix.org` all put a
/// colon between two non-space characters, and none of them takes a space.
bool _isColonInAToken(String message, int index) {
  final before = message[index - 1];
  final after = index + 1 < message.length ? message[index + 1] : ' ';
  if (before == ' ' || before == _nbsp || before == _narrowNbsp) return false;
  return after != ' ' && after != '\n';
}

// --- ICU ---------------------------------------------------------------------

/// A parsed ICU message: enough of one to compare and to measure.
///
/// Not a general ICU implementation — it knows arguments, `plural` and
/// `select`, which is everything this catalogue uses, and it exists because
/// counting `{` with a regexp mistakes a plural branch's text for an argument
/// name. That mistake is why a naive placeholder check reports every plural in
/// every locale.
class Message {
  Message(this._parts);

  final List<_Node> _parts;

  Set<String> get arguments {
    final out = <String>{};
    void walk(List<_Node> nodes) {
      for (final n in nodes) {
        if (n is _Arg) {
          out.add(n.name);
          for (final branch in n.branches.values) {
            walk(branch._parts);
          }
        }
      }
    }

    walk(_parts);
    return out;
  }

  Set<String> get pluralCategories {
    final out = <String>{};
    void walk(List<_Node> nodes) {
      for (final n in nodes) {
        if (n is _Arg) {
          if (n.type == 'plural' || n.type == 'selectordinal') {
            out.addAll(n.branches.keys);
          }
          for (final branch in n.branches.values) {
            walk(branch._parts);
          }
        }
      }
    }

    walk(_parts);
    return out;
  }

  /// Every concrete string this message can render as.
  ///
  /// One per combination of plural/select branches, with arguments replaced by
  /// the template's declared example. Capped: a message with three nested
  /// plurals would otherwise expand combinatorially, and the widest of the
  /// first few is the widest in practice.
  List<String> renderings(Map<String, String> examples) {
    var out = <String>[''];
    for (final node in _parts) {
      if (node is _Text) {
        out = [for (final s in out) s + node.value];
      } else if (node is _Arg) {
        if (node.branches.isEmpty) {
          final value = examples[node.name] ?? node.name;
          out = [for (final s in out) s + value];
        } else {
          final expanded = <String>[];
          for (final branch in node.branches.values) {
            for (final rendered in branch.renderings(examples)) {
              for (final s in out) {
                expanded.add(s + rendered);
              }
            }
          }
          out = expanded;
        }
      }
      if (out.length > 64) {
        out = out.sublist(0, 64);
      }
    }
    return out;
  }
}

sealed class _Node {}

class _Text implements _Node {
  _Text(this.value);
  final String value;
}

class _Arg implements _Node {
  _Arg(this.name, this.type, this.branches);
  final String name;
  final String type;
  final Map<String, Message> branches;
}

Message? _parse(String source) {
  try {
    final parser = _Parser(source);
    final message = parser.message(0);
    if (parser.index != source.length) return null;
    return message;
  } on FormatException {
    return null;
  }
}

class _Parser {
  _Parser(this.source);

  final String source;
  int index = 0;

  Message message(int depth) {
    final parts = <_Node>[];
    final text = StringBuffer();
    while (index < source.length) {
      final c = source[index];
      if (c == '}' && depth > 0) break;
      if (c == "'") {
        // `use-escaping: true`: '' is a literal quote, '{ opens a quoted run.
        if (index + 1 < source.length && source[index + 1] == "'") {
          text.write("'");
          index += 2;
          continue;
        }
        if (index + 1 < source.length && '{}'.contains(source[index + 1])) {
          final end = source.indexOf("'", index + 1);
          text.write(
            source.substring(index + 1, end == -1 ? source.length : end),
          );
          index = end == -1 ? source.length : end + 1;
          continue;
        }
        text.write(c);
        index++;
        continue;
      }
      if (c == '{') {
        if (text.isNotEmpty) {
          parts.add(_Text(text.toString()));
          text.clear();
        }
        index++;
        parts.add(argument(depth + 1));
        continue;
      }
      text.write(c);
      index++;
    }
    if (text.isNotEmpty) parts.add(_Text(text.toString()));
    return Message(parts);
  }

  _Node argument(int depth) {
    final name = _until(',}').trim();
    if (name.isEmpty) throw const FormatException('empty argument');
    if (_eat('}')) return _Arg(name, '', const {});
    _expect(',');
    final type = _until(',}').trim();
    if (_eat('}')) return _Arg(name, type, const {});
    _expect(',');
    if (type != 'plural' && type != 'select' && type != 'selectordinal') {
      // A formatted argument — `{when, date, yMd}`. No branches to walk.
      _until('}');
      _expect('}');
      return _Arg(name, type, const {});
    }
    final branches = <String, Message>{};
    while (true) {
      _skipSpace();
      if (_eat('}')) break;
      final category = _until('{').trim();
      if (category.isEmpty) {
        throw const FormatException('branch with no category');
      }
      _expect('{');
      branches[category] = message(depth);
      _expect('}');
    }
    if (branches.isEmpty) throw const FormatException('no branches');
    return _Arg(name, type, branches);
  }

  String _until(String stops) {
    final start = index;
    while (index < source.length && !stops.contains(source[index])) {
      index++;
    }
    if (index >= source.length) throw const FormatException('unterminated');
    return source.substring(start, index);
  }

  void _skipSpace() {
    while (index < source.length && ' \t\n'.contains(source[index])) {
      index++;
    }
  }

  bool _eat(String c) {
    if (index < source.length && source[index] == c) {
      index++;
      return true;
    }
    return false;
  }

  void _expect(String c) {
    if (!_eat(c)) throw FormatException('expected $c at $index');
  }
}

// --- Width -------------------------------------------------------------------

/// How many columns [text] takes, which is what a length budget is about.
///
/// Not `String.length`. A budget written as "keep under ~14 chars" is a claim
/// about a chip that is fourteen Latin characters wide, and 十四个汉字 is twice
/// that in the same count — so East Asian Wide and Fullwidth glyphs count two.
/// Combining marks and the soft hyphens German compounds carry for hyphenation
/// count none: neither takes a column of its own.
int _visualWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    if (_isZeroWidth(rune)) continue;
    width += _isWide(rune) ? 2 : 1;
  }
  return width;
}

bool _isZeroWidth(int r) =>
    r == 0x00ad || // soft hyphen
    r == 0x200b || // zero-width space
    (r >= 0x0300 && r <= 0x036f) || // combining diacritics
    (r >= 0xfe00 && r <= 0xfe0f); // variation selectors

/// The East Asian Wide and Fullwidth ranges, to the resolution a budget needs.
bool _isWide(int r) =>
    (r >= 0x1100 && r <= 0x115f) || // Hangul Jamo
    (r >= 0x2e80 && r <= 0x303e) || // CJK radicals, punctuation
    (r >= 0x3041 && r <= 0x33ff) || // kana, compatibility
    (r >= 0x3400 && r <= 0x4dbf) || // CJK ext A
    (r >= 0x4e00 && r <= 0x9fff) || // CJK unified
    (r >= 0xa000 && r <= 0xa4cf) || // Yi
    (r >= 0xac00 && r <= 0xd7a3) || // Hangul syllables
    (r >= 0xf900 && r <= 0xfaff) || // CJK compatibility ideographs
    (r >= 0xfe30 && r <= 0xfe6f) || // CJK compatibility forms
    (r >= 0xff00 && r <= 0xff60) || // fullwidth forms
    (r >= 0xffe0 && r <= 0xffe6) ||
    (r >= 0x1f300 && r <= 0x1f9ff); // emoji

// --- Report ------------------------------------------------------------------

void _report(List<Finding> findings, List<String> locales, int keyCount) {
  final where = locales.join(', ');
  if (findings.isEmpty) {
    stdout.writeln(
      'l10n lint: $keyCount keys × ${locales.length} locales ($where) — clean.',
    );
    return;
  }

  final byRule = <String, List<Finding>>{};
  for (final f in findings) {
    byRule.putIfAbsent(f.rule, () => []).add(f);
  }

  stdout.writeln('l10n lint: ${findings.length} findings across $where.');
  stdout.writeln();
  for (final rule in byRule.keys.toList()..sort()) {
    stdout.writeln('$rule (${byRule[rule]!.length})');
    for (final f in byRule[rule]!) {
      stdout.writeln('  ${f.locale}  ${f.key}  ${f.detail}');
    }
    stdout.writeln();
  }
  stdout.writeln(
    'See docs/TRANSLATING.md for what each rule means and how to satisfy it.',
  );
}
