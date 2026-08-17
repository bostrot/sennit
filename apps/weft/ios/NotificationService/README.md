# Weft notification service extension — not yet in the Xcode project

`NotificationService.swift` and `Info.plist` here are **authored but not built**.
Nothing in `Runner.xcodeproj` references them, so `flutter build ios` ignores
this directory entirely and the app builds exactly as it did before.

## Why it is not wired up

An App Extension target cannot be added from a text editor in any way that
survives: `project.pbxproj` is a generated file with UUID cross-references, and
the target also needs an App Group entitlement and a provisioning profile of its
own — signing material that is not in this repository and should not be.

## Adding it (Xcode, once)

1. **File → New → Target → Notification Service Extension.** Name it
   `NotificationService`, product bundle id
   `com.bostrot.weft.NotificationService`. Xcode creates its own
   `NotificationService.swift` and `Info.plist`.
2. **Replace both** with the files in this directory, or point the new target's
   build phases at these.
3. **Signing & Capabilities → App Groups** on *both* Runner and the extension.
   Use one group, e.g. `group.com.bostrot.weft`. Without it the extension has
   its own container and cannot reach the Matrix store.
4. Set the extension's **deployment target** to match Runner's.
5. Nothing to change in the Podfile until the extension needs the Matrix SDK —
   at which point it needs its own `target 'NotificationService' do … end`
   block, not Runner's pods.

## What it will and will not do

As written it improves the *shape* of the notification — thread identifier,
category, the event id carried through for the tap — and leaves the placeholder
text from `kIosDefaultPayload` in place. It does **not** decrypt.

Decryption from an extension is a real piece of work and the reasons are set out
in the file's own doc comment: a second vodozemac initialisation in a second
process, a database handle shared with a running app, and Olm ratchet state that
must not be advanced where the app cannot see it. Until that is solved, the
honest behaviour is the one implemented here — the app posts the real
notification when it next runs, and a vague notification beats a wrong one.
