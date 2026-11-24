# Notes for agents

Instructions for any coding agent (and any human) changing this repository.
Read [CONTRIBUTING.md](CONTRIBUTING.md) for the rest.

## Translations are part of every change

Sennit ships in English, German, Chinese (Simplified), Hindi, Spanish and
Arabic, plus French and Portuguese. **Any added or changed user-facing string
must be updated in ALL locale files in the same PR (en, de, zh, hi, es, ar —
and fr, pt while they ship). Never leave a key untranslated or in English.**

That covers every place the app keeps words:

| Where | Files |
| --- | --- |
| Flutter UI, notifications, errors, onboarding, AI settings | `apps/weft/lib/l10n/app_<code>.arb` (template: `app_en.arb`, with an `@key` description) |
| Android widgets, call and connection notifications | `apps/weft/android/app/src/main/res/values-<code>/strings.xml` |
| Wear OS tile and replies | `apps/weft/android/wear/src/main/res/values-<code>/strings.xml` |
| iOS and macOS permission prompts | `apps/weft/{ios,macos}/Runner/<code>.lproj/InfoPlist.strings` |
| Siri example phrases | `apps/weft/ios/Runner/<code>.lproj/AppIntentVocabulary.plist` |

How to write them:

- Natural wording, not word for word; keep UI text short where the space is
  tight (the `@key` description and `maxLength` say how tight).
- Keep placeholders, ICU plurals and selects intact. Use each language's own
  plural categories (Arabic: `=1`, `=2`, `few`, `other`; Chinese: `other`).
- Use the terms the file already uses for the same idea.
- Never hard-code a user-facing literal in Dart; add a key and read it through
  `context.l10n`.
- Product names (Sennit, Matrix, WhatsApp, MCP…) stay as they are. A string
  that is legitimately identical to English goes in
  `apps/weft/lib/l10n/lint_allow.json` with a reason.

Check before you push (CI runs the same and fails on any finding):

```sh
cd apps/weft && flutter gen-l10n && cd ../..
dart run tooling/scripts/l10n_lint.dart    # missing locale/key, placeholders, ICU, untranslated, too long
dart run tooling/scripts/l10n_audit.dart   # hard-coded literals outside the catalogues
cd apps/weft && flutter test test/l10n_test.dart test/l10n_overflow_test.dart
```

[docs/TRANSLATING.md](docs/TRANSLATING.md) has the conventions per language,
and [docs/architecture/l10n-pipeline.md](docs/architecture/l10n-pipeline.md)
how the catalogues are built.

## Every release needs a short Play text

Google Play's "What's new" shows at most 500 characters; longer notes show
the first bullet and "…". So besides `docs/release-notes/<version>.md`, every
release needs `docs/release-notes/<version>.play.md` (en-US) and
`<version>.play.de-DE.md`: all highlights, one short line each, at most 500
characters per file. Play gets these, on every track; the full notes stay
for GitHub, TestFlight and the app. Check with
`python3 tooling/scripts/release_notes.py --check` (CI runs it).
[docs/RELEASING.md](docs/RELEASING.md#plays-short-text) has the details.
