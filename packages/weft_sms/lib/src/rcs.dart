/// Where RCS stands on an Android phone, and what the messaging role does to it.
///
/// RCS is the one network in this app that Braid cannot carry itself, and not
/// for want of trying: Android exposes no RCS API to a third-party app. RCS on
/// Android is the Google Messages app talking to Google's Jibe network; the
/// API that drives it is granted to a short list of Samsung system apps and
/// nobody else; and Google Messages speaks RCS only while it holds the phone's
/// default-messaging role.
///
/// So "Braid is your SMS app" and "this phone has RCS" are mutually exclusive,
/// and taking the role does not move RCS to Braid — it turns RCS off for the
/// whole phone and drops those conversations back to SMS and MMS. That is a
/// sentence the user has to read *before* the system dialog rather than
/// discover a week later, and everything in this file exists to state it
/// accurately for the phone actually in their hand.
library;

/// The app that carries RCS on Android.
///
/// One entry, because there is one: the carriers that ran their own RCS —
/// AT&T's Advanced Messaging, Verizon through Samsung Messages — have handed
/// it to Google's network, and every other messaging app on the Play Store is
/// in exactly Braid's position.
const String kGoogleMessagesPackage = 'com.google.android.apps.messaging';

/// Package ids worth spelling as names.
///
/// A package id is what the phone reports and a name is what the user chose in
/// a settings screen, so telling them which app is in the way means saying
/// "Google Messages" rather than `com.google.android.apps.messaging`. Unknown
/// ids are still shown — they are ugly, but they are actionable, and inventing
/// a friendly name for an app nobody here has heard of would not be.
const Map<String, String> kMessagingAppNames = {
  kGoogleMessagesPackage: 'Google Messages',
  'com.android.messaging': 'Messaging',
  'com.samsung.android.messaging': 'Samsung Messages',
  'com.textra': 'Textra',
  'org.thoughtcrime.securesms': 'Signal',
  'com.moez.QKSMS': 'QKSMS',
  'org.fossify.messages': 'Fossify Messages',
  'com.simplemobiletools.smsmessenger': 'Simple SMS Messenger',
  'com.google.android.apps.messaging.dogfood': 'Google Messages',
  'com.bostrot.weft': 'Braid',
};

/// [package] as something to read, falling back to the id itself.
String? messagingAppName(String? package) {
  final id = package?.trim();
  if (id == null || id.isEmpty) return null;
  return kMessagingAppNames[id] ?? id;
}

/// Whether [package] is the app that can carry RCS on this phone.
bool isRcsCapableApp(String? package) =>
    package?.trim() == kGoogleMessagesPackage;

/// What the default-messaging role currently costs, in RCS.
enum RcsStanding {
  /// A device that cannot carry SMS at all, so there is no RCS question.
  unavailable,

  /// Google Messages holds the role, so RCS is working — and it is working
  /// *there*, not here. Braid sees those conversations only if the phone is
  /// bridged.
  withGoogleMessages,

  /// Braid holds the role, so this phone sends SMS and MMS and no RCS.
  offForBraid,

  /// Another app holds the role, and RCS is off for exactly the reason it
  /// would be off for Braid. Nothing is lost by switching.
  offForOther,
}

/// Where RCS stands, from the two facts the platform reports.
RcsStanding rcsStanding({
  required bool supported,
  required bool braidIsDefault,
  required String? defaultPackage,
}) {
  if (!supported) return RcsStanding.unavailable;
  if (braidIsDefault) return RcsStanding.offForBraid;
  return isRcsCapableApp(defaultPackage)
      ? RcsStanding.withGoogleMessages
      : RcsStanding.offForOther;
}

/// Whether taking the role would turn RCS off on this phone.
///
/// True only when RCS is plausibly on right now. Taking the role from Textra
/// costs nothing, and warning about it there would teach the user to click
/// through the warning that matters.
bool takingRoleEndsRcs(String? defaultPackage) =>
    isRcsCapableApp(defaultPackage);
