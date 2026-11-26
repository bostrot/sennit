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

**Later** (Android's third button: remind in an hour, remind tonight, or
mute for an hour) runs headless like Reply, but carries no semantic action,
so no car surface offers it. On iOS the two reminders are actions of their
own beside Mute.

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

## Gemini and Google Assistant on Android

Gemini has replaced Google Assistant on most Android phones and is replacing
it in Android Auto through 2026 ([Android Auto help: Send and receive
messages](https://support.google.com/androidauto/answer/6348317)). Neither
Gemini nor Assistant has a messaging API for third-party apps. What exists,
checked against Google's documentation on 2026-11-20:

| Mechanism | What Google documents | Used by Sennit |
|---|---|---|
| Notification `MessagingStyle` + Reply / Mark-as-read actions | The Android Auto messaging contract ([notification-based messaging](https://developer.android.com/training/cars/communication/notification-messaging)); the assistant reads the notification and dictates into the reply's `RemoteInput` | Since 1.0.12 |
| Long-lived conversation shortcuts with a `Person` ([People and conversations](https://developer.android.com/develop/ui/views/notifications/conversations)) pushed with `pushDynamicShortcut`, and the Google Shortcuts Integration Library so Google surfaces receive them ([creating shortcuts](https://developer.android.com/develop/ui/compose/system/shortcuts/creating-shortcuts#gsi-library)) | How the system and Google's assistant learn which conversations exist and what the people in them are called | Shortcuts since Direct Share; the library and the capability bindings since this change |
| `addCapabilityBinding("actions.intent.SEND_MESSAGE")` / `RECEIVE_MESSAGE` on those shortcuts, with `message.recipient.@type = Audience` for groups | The `ShortcutInfoCompat.Builder` API; the message ids are App Actions built-in intents. Signal publishes exactly these (`ConversationUtil.java`) | Since this change |
| App Actions `actions.intent.CREATE_MESSAGE` capability in `shortcuts.xml` ([reference](https://developer.android.com/reference/app-actions/built-in-intents/communications/create-message)) | Still documented; only the old `actions.xml` form is being retired. **In the car, App Actions only serve parking and charging apps** ([App Actions for cars](https://developer.android.com/develop/devices/assistant/cars)) | Since this change, phone only |
| Gemini "connected apps" (Messages, WhatsApp) | A Google partner integration with no public API | Not possible |

### What works, per case

**(a) Replying by voice to a Sennit notification in the car: works.** The
notification is a `MessagingStyle` conversation with a `SEMANTIC_ACTION_REPLY`
action carrying a single `RemoteInput`, `showsUserInterface(false)`, handled
headless (above). That is all Android Auto and its assistant need to read the
message aloud and send a dictated reply, and it is the same contract Google
documents. Nothing in it is Gemini-specific: the car's assistant fills the
`RemoteInput` either way. This change also binds each notification's
conversation shortcut to `RECEIVE_MESSAGE` and gives it a `LocusId` equal to
its id.

**(b) Starting a new message by voice in the car ("Hey Google, send a message
to Alex on Sennit"): prepared, needs a hand test.** Android Auto takes this
request for "any messaging app compatible with Android Auto", but Google does
not document how a third-party app is offered as a target or receives the
text. The open-source precedent is Signal: conversation shortcuts that are
long-lived, carry a `Person`, are pushed with `pushDynamicShortcut` and are
bound to `SEND_MESSAGE`. Sennit now publishes the same. Its top eight chats
(pinned first, then recency and how often the user writes to them; see
`ShareTargetRanker`) are bound to `SEND_MESSAGE`, and every chat that posts a
notification is bound to both `SEND_MESSAGE` and `RECEIVE_MESSAGE`.
`core-google-shortcuts` hands those pushes to Google's surfaces. Whether
Gemini in Android Auto then offers Sennit for an arbitrary contact is Google's
decision. Expect a contact who wrote recently to work first. Reports exist of
Assistant refusing new messages for some apps ("I can't send messages with
Telegram yet") while replies worked.

**(c) On the phone, without a car: replies need a hand test, new messages are
implemented.** "Hey Google, send a message to Alex on Sennit" on the phone goes
through the `CREATE_MESSAGE` App Action. The assistant opens
`weft://compose?recipient=Alex&text=…` and `WeftLink.parse` reads it as a
`ComposeMessageLink`. `resolveMessageRecipient` (in `weft_share`, the same
matching Siri uses) then picks the conversation, and it opens with the
dictated words in the composer, **unsent**, after anything already typed. An
App Action cannot ask "send it?", so the composer asks instead. When the name
fits several chats or none, the search opens on the name, the dictated words
go to the clipboard, and a snackbar says so. Whether Gemini on the phone still
dispatches App Actions is not stated anywhere current. Google documents the
intent without a deprecation, but some developers report that Gemini ignores
older Assistant shortcuts. If it does not dispatch them, the capability does
nothing and costs nothing. Voice replies to a notification on the phone work
wherever the phone's assistant replies to notifications at all. They use the
same reply action as the car.

### Which chats the assistant can name

- **Merged chats are one name.** A shortcut is a `Chat`, keyed by
  `shareTargetSlotId(chat.id)`, so Anna on WhatsApp and Signal is one Anna,
  and a reply goes through `ChatRepository.send` to her preferred leg, as from
  the composer. Matching is on the chat title, which for a DM is the person
  after the address book and the merge fold.
- **Groups are audiences**, bound with `message.recipient.@type = Audience` or
  `message.sender.@type = Audience`, so "message Anna" does not offer the
  family group.
- **Not addressable** (`isVoiceAddressable`): archived chats, and chat requests
  that are pending or declined. A request published as a shortcut would hand a
  stranger's name to the launcher and the assistant before the user had
  accepted, and answering one by voice would accept it unseen. This also
  removes such requests from Direct Share.

### Privacy

A conversation shortcut puts the chat's name and avatar into the launcher, the
share sheet and, through `core-google-shortcuts`, Google's on-device assistant.
It carries no message text. That is the same exposure Direct Share has always
had, and it matches the preview setting's reading: with previews off, the
notification still names the sender and only the body becomes "New message".
The car and the assistant read only what the notification says. Sign-out
removes every shortcut (`ShareShortcuts.clear`, `removeLongLivedShortcuts`),
and the compat library forwards the removal to Google's surfaces too.

### Play policy

No new permission, declaration or Data safety change. Nothing is collected,
and no data leaves the device beyond what the user's assistant already reads
from shortcuts. The Android Auto opt-in under **Play Console** above is still
what the car needs. The App Action needs no Play Console step.

### Testing it by hand

Unit and widget tests pin Sennit's side: the declarations
(`assistant_messaging_test.dart`), the compose link and composer prefill, the
name resolution (`packages/weft_share/test/recipient_test.dart`) and the
ranker's request filter. Google's assistant, the DHU and a signed-in Google
account are not available to CI. Check these by hand on a Play build, or on a
debug build with *Unknown sources* enabled in Android Auto's developer
settings:

1. **Shortcuts reach the system.** After signing in and getting a message:
   `adb shell dumpsys shortcut`, in the `com.bostrot.weft` package. Expect
   `chat_…` ids that are dynamic and long-lived, with the conversation
   category and a person.
2. **(a) in the car / DHU.** As in the DHU steps above: a message arrives, the
   head unit reads it, "Reply" takes a dictated answer, and it arrives in the
   room. Do it once with Gemini enabled as the phone's assistant.
3. **(b) in the car / DHU.** Press the voice button and say "Send a message to
   <a contact who wrote recently> on Sennit", then "… to <a pinned chat> on
   Sennit". Note what Gemini answers. If it says Sennit cannot send new
   messages, Google is not offering third-party targets, and nothing more can
   be done on Sennit's side.
4. **(c) on the phone.** "Hey Google, send a message to <exact chat name> on
   Sennit saying test": Sennit should open that chat with "test" in the
   composer. Then try an ambiguous name: search should open with a snackbar,
   and the text should be on the clipboard. To confirm the capability is
   registered when Gemini will not trigger it, start the link directly:
   `adb shell am start -a android.intent.action.VIEW -d 'weft://compose?recipient=Anna&text=hi' com.bostrot.weft`.

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
