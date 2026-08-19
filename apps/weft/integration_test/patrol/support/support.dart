/// One import for the device suite's shared machinery.
///
/// Account provisioning, login, teardown and the app driver are separate files
/// because they answer separate questions — what the world is, who else is in
/// it, how the app is worked, what the platform does with a file, what a
/// scenario starts from, how this device becomes trusted, and what is in the
/// notification shade — but a scenario needs all of them and should say so once.
library;

export 'accounts.dart';
export 'app.dart';
export 'environment.dart';
export 'media.dart';
export 'scenario.dart';
export 'shade.dart';
export 'verification.dart';
