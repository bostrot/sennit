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
/// answer is a value the Dart side can render as an absent feature rather than
/// as an error.
///
/// The answers are *values* and not booleans, which they used to be. A yes/no
/// could not tell a decline from a system that never showed the dialog, or from
/// an activity destroyed while the dialog was up — and the third of those is a
/// role the system granted, reported to the user as "Nothing changed". See
/// [Outcome].
object SmsRole {
    private const val TAG = "WeftSms"

    /// Activity result code for the role dialog. Arbitrary but must not collide
    /// with another `startActivityForResult` in `MainActivity`.
    const val REQUEST_CODE = 0x5E15

    /// How a role request ended, as the wire strings Dart decodes.
    ///
    /// A boolean was the bug. "Granted" has one meaning and every other answer
    /// has four, and folding them together is what produced a screen saying
    /// "Nothing changed. Braid is not your SMS app" to a user who had just been
    /// made the default SMS app — see the phase-05 diagnosis note. Each of these
    /// leads somewhere different: [DENIED] is the only one the decline copy
    /// belongs on, [UNAVAILABLE] is a device to stop offering the role on, and
    /// [INTERRUPTED] means *ask the system again*, not *report a failure*.
    object Outcome {
        /// Braid holds the role, confirmed by asking the system afterwards.
        const val GRANTED = "granted"

        /// The dialog was shown and Braid still does not hold the role.
        const val DENIED = "denied"

        /// No dialog could be shown: no telephony, no `ROLE_SMS` on this ROM,
        /// or no activity to raise it from. The user was never asked.
        const val UNAVAILABLE = "unavailable"

        /// A second request replaced this one before it was answered.
        const val SUPERSEDED = "superseded"

        /// The activity went away while the dialog was up. The answer exists —
        /// the system knows who holds the role — it simply did not come back
        /// through this call. Dart re-reads the status rather than reporting.
        const val INTERRUPTED = "interrupted"
    }

    /// [Outcome.GRANTED] when [context] holds the role now, [otherwise] if not.
    ///
    /// Every path that ends a request goes through here rather than trusting
    /// the dialog's own result code. The result code reports whether the
    /// *dialog* completed, not what the system did with it, and the two
    /// disagree often enough to matter — a user who was already the default
    /// gets `RESULT_CANCELED`.
    fun outcomeFor(context: Context?, otherwise: String): String =
        if (context != null && isDefault(context)) Outcome.GRANTED else otherwise

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
    ///
    /// `roleAvailable` is reported separately from `canRequestRole` because the
    /// two "no"s read differently on screen: a phone that could carry the role
    /// and simply has another app holding it is one tap from SMS, while a ROM
    /// with the role stripped out is a device where the button must not appear
    /// at all and the sentence has to say why.
    fun status(context: Context): Map<String, Any?> = mapOf(
        "supported" to hasTelephony(context),
        "isDefault" to isDefault(context),
        "canRequestRole" to canRequest(context),
        "roleAvailable" to roleAvailable(context),
        "hasPermissions" to hasPermissions(context),
        "defaultPackage" to Telephony.Sms.getDefaultSmsPackage(context),
    )

