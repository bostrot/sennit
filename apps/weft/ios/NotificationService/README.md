# Weft notification service extension

`NotificationService.swift` and `Info.plist` here are a registered target in
`Runner.xcodeproj`. `flutter build ios` builds them and embeds the resulting
`NotificationService.appex` in `Runner.app`.

## This changed in Phase 04

Phase 03 authored these files and deliberately left them unregistered, on the
grounds that "an App Extension target cannot be added from a text editor in any
way that survives". Phase 04 needed a second extension — the Share Extension —
and tested that claim rather than inheriting it. It does not hold:

- `project.pbxproj` is an OpenStep property list with stable, author-chosen
  24-character object ids. Xcode reads hand-written ids and does not renumber
  them; nothing about the format is generated in a sense that resists editing.
  `plutil -lint` validates the result and `xcodebuild -list` reports the new
  targets.
- **Registration and signing are separable, and only the second was really
  missing.** Runner has been a registered, unsigned target in this repository
  since it was created — `DEVELOPMENT_TEAM` is unset and no profile is checked
  in. The extensions are registered on exactly the same terms.
- Leaving it unregistered had a cost Phase 03 could not see from where it stood:
  Phase 04 is asked to record whether the extension target *builds*, and a
  directory no target references answers that question with "not applicable"
  forever. Both extensions now build under `CODE_SIGNING_ALLOWED=NO`, which is a
  fact rather than a hope.

Both were registered together so the repository does not hold one wired and one
unwired extension — the condition Phase 04's read pass attached to overturning
this.

## What still needs Xcode, and what does not

Nothing needs Xcode. What needs *you* is signing material, which no repository
can hold:

1. A team selected on the Runner, ShareExtension and NotificationService targets.
2. Provisioning profiles for `com.bostrot.weft`,
   `com.bostrot.weft.ShareExtension` and `com.bostrot.weft.NotificationService`.
3. The App Group `group.com.bostrot.weft` created on the developer portal and
   enabled on Runner and ShareExtension.

This target deliberately has **no entitlements file**. It does not read the
Matrix store, so it does not need the group, and an unused entitlement is one
more App ID capability to keep in sync for no behaviour. Add one when — and only
when — the decryption work below starts.

`docs/decisions/adr-002-ios-signing-handoff.md` is the checklist.

## Pods

Still none, and still absent from the `Podfile` for that reason. When this
extension does need the Matrix SDK it wants its own
`target 'NotificationService' do … end` block, not Runner's pods — linking the
Flutter engine into an extension is how an extension gets killed for memory
before it has done anything. The Share Extension's block next to it is the shape
to copy, and `NotificationService.xcconfig` would then grow the same optional
CocoaPods include the Share Extension's two xcconfigs carry.

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
