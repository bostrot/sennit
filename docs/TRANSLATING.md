---
type: reference
title: Translating Braid
created: 2026-08-28
tags: [l10n, contributing]
related:
  - '[[l10n-pipeline]]'
  - '[[l10n-inventory]]'
---

# Translating Braid

Braid speaks six languages and is honest about which ones it has been *read*
in. This is how to claim one, what the conventions are, and how to check your
work before anyone else has to.

You do not need Flutter, Dart, or a checkout to translate. Weblate is set up
against this repository and edits the same files a maintainer would; the
"Without an account" section at the bottom is for people who would rather send
a patch.

## Where the words live

| File | What it is |
| --- | --- |
| `apps/weft/lib/l10n/app_en.arb` | The template. Every key, the English text, and an `@key` block describing where it appears. |
| `apps/weft/lib/l10n/app_<code>.arb` | One per language: the same keys, translated. No `@key` blocks. |
| `apps/weft/lib/l10n/lint_allow.json` | Translations legitimately identical to the English, with the reason for each. |
| `apps/weft/android/app/src/main/res/values-<code>/strings.xml` | The words Android draws itself: notification channel names, widget text, the watch. |
| `apps/weft/ios/Runner/<code>.lproj/InfoPlist.strings` | The sentence in a permission dialog, drawn by iOS before Braid has run a line of code. |

Six locales ship today: `en`, `de`, `es`, `fr`, `pt` (Brazilian) and `zh`
(Simplified). `ar` and `he` are *declared* but not translated — see
[[l10n-pipeline]] for what that means and why.

## Claiming a locale

1. Open an issue titled `l10n: <language>` saying which language and whether
   you are reviewing the existing machine-seeded text or adding a new locale.
   One person per language at a time; the issue is how we know who.
2. Work in Weblate, or on a branch if you prefer a checkout.
3. When a locale has been read end to end by a human, **delete its
   `@@x-review` line**. That is the only record that a review happened.

### The `@@x-review` marker

Every machine-seeded file carries:

```json
"@@x-review": "TRANSLATOR REVIEW PENDING — machine-seeded 2026-08-28"
```

It is ARB metadata, inert at runtime, and it is the difference between "nobody
has read this" and "somebody has". Its presence is not an insult to the
translation; its *absence* is a claim, so only remove it once you have been
through the whole file.

```sh
grep -l 'x-review' apps/weft/lib/l10n/*.arb   # which locales are still unread
```

## Key naming

`lowerCamelCase`, prefixed with the surface the string appears on:

```
settingsTitle
chatComposerMessage
inboxDeleteChatTitle
commonCancel
```

The prefix is the screen (`settings`, `chat`, `inbox`, `auth`); `common` is
reserved for words used on more than three surfaces. You will not usually add
keys — that happens alongside a code change — but you will read a lot of them,
and the prefix is how you find the screen a string is on.

**Read the `@key` description before translating.** It is written for someone
who cannot see the screen, and it says three things that change the answer:
where the string appears, how much room it has, and which words must not be
translated. `paperless-ngx`, `Matrix`, `MCP`, `WhatsApp` and `Braid` are names.
A translated `paperless-ngx` matches nothing.

## Conventions

**Register is informal, in every language.** `du` in German, `tu` in French,
`tú` in Spanish, `você` in Portuguese. Braid talks to one person, not to an
institution. This is not negotiable per-locale: the whole app has to agree, and
a single `vous` in a file of `tu` reads as a mistake rather than as politeness.

**Use the words your messengers use.** People arrive at Braid from WhatsApp,
Telegram and Signal, and "read receipt", "sticker", "reaction", "archive" and
"mute" all have a settled translation in each. Match it rather than the
dictionary; a technically better word that nobody has seen before is worse.

**Placeholders are copied, never renamed.** `{network}`, `{count}`,
`{sender}` are substituted at runtime with values the code supplies. You may
move one within the sentence — that is the entire point of having them — but
the set must match the English exactly. The lint fails on a dropped one.

**Plurals are ICU, and your language's own categories.**

```json
"searchResultCount": "{count, plural, =1{1 résultat} other{{count} résultats}}"
```

Give the categories your language actually has. Chinese has only `other`, and
an `=1` branch there is a branch that can never be selected — the lint says so.
Languages with `few` and `many` should use them; the template having two
branches is a fact about English.

