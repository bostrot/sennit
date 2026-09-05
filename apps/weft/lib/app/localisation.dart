/// Weft's localisation surface: the locales it declares, what declaring them
/// turns on, and where its own translated strings come from.
///
/// Braid's user-facing words live in ARB files under `lib/l10n/`, and
/// `flutter gen-l10n` compiles them into the [AppL10n] class this file wires
/// into the widget tree. `lib/l10n/app_en.arb` is the template every other
/// locale is keyed against; `context.l10n` is how a widget reads one.
/// `docs/architecture/l10n-pipeline.md` is the how-to — adding a string, adding
/// a locale, what CI checks.
///
/// A `supportedLocales` list does two separable jobs, and it is worth keeping
/// them apart because only the first is about translation:
///
/// - It selects which of Braid's own ARB files [AppL10n] resolves against. A
///   device set to Spanish gets `app_es.arb`; a device set to something with no
///   ARB file gets `app_en.arb`, because English is first in the list and
///   `basicLocaleListResolution` returns the first entry for anything it cannot
///   match. Keys never reach the screen — the fallback is a real English
///   sentence.
/// - It is also the *only* source of three things that have nothing to do with
///   Braid's strings. Without a declared locale, `Directionality` resolves to
///   left-to-right for every locale a device can be set to, and no amount of
///   `EdgeInsetsDirectional` downstream makes a difference because nothing was
///   ever going to set the direction. `Localizations.localeOf` is always
///   `en_US`, so Material's own strings — the back button's semantics label,
///   the selection menu, the date and time pickers — stay English on a device
///   that is not. And `intl`'s `DateFormat` formats every timestamp in the
///   default locale for ever.
///
/// ## Where the eight locales actually stand
///
/// Not all eight are the same kind of thing, and the list flattens a
/// distinction worth keeping:
///
/// - **`en`** is the template. Every key is written here first, with the
///   `@key` description a translator works from.
/// - **`de`, `es`, `fr`, `pt`, `zh`** have a complete ARB file — the same key
///   set as the template, checked by `l10n_test.dart` and
///   `tooling/scripts/l10n_lint.dart`. Every one of them still carries an
///   `@@x-review` line, which means machine-seeded and machine-checked but not
///   yet read by somebody who speaks the language. That line's *absence* is
///   the claim that a person has; nothing else records it. See
///   `docs/TRANSLATING.md`.
/// - **`ar`, `he`** have no ARB file and are not waiting for one here. They are
///   declared for layout, and Braid's own words in them are English.
///
/// So "supported" means three different things down this list, and the honest
/// summary is: five translated languages awaiting a human reader, two declared
/// for right-to-left with English words, and English underneath all of them
/// wherever a string is missing.
///
/// That last case is why `ar` and `he` are on the list with no ARB file of
/// their own, which looks like an oversight and is not. They are the two
/// right-to-left scripts the accessibility pass is verified against, and what
/// is being verified is the *layout*: that the thread mirrors, that the tail on
/// a bubble swaps sides, that a timestamp is Arabic-Indic. Declaring them turns
/// the app right-to-left and hands Material its Arabic and Hebrew strings while
/// Braid's own text falls back to English — the honest half-state, and one that
/// makes an RTL golden a test of the layout rather than of a translation. When
/// Arabic and Hebrew ARB files are written they simply appear, and nothing
/// here changes.
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' show DateFormat, Intl;
import '../app/localisation.dart';

import '../l10n/gen/app_l10n.dart';

// `lookupAppL10n` alongside the class: a plain unit test of a function that
// formats a string has an [AppL10n] to hand it without pumping a widget, and
// the generated file it comes from is gitignored — so the import belongs here,
// where the pipeline's shape is already documented, rather than spread across
// the tests that need it.
export '../l10n/gen/app_l10n.dart' show AppL10n, lookupAppL10n;