    /// Whether this device has a default-SMS-app role to give at all.
    ///
    /// Unlike [canRequest] this stays true once Braid holds the role, so the
    /// screen can tell "the role does not exist here" from "there is nothing
    /// left to ask for".
    fun roleAvailable(context: Context): Boolean = try {
        if (!hasTelephony(context) || !hasRoleComponents(context)) {
            false
        } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            true
        } else {
            context.getSystemService(RoleManager::class.java)
                ?.isRoleAvailable(RoleManager.ROLE_SMS) == true
        }
    } catch (e: Exception) {
        false
    }

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
    ///
    /// Two features, either of which is enough. `FEATURE_TELEPHONY` is the old
    /// blanket answer and is deprecated from API 35, where the platform split it
    /// into per-capability features; `FEATURE_TELEPHONY_MESSAGING` is the one
    /// that means *this device can carry SMS*, which is the only question being
    /// asked here. A phone that reports the new feature and not the old one
    /// would otherwise be told it cannot text.
    fun hasTelephony(context: Context): Boolean = try {
        val packages = context.packageManager
        val messaging = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            packages.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_MESSAGING)
        @Suppress("DEPRECATION")
        val telephony = packages.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
        (messaging || telephony) &&
            (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                ?.phoneType != TelephonyManager.PHONE_TYPE_NONE
    } catch (e: Exception) {
        false
    }

    fun hasPermissions(context: Context): Boolean = REQUIRED.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    /// Whether the role dialog can be shown right now.
    ///
    /// The component check is part of the answer rather than a separate one: a
    /// build missing a required component is one the picker will not list, so a
    /// button wired to this would open a dialog Braid is not in. Offering
    /// nothing is the honest state, and `status` carries the reason across so
    /// Dart can say which of the two "no"s this is.
    fun canRequest(context: Context): Boolean {
        if (!hasTelephony(context)) return false
        if (isDefault(context)) return false
        if (!hasRoleComponents(context)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        val manager = context.getSystemService(RoleManager::class.java) ?: return false
        return manager.isRoleAvailable(RoleManager.ROLE_SMS)
    }

    /// Whether every component `ROLE_SMS` requires is present in this build.
    ///
    /// The role controller decides eligibility by resolving four components
    /// against the package, and an app missing one of them never appears in the
    /// picker — no error, no log line, and a dialog that either does not open or
    /// opens without Braid in it. That is indistinguishable from a decline at
    /// the call site, so it is checked before the dialog rather than guessed at
    /// afterwards, and a false answer is reported as [Outcome.UNAVAILABLE].
    ///
    /// Resolved against this package explicitly. `queryIntentActivities` without
    /// a package filter answers about the whole device, which is a different
    /// question and would pass on any phone with some other SMS app installed.
    @Suppress("DEPRECATION")
    fun hasRoleComponents(context: Context): Boolean = try {
        val packages = context.packageManager
        val self = context.packageName
        val sendTo = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:")).setPackage(self)
        val deliver = Intent(Telephony.Sms.Intents.SMS_DELIVER_ACTION).setPackage(self)
        val wapPush = Intent(Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION)
            .setPackage(self)
            .setType(MMS_MIME_TYPE)
        val respond = Intent(TelephonyManager.ACTION_RESPOND_VIA_MESSAGE, Uri.parse("smsto:"))
            .setPackage(self)

        val missing = buildList {
            if (packages.queryIntentActivities(sendTo, 0).isEmpty()) add("SENDTO activity")
            if (packages.queryBroadcastReceivers(deliver, 0).isEmpty()) add("SMS_DELIVER receiver")
            if (packages.queryBroadcastReceivers(wapPush, 0).isEmpty()) add("WAP_PUSH_DELIVER receiver")
            if (packages.queryIntentServices(respond, 0).isEmpty()) add("RESPOND_VIA_MESSAGE service")
        }
        if (missing.isNotEmpty()) {
            Log.w(TAG, "not eligible for ROLE_SMS, missing: ${missing.joinToString()}")
        }
        missing.isEmpty()
    } catch (e: Exception) {
        // A resolver that refuses to answer is not evidence of ineligibility.
        // Assuming the components are there costs a dialog that may not open;
        // assuming they are not costs the feature outright on a working phone.
        Log.w(TAG, "could not resolve the ROLE_SMS components", e)
        true
    }

    /// Shows the system's default-SMS-app dialog.
    ///
    /// Returns whether it could be shown at all — false is a device that has no
    /// such dialog, not a user who said no. The answer to the *question* comes
    /// back as an activity result, because the dialog belongs to the system and
    /// there is no callback.
    fun request(activity: Activity): Boolean {
        if (!hasTelephony(activity)) return false
        if (!hasRoleComponents(activity)) return false
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

    /// The MMS notification PDU's type, as the role's `WAP_PUSH_DELIVER` filter
    /// spells it. Named rather than repeated — the manifest carries the same
    /// literal, and a component check that disagreed with the manifest by one
    /// character would report a build ineligible for a reason that is not true.
    private const val MMS_MIME_TYPE = "application/vnd.wap.mms-message"
}
