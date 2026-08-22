package com.bostrot.weft.sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// Brings the connection back after a reboot.
///
/// Only when the user turned the toggle on — a reboot must not opt anyone in
/// — and via the service so every rule about foreground types and the daemon
/// engine stays in one place.
class SyncBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!WeftSyncService.isEnabled(context)) return
        try {
            WeftSyncService.start(context)
        } catch (e: Exception) {
            // A refused boot-time start costs this boot's connection, nothing
            // else; opening the app once brings it back.
        }
    }
}
