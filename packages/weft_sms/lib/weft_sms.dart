/// SMS and MMS as one more network in the inbox, rather than a tab beside it.
///
/// Pure Dart, and it has to be: everything in here is a decision the Android
/// default-SMS role depends on and none of it is I/O. Whether a body costs one
/// billable segment or four, whether a photo survives the MMSC, and whether the
/// number on an SMS thread is the same person as a WhatsApp handle are all
/// answerable without a SIM, a carrier or a device — and all three are wrong in
/// ways nobody notices until a message quietly fails to arrive.
///
/// The phone normaliser is `weft_merge`'s `normalizePhone`, not a copy of it.
/// Both sides of a merge comparison must fold a number identically, and two
/// normalisers that drift apart do not fail loudly — they just stop matching.
library;

// Consumers import this barrel, never src/.
export 'src/identity.dart';
export 'src/mms.dart';
export 'src/phone.dart';
export 'src/segment.dart';
export 'src/thread.dart';