/// The locales Braid declares.
///
/// English first: it is both the fallback and the language `app_en.arb` is
/// written in, and `basicLocaleListResolution` returns the first entry when the
/// device asks for something not on the list.
///
/// Then the five translated locales, each with an ARB file beside `app_en.arb`.
/// `zh` carries a `scriptCode` and `pt` a `countryCode` because both languages
/// have a second written form Braid does not ship — Traditional Chinese,
/// European Portuguese — and a bare `zh` would claim to serve a reader in
/// Taipei with text written for Shanghai.
///
/// Then `ar` and `he`, declared for right-to-left layout and Material's own
/// strings, with no ARB file of their own. See the library comment above.
const List<Locale> weftSupportedLocales = [
  Locale('en'),
  Locale('es'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  Locale('pt', 'BR'),
  Locale('de'),
  Locale('fr'),
  Locale('ar'),
  Locale('he'),
];

/// The delegates that make [weftSupportedLocales] mean anything.
///
/// [_WeftAppL10nDelegate] is Braid's own strings, compiled from
/// `lib/l10n/*.arb`. The `Global*` trio is Material, Widgets and Cupertino;
/// `GlobalWidgets` is the one that carries `textDirection`, and therefore the
/// one that puts the app into RTL at all. All four are needed: without the
/// globals, a screen translated into Arabic would still be laid out
/// left-to-right with an English back button.
const List<LocalizationsDelegate<dynamic>> weftLocalizationsDelegates = [
  _WeftAppL10nDelegate(),
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// [AppL10n.delegate], widened to cover the locales Braid declares without
/// translating.
///
/// The generated delegate supports exactly the languages that have an ARB file.
/// `ar` and `he` do not, deliberately — and a locale a delegate refuses is a
/// locale where `Localizations` simply has no `AppL10n` in it, so
/// `AppL10n.of(context)` is null and `context.l10n` throws a null check on the
/// first widget that draws. A device set to Arabic would not get English text
/// in a mirrored layout; it would get a red screen.
///
/// So [isSupported] answers for the whole of [weftSupportedLocales] and [load]
/// hands back the English strings for anything the generator did not produce.
/// That is the fallback the library comment above promises, made real: the
/// declared-for-layout locales get RTL, Material's own Arabic, and Braid's
/// English words.
///
/// Matching on `languageCode` alone is the same rule the generated delegate
/// uses, and it is what lets `pt-PT` reach `app_pt.arb` and `zh-Hant` reach
/// `app_zh.arb` rather than falling all the way to English.
class _WeftAppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _WeftAppL10nDelegate();

  @override
  bool isSupported(Locale locale) => weftSupportedLocales.any(
    (declared) => declared.languageCode == locale.languageCode,
  );

  @override
  Future<AppL10n> load(Locale locale) => AppL10n.delegate.isSupported(locale)
      ? AppL10n.delegate.load(locale)
      : AppL10n.delegate.load(const Locale('en'));

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppL10n> old) => false;
}

/// Braid's own translated strings, for the locale that resolved here.
///
/// Reads as `context.l10n.settingsTitle` at a call site — the same shape as
/// `context.colors` and `context.motion` from `weft_design`, and short enough
/// that a `Text(context.l10n.x)` is no wider than the literal it replaced.
///
/// Non-null: `nullable-getter: false` in `l10n.yaml`, because everything that
/// draws is under the app's `Localizations` and a nullable getter would be a
/// `!` at four hundred call sites. It throws in a widget test that pumps a bare
/// `MaterialApp` without [weftLocalizationsDelegates] — which is the right
/// failure, and `test/support/golden_harness.dart` supplies them.
extension WeftL10nContext on BuildContext {
  AppL10n get l10n => AppL10n.of(this);
}

/// The same strings, for code that has no widget tree to read them from.
///
/// A notification's action labels, the channel names Android shows in its own
/// settings, and a file dialog's type-group name are all user-facing, and none
/// of them is built under a `Localizations` — the notification plugin is
/// configured once at startup and the platform draws the rest itself, possibly
/// while the app is not running at all.
///
/// So this resolves against the device's own locale list rather than an
/// inherited widget. It is the *only* correct use of it: anything with a
/// `BuildContext` must use [WeftL10nContext.l10n], which follows the locale the
/// app actually resolved to and rebuilds when it changes. This does neither.
AppL10n weftPlatformL10n() {
  final locale = basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    weftSupportedLocales,
  );
  // `lookupAppL10n` throws for a locale with no generated class — `ar` and `he`
  // are declared for layout and have none — so the same English fallback the
  // delegate above makes applies here too.
  return weftSupportedLocales.contains(locale) &&
          AppL10n.delegate.isSupported(locale)
      ? lookupAppL10n(locale)
      : lookupAppL10n(const Locale('en'));
}

/// Points `intl`'s date formatting at [locale], when it has data for it.
///
/// Every `DateFormat` in Braid is constructed without a locale — `DateFormat.Hm()`
/// on a bubble, `DateFormat.yMMMd()` on a device row — which means they all read
/// `Intl.defaultLocale`. Setting it here is what makes a timestamp in an Arabic
/// UI an Arabic timestamp rather than an English one sitting in a mirrored
/// layout.
///
/// Guarded on [DateFormat.localeExists] rather than assumed, because a
/// `DateFormat` built for a locale whose symbols were never loaded throws — and
/// it would throw inside `build`, on every bubble at once. `main` loads the
/// symbol data; a widget test does not, and a test that puts the app into
/// Arabic to check its *layout* must not be made to fail by its clock.
void applyFormattingLocale(Locale locale) {
  final tag = locale.toLanguageTag().replaceAll('-', '_');
  for (final candidate in [tag, locale.languageCode]) {
    if (Intl.defaultLocale == candidate) return;
    if (DateFormat.localeExists(candidate)) {
      Intl.defaultLocale = candidate;
      return;
    }
  }
}
