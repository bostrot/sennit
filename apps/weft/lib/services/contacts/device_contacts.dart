import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:weft_store/weft_store.dart';

import '../../app/providers.dart';
import '../../app/stores.dart';

/// The address book, folded down to what titling needs: phone digits → name.
///
/// Matching happens entirely on this device — the map never leaves the
/// process, and the store below only caches it so the very first inbox after
/// a cold start already shows the right names instead of waiting on a
/// platform channel.
Future<Map<String, String>?> loadDeviceContactNames() async {
  try {
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return null;
    }
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.name, ContactProperty.phone},
    );
    final byPhone = <String, String>{};
    for (final contact in contacts) {
      final name = contact.displayName?.trim() ?? '';
      if (name.isEmpty) continue;
      for (final phone in contact.phones) {
        final raw = phone.normalizedNumber ?? phone.number;
        final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.length < 7) continue;
        byPhone[digits] = name;
      }
    }
    return byPhone;
  } on Object catch (error) {
    debugPrint('weft: could not read device contacts: $error');
    return null;
  }
}

/// The settings key of the cached phone→name map.
const String kContactNamesCacheKey = 'contacts.device_names_cache';

/// Keeps the repository's name overrides in step with the preference.
///
/// Watched from the inbox shell so it lives exactly as long as the app shows
/// conversations. Off (the default) applies an empty map, which is also what
/// clears the names the moment the user changes their mind. On, the cached
/// map applies immediately and a fresh read of the address book follows —
/// permission was granted when the toggle was turned on, so the refresh is
/// silent.
final contactNamesSyncProvider = Provider<void>((ref) {
  ref.watch(settingsRevisionProvider);
  final repository = ref.watch(chatRepositoryProvider);
  final stores = storesOrNull(ref);
  if (stores == null) return;

  if (!stores.settings.getBool(WeftSettings.useDeviceContactNames)) {
    repository.setContactNameOverrides(const {});
    return;
  }

  final cached = stores.settings.getJson(kContactNamesCacheKey);
  repository.setContactNameOverrides({
    if (cached != null)
      for (final entry in cached.entries)
        if (entry.value is String) entry.key: entry.value as String,
  });

  unawaited(() async {
    final fresh = await loadDeviceContactNames();
    if (fresh == null) return;
    stores.settings.setJson(kContactNamesCacheKey, fresh);
    repository.setContactNameOverrides(fresh);
  }());
});