**Apostrophes and braces are escaped.** `use-escaping` is on, so a literal `'`
is written `''` and a literal `{` is written `'{'`. In practice you sidestep
this by using your language's own typography — French sets `’`, not `'`, which
is what you would write anyway and needs no escaping.

### French spacing

French sets a space before `; ! ? :` and inside `« »`, and it must be
**non-breaking** or the line wraps and leaves the punctuation stranded at the
start of the next one. Braid uses:

| Where | Character |
| --- | --- |
| before `;` `!` `?` | U+202F narrow no-break space |
| before `:`, before `»`, after `«` | U+00A0 no-break space |

The `fr-spacing` lint rule checks every string. It skips a colon inside a clock
time, a URL or an `@user:server` handle, which take no space.

### Chinese

Simplified only — `app_zh.arb` is what a device asking for `zh-Hant` gets, so
there is nowhere for a Traditional character to be correct. Full-width
punctuation (`，` `。` `：` `「」`), no spaces between Han characters, and a
space between Han and Latin or digits (`通过 Braid 发送`). The `zh-traditional`
and `zh-plural` lint rules check the first and the last of those.

### German

Capitalise nouns, and prefer the shorter synonym wherever a string sits in a
button, a chip or a tab. German is the longest text Braid ships and it is where
layouts break; if a string has no short form, say so on the issue rather than
inventing an abbreviation nobody uses.

## Length budgets

Some keys carry a `maxLength` in their `@key` block:

```json
"@settingsStatusModeOff": {
  "description": "Label of a small selectable chip choosing how statuses appear: not at all. Very tight — keep under ~10 chars.",
  "maxLength": 25
}
```

Two numbers, and they are not the same thing. The **description** gives the
English budget — what the designer had in mind for the slot. The **`maxLength`**
is the physical cap, the English budget plus the room another language needs
for the same idea, and it is what the lint enforces. Being under the English
number is not a goal: `Off` is three characters and `Desactivado` is eleven,
and the second is not a worse translation.

`maxLength` is measured in *columns*, not characters. A CJK glyph counts two, a
combining mark counts none, and a message with plural branches is measured at
its widest branch. Only genuinely constrained surfaces carry one — chips, tabs,
buttons, app bar titles, widget rows. A subtitle that wraps has no budget,
because it has no limit worth writing down.

If a translation cannot fit, that is a finding about the *layout*, not about
your translation. Say so on the issue.

## Checking your work

From the workspace root:

```sh
cd apps/weft && flutter gen-l10n     # malformed ARB, broken ICU, missing @key
dart analyze                          # a key the generator did not produce
cd ../.. && dart run tooling/scripts/l10n_lint.dart
cd apps/weft && flutter test test/l10n_test.dart test/l10n_overflow_test.dart
```

The lint is the one written for you. It exits non-zero on any finding and
reports them grouped by rule:

| Rule | What it means |
| --- | --- |
| `missing-key` / `extra-key` | The key set does not match the template. |
| `placeholder` | A `{name}` was dropped, added or renamed. |
| `icu` | The message does not parse — usually an unbalanced brace. |
| `untranslated` | Byte-identical to the English. If that is genuinely right, add it to `lint_allow.json` **with a reason**. |
| `too-long` | Wider than the key's `maxLength`. |
| `fr-spacing` | A breaking space before French punctuation. |
| `zh-traditional` | A Traditional character in the Simplified catalogue. |
| `zh-plural` | A plural category Chinese does not have. |

`l10n_overflow_test.dart` pumps every main screen in every locale at 1.0× and
2.0× text and fails on a `RenderFlex overflowed`. It is the check that catches
a translation that fits the budget and still breaks the row.

## Weblate

Braid is set up for [Weblate](https://weblate.org), which is self-hostable and
AGPL — the same licence as Braid, which is why it rather than a hosted
proprietary service.

`.weblate` in the repository root configures the [`wlc`](https://docs.weblate.org/en/latest/wlc.html)
command-line client and names the two components:

- **app** — `apps/weft/lib/l10n/app_*.arb`, the Flutter strings.
- **android** — `apps/weft/android/app/src/main/res/values-*/strings.xml`, the
  words Android draws.

Both are configured to push a branch rather than commit to `main`, so a
translation arrives as a pull request and gets the same CI run — including the
lint above — as any other change.

Weblate does not know about `lint_allow.json`, so a string you deliberately
leave in English will show as untranslated there. Mark it and add the entry;
the file is the durable record of *why*.

## Without an account

A pull request works just as well:

1. Edit `apps/weft/lib/l10n/app_<code>.arb`. Same keys, no `@key` blocks, keep
   `@@locale`.
2. Run the checks above.
3. Open the PR against `main`, and say in the description whether you read the
   whole file or a part of it.

Do not commit `apps/weft/lib/l10n/gen/` — it is generated and gitignored.

## Adding a new language

1. Copy `app_en.arb` to `app_<code>.arb`, drop every `@key` block, translate
   the values.
2. Set `"@@locale": "<code>"` and add the `@@x-review` marker.
3. Add the locale to `weftSupportedLocales` in
   `apps/weft/lib/app/localisation.dart`.
4. Add `values-<code>/strings.xml` under `apps/weft/android/`, matching the
   base key set exactly — `l10n_test.dart` checks that.
5. Add `<code>.lproj/InfoPlist.strings` under `apps/weft/ios/Runner/` and
   `apps/weft/macos/Runner/`, and register the locale in each Xcode project's
   `knownRegions`. [[l10n-pipeline]] has the detail; it is the one step that
   involves editing a `.pbxproj`.

A script or region subtag needs a base file to fall back to — see "Script and
region codes" in [[l10n-pipeline]] before adding `pt-PT` or `zh-Hant`.

## Related

- [[l10n-pipeline]] — how the catalogues are built, and what a locale turns on.
- [[l10n-inventory]] — literals not yet in a catalogue. Not translator work.
