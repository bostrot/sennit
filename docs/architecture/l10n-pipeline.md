---
type: reference
title: Localization Pipeline
created: 2026-08-28
tags:
  - l10n
  - i18n
  - build
related:
  - '[[l10n-inventory]]'
  - '[[TRANSLATING]]'
  - '[[a11y-audit]]'
---

# Localization Pipeline

Sennit's user-facing words live in ARB files under `apps/weft/lib/l10n/`.
`flutter gen-l10n` compiles them into an `AppL10n` class, and a widget reads one
string from it as `context.l10n.settingsTitle`. Nothing user-facing should be a
Dart literal; [[l10n-inventory]] is the machine-generated list of the ones that
still are.

This is the how-to. The *why* — what declaring a locale turns on beyond
translation, and why Hebrew is declared with no ARB file — is in the
library comment at the top of `apps/weft/lib/app/localisation.dart`, which is
where someone changing that list will be standing.

## The pieces

| File | What it is |
| --- | --- |
| `apps/weft/lib/l10n/app_en.arb` | The template. Every key, every description, and the English text. |
| `apps/weft/lib/l10n/app_*.arb` | One per translated language. Same keys, no descriptions. |
| `apps/weft/l10n.yaml` | The generator's settings. |
| `apps/weft/lib/l10n/gen/` | Generated Dart. **Gitignored** — never edit, never commit. |
| `apps/weft/lib/app/localisation.dart` | The locale list, the delegates, and `context.l10n`. |
| `apps/weft/test/l10n_test.dart` | The checks CI runs against all of the above. |
| `tooling/scripts/l10n_audit.dart` | Finds literals that have not been extracted yet. |

`generate: true` under `flutter:` in `apps/weft/pubspec.yaml` is what runs the
generator on every `flutter pub get` and every build, so `lib/l10n/gen/` exists
without anyone having to remember it. There is a second `generate: true` further
down that file belonging to `flutter_launcher_icons`; they are unrelated
settings that happen to share a name.

## Key naming

`lowerCamelCase`, no dots, prefixed with the surface the string appears on:

```
settingsTitle
settingsSectionPrivacyAndSecurity
settingsReadReceiptsSubtitle
settingsSendOnEnterSubtitleOn
commonCancel
```

The prefix is the screen or feature (`settings`, `chat`, `inbox`, `auth`), and
`common` is reserved for words used on more than three surfaces — `Cancel`,
`Save`, `Delete`. Resist growing `common`: a "Save" that means *store this
draft* and a "Save" that means *keep this contact* are different words in
German, and sharing a key makes one of them wrong for ever.

Where a key needs a title and a subtitle, spell both out — `xTitle`, `xSubtitle`
— rather than nesting. Where a string has two states, suffix the state:
`SubtitleOn`, `SubtitleOff`.

## Adding a string

1. Add the key and the English text to `app_en.arb`.
2. Add an `@key` block next to it with a `description`. This is **required** —
   `required-resource-attributes: true` in `l10n.yaml` makes a missing one a
   build failure, and `l10n_test.dart` checks it too.
3. Add the same key to every other `app_*.arb`, translated — never the English
   copied across. Descriptions do not go in the translated files; only
   `@@locale` and `@@x-review` do. The same goes for a changed English string:
   every locale is updated in the same pull request. `AGENTS.md` states the
   rule; the lint below enforces it.
4. Replace the literal at the call site with `context.l10n.yourKey`.
5. `flutter gen-l10n`, then `flutter test`.

### Writing the description

Write for a translator who cannot see the screen and has never used Sennit. Say
where the string appears, what it does, and how much room it has:

```json
"@settingsStatusModeOff": {
  "description": "Label of a small selectable chip choosing how statuses appear: not at all. Very tight — keep under ~10 chars."
}
```

