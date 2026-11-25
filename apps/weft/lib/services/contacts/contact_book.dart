import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:weft_merge/weft_merge.dart' show normalizePhone;

/// One address-book person as the inbox needs them: a name and maybe a face.
@immutable
class DeviceContact {
  const DeviceContact({required this.name, this.photoPath});

  final String name;

  /// A thumbnail written to the app's own storage, or null for no photo.
  final String? photoPath;

  /// [photoPath] as an image URL the avatar widget understands.
  String? get photoUrl =>
      photoPath == null ? null : Uri.file(photoPath!).toString();

  @override
  bool operator ==(Object other) =>
      other is DeviceContact &&
      other.name == name &&
      other.photoPath == photoPath;

  @override
  int get hashCode => Object.hash(name, photoPath);
}

/// The address book, keyed by every form its numbers can take.
///
/// The two sides of a lookup almost never write a number the same way: the SMS
/// provider says `+4915112345678` for a message that arrived and `0151 1234567`
/// for one the user typed, a bridge says `4915112345678`, and the contacts app
/// stores whatever was typed into it years ago. So a contact is filed under the
/// digits of its E.164 form *and* the digits as written, and a lookup tries the
/// same two forms of the question before falling back to the last nine digits —
/// which is what `+49 151…` and `0151…` still agree on when nothing knows the
/// region.
///
/// Short codes (`22020`) match exactly or not at all: their last digits are
/// somebody else's whole number.
@immutable
class ContactBook {
  ContactBook(Map<String, DeviceContact> byDigits, {this.defaultCountryCode})
    : _byDigits = Map.unmodifiable(byDigits),
      _bySuffix = Map.unmodifiable({
        for (final entry in byDigits.entries)
          if (entry.key.length >= _suffixDigits)
            _suffix(entry.key): entry.value,
      });

  /// No contacts: what the inbox uses while the preference is off.
  static final ContactBook empty = ContactBook(const {});

  /// Builds the book from `(name, photo, numbers)` rows as a contacts provider
  /// hands them over, normalising each number against [defaultCountryCode].
  factory ContactBook.fromEntries(
    Iterable<({String name, String? photoPath, List<String> numbers})>
    entries, {
    String? defaultCountryCode,
  }) {
    final byDigits = <String, DeviceContact>{};
    for (final entry in entries) {
      final name = entry.name.trim();
      if (name.isEmpty) continue;
      final contact = DeviceContact(name: name, photoPath: entry.photoPath);
      for (final number in entry.numbers) {
        for (final key in _keysFor(number, defaultCountryCode)) {
          // The first contact to claim a number keeps it, so a shared office
          // line does not flip between two names from one read to the next.
          byDigits.putIfAbsent(key, () => contact);
        }
      }
    }
    return ContactBook(byDigits, defaultCountryCode: defaultCountryCode);
  }

  /// Country calling code national numbers are read against, if known.
  final String? defaultCountryCode;

  final Map<String, DeviceContact> _byDigits;
  final Map<String, DeviceContact> _bySuffix;

  /// Agreement this long is the same number; shorter, numbers collide.
  static const int _suffixDigits = 9;

  /// Fewest digits worth filing: a short code.
  static const int _minDigits = 3;

  /// Most digits a short code has; see `kShortCodeMaxDigits`.
  static const int _maxShortCodeDigits = 6;

  bool get isEmpty => _byDigits.isEmpty;

  /// Every filed number in digits, mapped to its contact.
  Map<String, DeviceContact> get byDigits => _byDigits;

  /// The contact [phone] belongs to, or null.
  DeviceContact? lookup(String? phone) {
    if (phone == null || _byDigits.isEmpty) return null;
    final keys = _keysFor(phone, defaultCountryCode);
    for (final key in keys) {
      final exact = _byDigits[key];
      if (exact != null) return exact;
    }
    for (final key in keys) {
      if (key.length < _suffixDigits) continue;
      final bySuffix = _bySuffix[_suffix(key)];
      if (bySuffix != null) return bySuffix;
    }
    return null;
  }

  /// The first contact any of [phones] belongs to, or null.
  DeviceContact? lookupAny(Iterable<String?> phones) {
    for (final phone in phones) {
      final contact = lookup(phone);
      if (contact != null) return contact;
    }
    return null;
  }

  /// The cache form: digits → name, and digits → photo path.
  ({Map<String, String> names, Map<String, String> photos}) toCache() => (
    names: {for (final e in _byDigits.entries) e.key: e.value.name},
    photos: {
      for (final e in _byDigits.entries)
        if (e.value.photoPath != null) e.key: e.value.photoPath!,
    },
  );

  /// The book [toCache] wrote, read back.
  factory ContactBook.fromCache(
    Map<String, Object?>? names,
    Map<String, Object?>? photos, {
    String? defaultCountryCode,
  }) {
    final byDigits = <String, DeviceContact>{};
    for (final entry in (names ?? const <String, Object?>{}).entries) {
      final name = entry.value;
      if (name is! String || name.trim().isEmpty) continue;
      final photo = photos?[entry.key];
      byDigits[entry.key] = DeviceContact(
        name: name,
        photoPath: photo is String && photo.isNotEmpty ? photo : null,
      );
    }
    return ContactBook(byDigits, defaultCountryCode: defaultCountryCode);
  }

  @override
  bool operator ==(Object other) =>
      other is ContactBook &&
      other.defaultCountryCode == defaultCountryCode &&
      const MapEquality<String, DeviceContact>().equals(
        other._byDigits,
        _byDigits,
      );

  @override
  int get hashCode => Object.hash(defaultCountryCode, _byDigits.length);

  /// The digit strings [raw] is filed and looked up under, best first.
  static List<String> _keysFor(String raw, String? defaultCountryCode) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < _minDigits) return const [];
    // A short code stays as written: read as a national number it would grow
    // a country code and become a plausible stranger's.
    if (digits.length <= _maxShortCodeDigits && !raw.trim().startsWith('+')) {
      return [digits];
    }
    final e164 = normalizePhone(raw, defaultCountryCode: defaultCountryCode);
    final international = e164?.substring(1);
    return [?international, if (digits != international) digits];
  }

  static String _suffix(String digits) =>
      digits.substring(digits.length - _suffixDigits);
}
