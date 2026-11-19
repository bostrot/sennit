# Android Auto and CarPlay

Neither car platform runs Sennit's UI. Both read the user's messages through
the phone and answer through it, and both are built on things Sennit already
had: notifications, the notification actions, and `ChatRepository.send` /
`markRead`. Nothing here adds a network call; a reply and a read receipt go
to the user's own homeserver exactly as from the composer.

## Android Auto: working

A messaging app is a notification app in the car. The head unit shows and
speaks a notification that has:

| Requirement | Where |
|---|---|
| `com.google.android.gms.car.application` → `@xml/automotive_app_desc` (`<uses name="notification"/>`) | `AndroidManifest.xml`, `res/xml/automotive_app_desc.xml` |
| `MessagingStyle` with a keyed self `Person` and a keyed `Person` per sender, conversation title and `isGroupConversation` for groups | `NotificationPresentation.forMessage` |
| `category: message` | same |
| Reply action: `RemoteInput`, `SEMANTIC_ACTION_REPLY`, `setShowsUserInterface(false)` | `weftAndroidMessageActions` |
| Mark-as-read action: `SEMANTIC_ACTION_MARK_AS_READ`, `setShowsUserInterface(false)` | same |
| A receiver for those broadcasts | `ActionBroadcastReceiver` in the manifest |

**How a headless action is done.** `flutter_local_notifications` delivers a
`showsUserInterface: false` action to a fresh engine, in
`runBackgroundNotificationAction` (`background_push.dart`). That isolate has
no Matrix client, and must not open a second one next to a live one, so it
first offers the action over `IsolateNameServer` (`background_actions.dart`)
to whichever isolate in the process has a client — the UI isolate or the
sync daemon. Only when nobody accepts within two seconds does it boot the
same headless stack background push uses, and run the same
`NotificationActionHandler`: the reply is sent, the read receipt is sent, and
the conversation's notification is cancelled. A reply that cannot be sent
leaves the notification up.

**Privacy.** The car reads what the notification says. With message previews
off, that is the sender and "New message" — the body is replaced before the
notification is built.

**Reply reminders stay out of the car.** They are posted with
`category: reminder`, without `MessagingStyle` and without a reply or
mark-as-read action. Android Auto shows only conversations, so it never
offers them, which is the intent: a reminder is Sennit talking, not a person,
and the car is the wrong place for a nudge to answer someone. On iOS their
category has no `allowInCarPlay` for the same reason.

**Mute for an hour** still opens Sennit. The timed mute lives in the UI
isolate's policy, and no car surface offers mute.

### Testing it with the Desktop Head Unit

1. Install the DHU: `sdkmanager "extras;google;auto"`.
2. On the phone or emulator, open Android Auto's settings, tap the version
   ten times to unlock developer settings, and choose **Start head unit
   server** from the overflow menu.
3. `adb forward tcp:5277 tcp:5277` and run
   `$ANDROID_HOME/extras/google/auto/desktop-head-unit`.
4. Send the signed-in account a message from another account. The DHU shows
   the notification; tap it to hear it, use the reply button (DHU voice input
   types the reply in the DHU console) and check the reply arrives and the
   peer sees a read receipt.

### Play Console

Google reviews apps that declare Android Auto support. Before the next
production release, opt in to the Android Auto form factor in the Play
Console (*Advanced settings → Form factors*) and accept the Android for Cars
App Quality terms; the review is against the messaging notification
guidelines above. Until Google accepts it, the car shows a Play build only
with *Unknown sources* enabled in Android Auto's developer settings.

## CarPlay and Siri: code ready, entitlements needed

CarPlay messaging is SiriKit plus notifications. Sennit handles the three
intents CarPlay requires in the app (no Intents extension, for the same
reason the notification service extension does not decrypt — the Matrix
client lives in the app process):

| Intent | What it does | Where |
|---|---|---|
| `INSearchForMessagesIntent` | "Read my messages": the newest unread message of up to ten unmuted conversations | `SiriIntents.swift`, `siri_messaging.dart` |
| `INSendMessageIntent` | "Reply" / "Send a message to Anna on Sennit": resolves the name against chat titles, sends with `ChatRepository.send`, marks read | same |
| `INSetMessageAttributeIntent` | "Mark as read": read receipt for each conversation | same |

What Siri reads obeys the preview setting: with previews off it says who
wrote and "New message". `Info.plist` has `NSSiriUsageDescription`
(translated in every `InfoPlist.strings`), `INIntentsSupported` and
`NSUserActivityTypes`, and the message notification category has
`allowInCarPlay`.

Separately, this release fixes the iOS notification actions themselves: Reply
and Mark read on a notification did nothing before (the plugin's background
engine had no plugin registrant and no Dart handler). `AppDelegate` now
registers one and the actions go through the same relay as on Android.

### What only the account holder can do

Nothing above is active until the build is signed with these entitlements.
They are **not** in `Runner.entitlements` on purpose: the TestFlight workflow
signs automatically with an API key, and an entitlement the App ID does not
have — `carplay-communication` cannot be enabled without Apple's approval —
fails the archive and would block the release.

1. **Request the CarPlay entitlement.** <https://developer.apple.com/contact/carplay/>
   (Certificates, Identifiers & Profiles → *Request CarPlay entitlement*),
   category **Communication / messaging**, for `com.bostrot.weft`. Apple
   replies by email; it can take weeks.
2. **Enable Siri** on the `com.bostrot.weft` App ID (Identifiers → App ID →
   Capabilities → Siri), and **Communication Notifications** if wanted.
3. Once granted, add to `apps/weft/ios/Runner/Runner.entitlements`:

   ```xml
   <key>com.apple.developer.siri</key>
   <true/>
   <key>com.apple.developer.carplay-communication</key>
   <true/>
   <key>com.apple.developer.usernotifications.communication</key>
   <true/>
   ```

   and let the next TestFlight run regenerate the profile.
4. Ask for Siri authorisation once, after notifications are allowed
   (`INPreferences.requestSiriAuthorization`). It is not called today
   because calling it without the Siri entitlement raises an exception.
5. Test in Xcode's simulator with **I/O → External Displays → CarPlay**, or
   on a device: "Hey Siri, read my messages", "Reply …", and a message sent
   with "Send a message to <name> on Sennit".

### Not done yet

- **Communication notifications** (sender avatar on the banner, Siri
  announcing messages on AirPods and in CarPlay). They need an
  `INSendMessageIntent` with the sender's `INPerson` applied to the
  notification content when it is posted (`content.updating(from:)`), and the
  entitlement in step 3. `flutter_local_notifications` cannot do that, and the
  notification service extension only sees the room and event id, not the
  decrypted sender, so this needs a native posting path or extension
  decryption first.
