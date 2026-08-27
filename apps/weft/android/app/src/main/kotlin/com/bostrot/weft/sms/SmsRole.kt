package com.bostrot.weft.sms

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import android.telephony.TelephonyManager
import android.util.Log

/// Asking to be the default SMS app, and knowing when Weft is not.
///
/// The decline path is the important one. Weft is a Matrix client that can
/// *also* carry SMS; it is not an SMS app that happens to do Matrix. A user who
/// says no — or who is on a tablet with no radio, or who later hands the role
/// to someone else — must get an app that behaves exactly as it did before,
/// with the SMS network simply not in the inbox. Nothing here throws, and every
/// answer is a boolean the Dart side can render as an absent feature rather
/// than an error.
object SmsRole {
    private const val TAG = "WeftSms"

    /// Activity result code for the role dialog. Arbitrary but must not collide
    /// with another `startActivityForResult` in `MainActivity`.
    const val REQUEST_CODE = 0x5E15

    /// The permissions the role carries.
    ///
    /// Not requested directly: granting ROLE_SMS grants the SMS group, and an
    /// app that asks for `READ_SMS` on its own is answered with the Play policy
    /// rather than a prompt. They are *checked* because holding the role and
    /// holding the permissions are not the same instant — a role handed over in
    /// Settings while Weft is in the background revokes them under a running
    /// read.
    private val REQUIRED = arrayOf(
        Manifest.permission.READ_SMS,
        Manifest.permission.SEND_SMS,
        Manifest.permission.RECEIVE_SMS,
    )

    /// What Dart needs to decide whether SMS is part of this device's inbox.
    fun status(context: Context): Map<String, Any?> = mapOf(
        "supported" to hasTelephony(context),
        "isDefault" to isDefault(context),
        "canRequestRole" to canRequest(context),
        "hasPermissions" to hasPermissions(context),
        "defaultPackage" to Telephony.Sms.getDefaultSmsPackage(context),
    )

    /// Whether Weft currently holds the role.
    fun isDefault(context: Context): Boolean = try {
        context.packageName == Telephony.Sms.getDefaultSmsPackage(context)
    } catch (e: Exception) {
        false
    }

    /// Whether this device can send an SMS at all.
    ///
    /// A tablet, an emulator without a modem and a Wi-Fi-only device all reach
    /// here. Offering the role on one of them produces a dialog that cannot be
    /// accepted, which reads as a broken app rather than an unsupported one.
    fun hasTelephony(context: Context): Boolean = try {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) &&
            (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                ?.phoneType != TelephonyManager.PHONE_TYPE_NONE
    } catch (e: Exception) {
        false
    }

    fun hasPermissions(context: Context): Boolean = REQUIRED.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    /// Whether the role dialog can be shown right now.
    fun canRequest(context: Context): Boolean {
        if (!hasTelephony(context)) return false
        if (isDefault(context)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        val manager = context.getSystemService(RoleManager::class.java) ?: return false
        return manager.isRoleAvailable(RoleManager.ROLE_SMS)
    }

    /// Shows the system's default-SMS-app dialog.
    ///
    /// Returns whether it could be shown at all — false is a device that has no
    /// such dialog, not a user who said no. The answer to the *question* comes
    /// back as an activity result, because the dialog belongs to the system and
    /// there is no callback.
    fun request(activity: Activity): Boolean {
        if (!hasTelephony(activity)) return false
        return try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                activity.getSystemService(RoleManager::class.java)
                    ?.takeIf { it.isRoleAvailable(RoleManager.ROLE_SMS) }
                    ?.createRequestRoleIntent(RoleManager.ROLE_SMS)
            } else {
                // Pre-Q there is no RoleManager; the same choice is made
                // through an intent the telephony provider exposes.
                @Suppress("DEPRECATION")
                Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).putExtra(
                    Telephony.Sms.Intents.EXTRA_PACKAGE_NAME,
                    activity.packageName,
                )
            } ?: return false
            activity.startActivityForResult(intent, REQUEST_CODE)
            true
        } catch (e: Exception) {
            // A ROM with the role stripped out, or an activity torn down
            // between the tap and the launch. Neither is worth a crash in an
            // app whose SMS support is optional by design.
            Log.w(TAG, "could not show the default-SMS-app dialog", e)
            false
        }
    }

    /// Opens Android's own default-apps settings, so the role can be handed on.
    ///
    /// There is no API for giving the role up: `RoleManager` can request a role
    /// and cannot release one, and the system dialog only ever asks about the
    /// app that raised it. Which left Weft as a one-way door — take the role and
    /// the way back is a settings screen the user has to go and find. That
    /// matters more than it sounds, because the role costs the phone its RCS,
    /// and somebody who wants it back should not have to hunt for the switch.
    fun openDefaultAppSettings(context: Context): Boolean {
        val candidates = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
            }
            // Pre-Q, and as the fallback for a ROM whose default-apps screen is
            // somewhere else entirely: app settings is always reachable and the
            // choice is one level in from there.
            add(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                ),
            )
        }
        for (intent in candidates) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: Exception) {
                Log.w(TAG, "could not open ${intent.action}", e)
            }
        }
        return false
    }
}