Three things earn their place in nearly every description: **the surface** ("app
bar title", "one-line subtitle under 'Bridges'", "screen-reader-only label"),
**the length budget**, and **which words must not be translated** — product
names (`WhatsApp`, `Home Assistant`, `paperless-ngx`), the app's own name
(`Sennit`), and protocol terms (`Matrix`, `MCP`). A translator who is not told
will translate them, and a translated `paperless-ngx` matches nothing.

### Placeholders and plurals

Interpolation is ICU `{name}` with typed `placeholders` metadata, never Dart
`$interpolation` inside an ARB value:

```json
"settingsShowNetworkInAll": "Show {network} in All",
"@settingsShowNetworkInAll": {
  "description": "...",
  "placeholders": {
    "network": { "type": "String", "description": "A messenger's display name, never translated.", "example": "WhatsApp" }
  }
}
```

Anything that branches on a count in Dart becomes an ICU `plural`, so the
languages with more than two plural forms can express them:

```json
"settingsUnhideStatusSenders": "{count, plural, =1{Unhide 1} other{Unhide {count}}}"
```

A translated file may carry *fewer* plural categories than the template when the
language has fewer — `app_zh.arb` gives only `other`, which is correct for
Chinese and not an omission.

### Escaping

`use-escaping: true` is on. A literal `'` inside an ARB message must be written
`''`, and a literal `{` as `'{'`. In practice the translations sidestep this by
using each language's own typography — French uses the typographic apostrophe
`’`, not `'` — which is what a translator would write anyway and needs no
escaping at all.

## Adding a locale

1. Copy `app_en.arb` to `app_xx.arb`, drop every `@key` block, translate the
   values.
2. Set `"@@locale": "xx"` and
   `"@@x-review": "TRANSLATOR REVIEW PENDING — machine-seeded <date>"`.
3. Add the locale to `weftSupportedLocales` in
   `apps/weft/lib/app/localisation.dart`.
4. `flutter gen-l10n` and `flutter test` — `l10n_test.dart` will fail if the key
   set does not match the template exactly.

### Script and region codes

`gen-l10n` refuses to generate a `zh_Hans` or `pt_BR` file unless a base
`zh` / `pt` file also exists, because the region file is a *delta* on the base
and a device asking for plain `pt` needs something to resolve to. Sennit ships
exactly one written form of each language, so rather than duplicate sixty
strings into a base file it keeps a single `app_zh.arb` and `app_pt.arb` whose
content *is* the Simplified and Brazilian form. Each carries an `@@x-variant`
line saying so.

`weftSupportedLocales` still declares `zh-Hans` and `pt-BR`, which is what the
app honestly serves. The generated delegate's `isSupported` matches on language
code alone, so both resolve; a device set to `pt-PT` or `zh-Hant` gets the form
Sennit has rather than English, which is the better of the two available
failures. If a second written form is ever translated, add `app_zh_Hant.arb`
beside the base and nothing else changes.

## The `@@x-review` marker

Every machine-seeded translation carries:

```json
"@@x-review": "TRANSLATOR REVIEW PENDING — machine-seeded 2026-08-28"
```

`@@`-prefixed keys are ARB metadata, ignored by the generator, so this is inert
at runtime and queryable from a shell:

```sh
grep -l 'x-review' apps/weft/lib/l10n/*.arb
```

A human translator who reviews a file **deletes the line**. Its absence is the
signal that a locale has been through review; nothing else records that, and a
translated file with no marker and no review is indistinguishable from a
reviewed one.

## Packages and their words

`apps/weft` has the ARB files. The fifteen packages under `packages/` do not,
and cannot: `AppL10n` lives in the app, and a shared library that imported it
would depend on the thing that consumes it. A package that hard-coded English
would be a package no locale could ever reach.

So the rule is that **a package answers in values and the app turns them into
words**. There are three shapes of that, and which one applies depends on how
far the package is from a screen.

### A code, worded by the app

The common case. The package already knew *why*; it just also happened to
write the sentence. Now it returns the reason and the facts the sentence needs,
and `apps/weft/lib/app/l10n_labels.dart` is the only place that words one.

| Package | Value | Worded by |
| --- | --- | --- |
| `weft_bridges` | `BridgeException.failure` (`BridgeFailure`) | `AppL10n.bridgeFailure` |
| `weft_search` | `EmbeddingException.failure` (`EmbeddingFailure`) | `AppL10n.embeddingFailure` |
| `weft_attachments` | `UploadRejection.reason`, `.sizeBytes`, `.limitBytes` | `AppL10n.attachmentRejection` |
| `weft_sms` | `MmsRejection.reason`, `.mimeType`, `.sizeBytes`, `.budgetBytes` | the SMS surface |
| `weft_call` | `CallAvailability` — a target, or a `CallBlocker` and its networks | `AppL10n.callAvailability` |
| `weft_domain` | `MessageKind`, `DeliveryState` | `AppL10n.messageKind`, `.deliveryState` |

Each of these still carries an English `message` beside its code. That is not a
leftover: it is what a `debugPrint` shows, what a `toString` reads as in a
crash report, and what a caller outside the app would get. Where a code is
present it wins; `bridgeFailure` returns null when the bridge sent a sentence
of *its own*, because that one is specific and is already in whatever language
the bridge was configured in.

### Words passed in

A widget is the one case where a code is not enough, because the widget is what
draws. `weft_design` and `weft_notify` therefore declare what they need as a
value object the app fills in:

- **`WeftDesignStrings`** — everything `ChatTile` says: the preview line, the
  pin tooltip, the unread count. Supplied through `WeftDesignStringsScope`,
  installed once in `main.dart` under `Localizations`.
- **`WeftNotifyStrings`** — the words a notification body is made of, and the
  same ones `weft_snapshot` renders a widget row with. Passed as an argument
  rather than a scope: neither has a widget tree to hang one on.

Both default to `.english`, and that fallback is real rather than a
placeholder: a component with no scope renders readable English, which is what
a widget test pumping a bare `MaterialApp` should get and what an undeclared
locale would have had anyway.

### No widget tree at all

Notification channel names, notification action labels, a file dialog's
type-group name and the snapshot a home-screen widget reads are all user-facing
and none of them is built under a `Localizations` — some are written while the
app is not running. `weftPlatformL10n()` in `localisation.dart` resolves the
device's own locale list against `weftSupportedLocales` and returns the strings
for it.

It is the only correct use of that function. Anything holding a `BuildContext`
must use `context.l10n`, which follows the locale the app actually resolved to
and rebuilds when it changes. `weftPlatformL10n` does neither.

## The native side

Three catalogues sit outside `lib/l10n/`, because three surfaces are drawn by an
operating system rather than by Flutter. Each has its own mechanism, and none of
them can reach an ARB file.

### Android resources

`apps/weft/android/app/src/main/res/values/strings.xml` and the Wear module's
own. A Glance composable and a Wear tile run in the launcher's process with no
Flutter engine anywhere in them, so their words have to be Android resources —
and so do the notification channel names, which Android shows in *its* settings
and which the app is not running to supply.

Translations are `values-<code>/strings.xml`, one directory per locale:
`values-es`, `values-de`, `values-fr`, `values-pt-rBR`, `values-zh-rCN`. Note
Android's own spelling: a region is `-r` plus the code, so Brazilian Portuguese
is `pt-rBR` and not `pt-BR`.

The base file carries the reasoning behind each string and the translations
carry only the words, which is the same split as `app_en.arb` and its
`@key` blocks. `l10n_test.dart` checks the key sets match.

Kotlin reads them through `getString(R.string.…)`. A literal in a `.kt` file is
a string no locale can reach, and the audit tool fails the build on one.

### Apple usage descriptions

A permission prompt is drawn before Sennit has run a line of Dart, so its
sentence comes out of the bundle: `Info.plist` for English, and
`<locale>.lproj/InfoPlist.strings` for everything else, keyed by the
`Info.plist` key each entry overrides.

**This involves editing `.xcodeproj`.** Writing the `.lproj` directories is not
enough — Xcode copies only what `project.pbxproj` lists — so each project also
gained the locales in `knownRegions`, a `PBXVariantGroup` named
`InfoPlist.strings`, and that group in the Runner target's Resources phase.
Adding a locale means touching the project file again; `plutil -lint` on the
`.pbxproj` is the cheapest check that it is still readable.

The iOS strings say "Sennit" and the macOS ones say "Weft", because that is what
each `Info.plist` says today. They are the product's own name, not something to
translate — but the two disagreeing is a rebrand that has not finished, and
worth fixing in English first.

## The audit tool

```sh
dart run tooling/scripts/l10n_audit.dart
```

Parses every file under `apps/weft/lib/` and reports string literals reaching a
widget the user reads — a `Text`, a `Tooltip(message:)`, a `Semantics(label:)`,
any `title:`/`subtitle:`/`label:`. Literals already resolved through
`context.l10n` are not literals at that point and never appear, so the count
falls as extraction proceeds and reaches zero when it is done. It also line-scans
the Kotlin and the layouts under `apps/weft/android/`, where the same mistake
is a `setContentTitle("…")` or an `android:text="…"` rather than a `Text`.

**It exits non-zero on a single finding.** A literal that is deliberately not
translated says so at the call site:

```dart
// l10n-ignore: the app's own name, never translated.
label: 'Sennit',
```

The marker goes on the literal's line or one of the two above it — an XML
attribute cannot carry a comment inside its start tag, so the one in
`AndroidManifest.xml` sits above the element. The reason is required and lands
in [[l10n-inventory]]'s own table, which keeps the exceptions a short list
somebody reads rather than a growing pile of suppressions. There are seventeen:
the app's name, ten demo fixtures, an error the SDK phrased, a machine-readable
audit line and two interpolations of already-translated strings.

It rewrites [[l10n-inventory]], which is the work-list.

It parses rather than resolves — no build, no analysis context, about a second
for the whole app — so the matcher is syntactic and will occasionally flag a
`title:` that is not prose. A false positive costs a line in a work-list.

The tool's `analyzer` dependency is declared in the **workspace root**
`pubspec.yaml`, not in `apps/weft`. It was already in the lock transitively at
the same version, so promoting it moved nothing; putting it in the app would
have added a direct `analyzer` constraint to a resolution unit that has lost
packages to `analyzer` conflicts before.

## The translation lint

```sh
dart run tooling/scripts/l10n_lint.dart
```

The audit above asks whether a string reached a catalogue. This asks whether
what reached it is *usable in the language it landed in* — and every one of its
findings is invisible to a reviewer who does not read that language, which is
what makes it a CI step rather than a review note.

Nine rules: a required locale with no catalogue at all (`en`, `de`, `zh`,
`hi`, `es` and `ar` — the list is `_requiredLocales` in the script), key parity,
placeholder-set drift, an ICU message that does not
parse, a translation byte-identical to the English, a translation wider than
its key's budget, a breaking space before French punctuation, a Traditional
character in the Simplified Chinese catalogue, and a plural category Chinese
does not have. Each is documented at the head of the script and again, for the
person who has to satisfy them, in [[TRANSLATING]].

It parses ICU rather than counting braces. That is not fastidiousness: a
regexp reading `{count, plural, =1{Unhide 1} other{…}}` sees `Unhide` as a
placeholder name, so a naive placeholder check reports every plural in every
locale and is switched off within a week.

### `untranslated`, and its allowlist

Most strings that come back identical to the English are fine — `SMS`, `PDF`,
`{network} · {id}` — so the rule allows anything made only of placeholders and
punctuation, plus a short list of names in the script itself.

What is left is per-language and genuinely coincidental: French really does say
`Photo`, German really does say `Pause`. Those go in
`apps/weft/lib/l10n/lint_allow.json`, one entry per locale per key, **with the
reason**. The reason is the point. An allowlist of bare keys becomes the place
things go when they fail, and then the rule stops meaning anything.

### `maxLength`, and why it is not the English length

`@key.maxLength` in `app_en.arb` is the physical width of the slot, in columns.
It is derived from the budget the description states — "keep under ~10 chars" —
plus the room another language needs for the same idea, on the usual curve: the
shorter the English, the larger the multiple. `Off` is three characters and
`Desactivado` is eleven, and the second is not a worse translation; a chip that
cannot hold it is a bad chip.

Only genuinely constrained surfaces carry one — chips, tabs, buttons, app bar
titles, widget rows, notification actions. A subtitle that wraps has no budget,
because it has no limit worth writing down, and giving it one produced three
hundred findings that were all really the same observation about German.

Width, not `String.length`: a CJK glyph counts two columns, a combining mark
and the soft hyphens German compounds carry for hyphenation count none, and a
message with plural branches is measured at its widest branch with placeholders
replaced by their declared `example`.

The lint is the cheap half of the check. `l10n_overflow_test.dart` is the other
half and the authoritative one — it pumps seven screens in all eight locales at
1.0× and 2.0× text on a phone-sized window and fails on a `RenderFlex
overflowed`, which is the failure a budget is a proxy for.

## In CI

Five commands, in this order — cheapest first, and each one catches something
the next cannot:

```sh
cd apps/weft && flutter gen-l10n         # a malformed ARB, a missing description
dart analyze                              # a key the codegen did not produce
dart run tooling/scripts/l10n_audit.dart  # a literal that never reached a catalogue
dart run tooling/scripts/l10n_lint.dart   # a translation that is unusable in its language
cd apps/weft && flutter test              # key parity, resolution, native catalogues, overflow
```

`flutter gen-l10n` catches the most for the least: a broken ICU expression, a
placeholder with no metadata, an `@key` block someone forgot. The audit exits
non-zero on a single unextracted literal, which is what makes it a gate rather
than a report; the lint does the same for a single unusable translation;
`l10n_test.dart` is what checks the two native catalogues and the Apple usage
descriptions, which nothing else looks at.

`lib/l10n/gen/` is gitignored, so a checkout has no generated Dart until
`flutter pub get` runs — which CI does anyway, and which regenerates it. Never
commit it; the diff is derived, and reviewing a generated file trains people to
skim generated files.

## Translators

`.weblate` in the repository root sets up two Weblate components — the ARB files
and the Android resources — both pushing a branch rather than committing to
`main`, so a translation arrives as a pull request and gets the lint like
anything else. [[TRANSLATING]] is the guide it points people at: how to claim a
language, the conventions each one has, and how to run the checks locally.

The one convention worth repeating here, because it is a property of the whole
app rather than of any locale: **the register is informal in every language**.
`du`, `tu`, `tú`, `você`. A file that is half formal reads as a mistake, and the
only way to keep that from happening one string at a time is for it to be
written down where the strings are.

## Related

- [[TRANSLATING]] — the translator's guide: conventions, the lint, Weblate.
- [[l10n-inventory]] — every literal still hardcoded, by area and file.
- [[a11y-audit]] — the RTL findings that `ar` and `he` are declared for. The two
  passes share `weftSupportedLocales` and nothing else.
