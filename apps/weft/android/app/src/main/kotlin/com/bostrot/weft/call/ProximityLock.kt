package com.bostrot.weft.call

import android.content.Context
import android.os.PowerManager

/// The screen-off-against-the-ear lock.
///
/// `PROXIMITY_SCREEN_OFF_WAKE_LOCK` is the only API that does this on Android:
/// it is not a sensor listener and a `View.setKeepScreenOn(false)` is not a
/// substitute — the point is that the display is blanked *and the touchscreen
/// stops responding*, which is what stops a cheek ending the call. There is no
/// public constant for it, hence the literal and the `isWakeLockLevelSupported`
/// check: the flag is honoured on essentially every phone and on essentially no
/// tablet, and asking for an unsupported level throws.
///
/// The policy above this — proximity only for a voice call on the earpiece,
/// never a video one — lives in `call_service.dart`, where it is a pure function
/// with tests. This is only the switch it throws.
object ProximityLock {
    /// `PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK`, which is public API in
    /// name only — the constant is annotated `@hide`.
    private const val PROXIMITY_SCREEN_OFF_WAKE_LOCK = 32

    private const val TAG = "weft:call:proximity"

    private var lock: PowerManager.WakeLock? = null

    /// Acquires or releases the lock, returning whether the device has one.
    ///
    /// False on a tablet with no proximity sensor, which is not a failure: a
    /// screen that stays on during a call on a device nobody holds to their face
    /// is the correct behaviour, and the Dart side treats the answer as
    /// informational.
    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        if (!power.isWakeLockLevelSupported(PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return false

        if (!enabled) {
            lock?.takeIf { it.isHeld }?.release()
            lock = null
            return true
        }

        if (lock?.isHeld == true) return true
        @Suppress("WakelockTimeout")
        return try {
            val acquired = power.newWakeLock(PROXIMITY_SCREEN_OFF_WAKE_LOCK, TAG)
            // No timeout: the lock is released by the call ending, and a call
            // longer than any timeout worth picking is an ordinary call.
            acquired.acquire()
            lock = acquired
            true
        } catch (e: Exception) {
            false
        }
    }
}
