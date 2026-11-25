import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/providers.dart';
import '../../app/stores.dart';
import 'contact_book.dart';

/// How asking for the address book ended.
enum ContactsAccess {
  /// Read, and the preference is on.
  granted,

  /// Refused this time; asking again shows the system prompt again.
  denied,

  /// Refused for good ("Don't ask again"); only the system settings can
  /// change it, so the caller offers those instead of a prompt that will not
  /// appear.
  blocked,
}

/// The address book, folded down to what titling needs: number → name and
/// photo.
///
/// Matching happens entirely on this device — the book never leaves the
/// process, and the store only caches it so the very first inbox after a cold
/// start already shows the right names instead of waiting on a platform
/// channel. Photos are small thumbnails written to the app's own storage.
///
/// [request] false reads only when permission is already there, which is what
/// a background refresh wants: a system prompt nobody tapped for is a prompt
/// that gets denied.
Future<(ContactBook?, ContactsAccess)> loadDeviceContacts({
  bool request = true,
  String? defaultCountryCode,
}) async {
  try {
    final status = request
        ? await FlutterContacts.permissions.request(PermissionType.read)
        : await FlutterContacts.permissions.check(PermissionType.read);
    switch (status) {
      case PermissionStatus.granted || PermissionStatus.limited:
        break;
      case PermissionStatus.permanentlyDenied || PermissionStatus.restricted:
        return (null, ContactsAccess.blocked);
      default:
        return (null, ContactsAccess.denied);
    }
    final contacts = await FlutterContacts.getAll(
      properties: {
        ContactProperty.name,
        ContactProperty.phone,
        ContactProperty.photoThumbnail,
      },
    );
    final photos = await _writePhotos(contacts);
    final book = ContactBook.fromEntries([
      for (final contact in contacts)
        (
          name: contact.displayName ?? '',
          photoPath: photos[contact.id],
          numbers: [
            for (final phone in contact.phones) ...[
              // Android's own E.164 first: it was formatted against the
              // phone's region, which is the one thing Dart cannot know.
              ?phone.normalizedNumber,
              phone.number,
            ],
          ],
        ),
    ], defaultCountryCode: defaultCountryCode);
    return (book, ContactsAccess.granted);
  } on Object catch (error) {
    debugPrint('weft: could not read device contacts: $error');
    return (null, ContactsAccess.denied);
  }
}

/// Writes each contact's thumbnail to disk and returns contact id → path.
///
/// A file is rewritten only when its size changed, and files for contacts
/// that are gone or lost their photo are deleted, so a refresh after one edit
/// in the address book costs one write rather than a thousand.
Future<Map<String, String>> _writePhotos(List<Contact> contacts) async {
  final out = <String, String>{};
  try {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/contact-photos',
    );
    await dir.create(recursive: true);
    final keep = <String>{};
    var rewrote = false;
    for (final contact in contacts) {
      final id = contact.id;
      final bytes = contact.photo?.thumbnail;
      if (id == null || bytes == null || bytes.isEmpty) continue;
      final file = File(
        '${dir.path}/${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.jpg',
      );
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
        rewrote = true;
      }
      keep.add(file.path);
      out[id] = file.path;
    }
    await for (final entry in dir.list()) {
      if (entry is File && !keep.contains(entry.path)) await entry.delete();
    }
    // A rewritten file keeps its path, and the image cache would keep showing
    // the old face under it.
    if (rewrote) PaintingBinding.instance.imageCache.clear();
  } on Object catch (error) {
    debugPrint('weft: could not store contact photos: $error');
  }
  return out;
}

/// The settings key of the cached number→name map.
const String kContactNamesCacheKey = 'contacts.device_names_cache';

/// The settings key of the cached number→photo-path map.
const String kContactPhotosCacheKey = 'contacts.device_photos_cache';

/// The settings key recording that the SMS prompt for contacts was dismissed.
const String kContactsSmsPromptDismissedKey = 'contacts.sms_prompt_dismissed';

/// The stored country calling code, or null.
String? _countryCode(SettingsStore settings) {
  final stored = settings.getString(WeftSettings.defaultCountryCode)?.trim();
  return stored == null || stored.isEmpty ? null : stored;
}

/// Asks for the address book and, when it is given, turns names on.
///
/// The one path every "use my contacts" button takes — setup, the settings
/// switch, the SMS screen and the strip in an SMS chat — so the permission
/// prompt always belongs to a tap and the cache is always written the same
/// way.
Future<ContactsAccess> enableDeviceContacts(
  SettingsStore settings, {
  required VoidCallback onChanged,
}) async {
  final (book, access) = await loadDeviceContacts(
    defaultCountryCode: _countryCode(settings),
  );
  if (book == null) return access;
  _writeCache(settings, book);
  settings.setBool(WeftSettings.useDeviceContactNames, value: true);
  onChanged();
  return ContactsAccess.granted;
}

void _writeCache(SettingsStore settings, ContactBook book) {
  final cache = book.toCache();
  settings
    ..setJson(kContactNamesCacheKey, cache.names)
    ..setJson(kContactPhotosCacheKey, cache.photos);
}

/// Keeps the repository's address book in step with the preference.
///
/// Watched from the inbox shell so it lives exactly as long as the app shows
/// conversations. Off (the default) applies an empty book, which is also what
/// clears the names the moment the user changes their mind. On, the cached
/// book applies immediately and a fresh read of the address book follows —
/// permission was granted when the toggle was turned on, so the refresh is
/// silent — and again whenever the address book itself changes.
final contactNamesSyncProvider = Provider<void>((ref) {
  ref.watch(settingsRevisionProvider);
  final repository = ref.watch(chatRepositoryProvider);
  final stores = storesOrNull(ref);
  if (stores == null) return;
  final settings = stores.settings;

  if (!settings.getBool(WeftSettings.useDeviceContactNames)) {
    repository.setDeviceContacts(ContactBook.empty);
    return;
  }

  final countryCode = _countryCode(settings);
  repository.setDeviceContacts(
    ContactBook.fromCache(
      settings.getJson(kContactNamesCacheKey),
      settings.getJson(kContactPhotosCacheKey),
      defaultCountryCode: countryCode,
    ),
  );

  Future<void> refresh() async {
    final (fresh, _) = await loadDeviceContacts(
      request: false,
      defaultCountryCode: countryCode,
    );
    if (fresh == null) return;
    _writeCache(settings, fresh);
    repository.setDeviceContacts(fresh);
  }

  // A contact added or renamed while Sennit runs shows up without a restart.
  // Debounced: one edit in the contacts app is several provider writes.
  Timer? debounce;
  StreamSubscription<void>? changes;
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    try {
      changes = FlutterContacts.onDatabaseChange.listen((_) {
        debounce?.cancel();
        debounce = Timer(
          const Duration(seconds: 2),
          () => unawaited(refresh()),
        );
      });
    } on Object catch (error) {
      debugPrint('weft: cannot watch device contacts: $error');
    }
  }
  ref.onDispose(() {
    debounce?.cancel();
    unawaited(changes?.cancel());
  });

  // One fresh read of the address book per app run. The provider recomputes
  // on every settings bump, and re-walking a thousand contacts over the
  // platform channel each time was launch jank nobody ordered; the cache
  // applied above already carries the last run's answer, and the listener
  // above carries every change after it.
  if (_refreshedThisRun) return;
  _refreshedThisRun = true;
  unawaited(refresh());
});

bool _refreshedThisRun = false;
