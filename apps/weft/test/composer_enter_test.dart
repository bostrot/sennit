import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:weft/app/shortcuts.dart';

/// What the Return key does.
///
/// Off by default, and that is the decision worth pinning: this composer grows
/// to five lines and people write paragraphs in it, so a Return that sends
/// turns every attempt at a second line into a message nobody meant to send —
/// and a message that has left for another network cannot be unsent.
void main() {
  Intent? intentFor(
    Map<ShortcutActivator, Intent> map, {
    required LogicalKeyboardKey key,
    bool shift = false,
    bool meta = false,
    bool control = false,
  }) {
    for (final entry in map.entries) {
      final a = entry.key;
      if (a is! SingleActivator) continue;
      if (a.trigger == key &&
          a.shift == shift &&
          a.meta == meta &&
          a.control == control) {
        return entry.value;
      }
    }
    return null;
  }

  group('Return breaks the line by default', () {
    final keys = composerShortcutsFor(sendOnEnter: false);

    test('a bare Return inserts a newline', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter),
        isA<InsertComposerNewlineIntent>(),
      );
    });

    test('the platform send chords still send', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter, meta: true),
        isA<SendComposerIntent>(),
      );
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter, control: true),
        isA<SendComposerIntent>(),
        reason: 'someone who turned Return into a newline still has to send',
      );
    });

    test('Shift+Return is a newline too, rather than nothing', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter, shift: true),
        isA<InsertComposerNewlineIntent>(),
      );
    });
  });

  group('Return sends when the setting says so', () {
    final keys = composerShortcutsFor(sendOnEnter: true);

    test('a bare Return sends', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter),
        isA<SendComposerIntent>(),
      );
    });

    test('Shift+Return is then the way to a second line', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter, shift: true),
        isA<InsertComposerNewlineIntent>(),
      );
    });

    test('the chords keep working, so one habit covers both settings', () {
      expect(
        intentFor(keys, key: LogicalKeyboardKey.enter, meta: true),
        isA<SendComposerIntent>(),
      );
    });
  });

  test('paste is bound either way', () {
    for (final on in [true, false]) {
      final keys = composerShortcutsFor(sendOnEnter: on);
      expect(
        intentFor(keys, key: LogicalKeyboardKey.keyV, meta: true),
        isA<PasteIntoComposerIntent>(),
      );
    }
  });
}
