/// Android, iOS and the desktops have no system-wide "do not track" switch an
/// app can read; the consent question is the only answer that counts there.
bool platformAsksNotToTrack() => false;
