/// Weft's localisation surface: the locales it declares, and what declaring
/// them actually turns on.
///
/// Weft ships **no translated strings**. Every user-facing word in the app is a
/// Dart literal, and extracting the ~400 of them into ARB files is a phase of
/// its own. That is deliberately not what this file is for, and it is worth
/// being precise about the difference, because a `supportedLocales` list is
/// usually a translation feature and here it is not:
///
/// - Without it, `Directionality` resolves to left-to-right for *every* locale
///   the device can be set to. Switching a phone to Arabic changed nothing in
///   Weft, and no amount of `EdgeInsetsDirectional` downstream would have made a
///   difference, because nothing was ever going to set the direction.
/// - Without it, `Localizations.localeOf` is always `en_US`, so Material's own
///   strings — the back button's semantics label, the text selection menu, the
///   date and time pickers — are always English even on a device that is not.
/// - Without it, `intl`'s `DateFormat` formats every timestamp in the app in the
///   default locale, and always will.
///
/// Declaring `ar` and `he` fixes all three for the two scripts M10 cares about,
/// while the app's own English literals stay English — which is the honest
/// half-state: a right-to-left *layout* with untranslated text, rather than a
/// left-to-right layout pretending the locale does not exist. There are no
/// message keys to leak, so the "fall back cleanly rather than showing keys"
/// requirement is satisfied by there being nothing to fall back from.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' show DateFormat, Intl;

/// The locales Weft declares.
///
/// English first: it is both the fallback and the language the app's literals
/// are written in, and `basicLocaleListResolution` returns the first entry when
/// the device asks for something not on the list.
///
/// `ar` and `he` are the two right-to-left scripts the accessibility pass is
/// verified against — Arabic because it is also the shaping and digit case
/// (Arabic-Indic numerals in timestamps), Hebrew because it is right-to-left
/// without joining behaviour, so the pair catches different layout bugs.
const List<Locale> weftSupportedLocales = [
  Locale('en'),
  Locale('ar'),
  Locale('he'),
];

/// The delegates that make [weftSupportedLocales] mean anything.
///
/// `GlobalMaterialLocalizations.delegates` is the Material, Widgets and
/// Cupertino trio; `GlobalWidgetsLocalizations` is the one that carries
/// `textDirection`, and therefore the one that puts the app into RTL at all.
const List<LocalizationsDelegate<dynamic>> weftLocalizationsDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Points `intl`'s date formatting at [locale], when it has data for it.
///
/// Every `DateFormat` in Weft is constructed without a locale — `DateFormat.Hm()`
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
