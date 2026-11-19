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

## CarPlay and Siri: entitled since 2026-11-19

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

### Entitlements and signing

Apple assigned the CarPlay Communication entitlement to the team on
2026-11-19. Siri and CarPlay are enabled on the `com.bostrot.weft` App ID, and
`apps/weft/ios/Runner/Runner.entitlements` (used by Debug, Release and
Profile) carries:

```xml
<key>com.apple.developer.siri</key>
<true/>
<key>com.apple.developer.carplay-communication</key>
<true/>
```

The TestFlight workflow signs automatically with the App Store Connect API
key, so each run regenerates the profiles from the App ID's capabilities. An
entitlement in the file that the App ID lacks fails the archive; enable it on
the App ID first. `car_integrations_test.dart` holds the file to both keys.

**Siri permission.** iOS routes no messaging intent to an app until the user
allows Siri for it. Sennit asks once, through `INPreferences.requestSiriAuthorization`
on the `com.bostrot.weft/siri` channel (`requestAuthorization`,
`authorizationStatus`). It asks after sign-in and after the notification
question is settled, and only while the answer is still undetermined, never on
first launch. Someone who said no can change it in Settings → Apps → Sennit →
Siri.

**No CarPlay scene.** A messaging app appears in CarPlay through SiriKit and
notifications. Apple's CarPlay Developer Guide requires text-messaging apps to
support sending messages, searching for messages and setting message
attributes (the three intents above), and a notification category with the
CarPlay option (`allowInCarPlay`). The CarPlay framework's templates, and the
`CPTemplateApplicationSceneSessionRoleApplication` scene they need, are
optional for communication apps, so Sennit declares none. Sources: the
[CarPlay Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)
and [Accelerate your app with CarPlay (WWDC20)](https://developer.apple.com/videos/play/wwdc2020/10635/).

### Testing it

In Xcode's simulator use **I/O → External Displays → CarPlay**, or a car or
CarPlay head unit with a TestFlight build: allow Siri for Sennit when asked,
then "Hey Siri, read my messages", "Reply …", "Send a message to <name> on
Sennit" and "Mark them as read". A message notification should show in
CarPlay with the sender, and Siri should offer to read it.

### Not done yet

- **Communication notifications** (sender avatar on the banner, Siri
  announcing messages on AirPods and in CarPlay). They need an
  `INSendMessageIntent` with the sender's `INPerson` applied to the
  notification content when it is posted (`content.updating(from:)`), and the
  Communication Notifications capability on the App ID and in the
  entitlements. `flutter_local_notifications` cannot do that, and the
  notification service extension only sees the room and event id, not the
  decrypted sender, so this needs a native posting path or extension
  decryption first.
