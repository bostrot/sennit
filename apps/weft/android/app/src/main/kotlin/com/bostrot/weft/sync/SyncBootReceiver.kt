package com.bostrot.weft.sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/// Brings the connection back after a reboot.
///
/// Only when the user turned the toggle on — a reboot must not opt anyone in
/// — and via the service so every rule about foreground types and the daemon
/// engine stays in one place.
///
/// **Not direct-boot aware, deliberately.** A device with file-based encryption
/// sends `LOCKED_BOOT_COMPLETED` before the user has unlocked, and a
/// `directBootAware` receiver would be woken by it — into a process that can
/// read only *device*-protected storage. Everything this service needs is in
/// credential-protected storage: the Matrix session, the account's own keys, the
/// Olm store, and the `weft_sync` preference that says whether the connection is
/// wanted at all. None of it is readable before the first unlock, so a receiver
/// that ran there would start a foreground service, post a notification the user
/// can see on their lock screen, fail to sign in, and stop — a visible failure in
/// exchange for nothing.
///
/// Moving that data to device-protected storage is not a fix, it is the same
/// question answered worse: it would put an end-to-end encrypted messenger's
/// long-term keys somewhere the OS decrypts before anybody has proved they are
/// the owner of the phone. So the connection resumes at `BOOT_COMPLETED`, which
/// on an encrypted device is delivered after the first unlock. The consequence
/// is real and worth stating rather than hiding: between a reboot and the first
/// unlock, an encrypted Android phone does not sync. Push still wakes the app if
/// a gateway is configured, because that path belongs to the system.
///
/// See `docs/architecture/notifications.md`, "Coming back after a reboot".
class SyncBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return
        if (!WeftSyncService.isEnabled(context)) return
        try {
            WeftSyncService.start(context)
        } catch (e: Exception) {
            // A refused boot-time start costs this boot's connection, nothing
            // else; opening the app once brings it back. Logged rather than
            // swallowed, because the two causes — a `specialUse` service
            // refused at boot, and a device that never delivered the broadcast
            // — look identical from the outside and one of them is a bug.
            Log.w(TAG, "could not start the connection after ${intent.action}", e)
        }
    }

    companion object {
        private const val TAG = "WeftSync"

        /// The broadcasts that mean "the phone has just started".
        ///
        /// `BOOT_COMPLETED` is the one Android documents and the only one most
        /// devices send. The two `QUICKBOOT_POWERON` spellings are what a
        /// number of vendor ROMs — HTC's originally, and the Chinese OEM forks
        /// that inherited its power-management code — send *instead* when the
        /// phone comes back from a "fast boot" shutdown, which is the default
        /// shutdown on those devices. An app that listens for `BOOT_COMPLETED`
        /// alone is simply never started on them, and it presents exactly as
        /// this bug was reported: notifications stop after a restart until the
        /// app is opened by hand.
        ///
        /// `LOCKED_BOOT_COMPLETED` is deliberately absent — see the class
        /// comment. This list and the manifest's `<intent-filter>` are the same
        /// list and `sync_boot_test.dart` holds them together; a receiver
        /// registered for an action it then ignores is a silent no-op.
        val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
