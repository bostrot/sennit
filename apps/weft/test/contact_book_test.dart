import 'package:flutter_test/flutter_test.dart';
import 'package:weft/services/contacts/contact_book.dart';

/// Address-book numbers as people really store them, against the forms the
/// SMS provider and the bridges hand over.
void main() {
  ContactBook book({String? defaultCountryCode}) => ContactBook.fromEntries([
    // Saved in national format with spaces, the way it was typed.
    (name: 'Anna', photoPath: '/p/anna.jpg', numbers: ['0151 1234 5678']),
    // Saved internationally with dashes and brackets.
    (name: 'Ben', photoPath: null, numbers: ['+49 (30) 1234-5678']),
    // Saved with the 00 international prefix.
    (name: 'Chloé', photoPath: null, numbers: ['0044 20 7946 0958']),
    // A short code the user named.
    (name: 'Bank', photoPath: null, numbers: ['22020']),
    // A contact with no name is not a name.
    (name: '  ', photoPath: null, numbers: ['+33 6 12 34 56 78']),
  ], defaultCountryCode: defaultCountryCode);

  test('E.164 from the provider matches a national-format contact', () {
    final contact = book().lookup('+4915112345678');
    expect(contact?.name, 'Anna');
    expect(contact?.photoUrl, 'file:///p/anna.jpg');
  });

  test('a national number matches with or without a known region', () {
    expect(book().lookup('01511 2345678')?.name, 'Anna');
    expect(book(defaultCountryCode: '49').lookup('015112345678')?.name, 'Anna');
  });

  test('a bridge id without the plus matches', () {
    expect(book().lookup('493012345678')?.name, 'Ben');
    expect(book().lookup('@whatsapp_493012345678:example.org')?.name, 'Ben');
  });

  test('the national form matches an international contact', () {
    expect(book(defaultCountryCode: '49').lookup('030 12345678')?.name, 'Ben');
    // No region: still the same last nine digits.
    expect(book().lookup('030 12345678')?.name, 'Ben');
  });

  test('00-prefixed and +-prefixed are the same number', () {
    expect(book().lookup('+44 20 7946 0958')?.name, 'Chloé');
  });

  test('short codes match exactly and never by suffix', () {
    expect(book(defaultCountryCode: '49').lookup('22020')?.name, 'Bank');
    expect(book().lookup('2020'), isNull);
    expect(book().lookup('122020'), isNull);
  });

  test('a different number is not a match', () {
    expect(book().lookup('+4915112345679'), isNull);
    expect(book().lookup('+33612345678'), isNull);
    expect(book().lookup(null), isNull);
    expect(book().lookup('Vodafone'), isNull);
  });

  test('the cache round-trips', () {
    final original = book(defaultCountryCode: '49');
    final cache = original.toCache();
    final restored = ContactBook.fromCache(
      cache.names,
      cache.photos,
      defaultCountryCode: '49',
    );
    expect(restored, original);
    expect(restored.lookup('+4915112345678')?.photoPath, '/p/anna.jpg');
  });

  test('the first contact keeps a shared number', () {
    final shared = ContactBook.fromEntries([
      (name: 'Office', photoPath: null, numbers: ['+49 30 1234 5678']),
      (name: 'Reception', photoPath: null, numbers: ['030 12345678']),
    ], defaultCountryCode: '49');
    expect(shared.lookup('+493012345678')?.name, 'Office');
  });
}
