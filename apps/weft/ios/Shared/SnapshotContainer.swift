import Foundation

/// Where the inbox snapshot lives inside the App Group, described once.
///
/// Four processes will read these paths and one writes them: the host app,
/// through `com.bostrot.weft/snapshot`; the WidgetKit extension, on every
/// timeline reload; the Lock Screen accessory, which is the same extension; and
/// the watchOS app. They are different processes with different bundle ids, and
/// `containerURL(forSecurityApplicationGroupIdentifier:)` hands each of them a
/// *different absolute path* for the same group — so anything spelled twice is a
/// pair that can drift into a snapshot the writer can see and a widget cannot.
///
/// **This file is intended to be a member of every one of those targets**, which
/// is why it imports `Foundation` and nothing else: an extension cannot link
/// Flutter, and a watch app cannot link most of what an iOS app can. It is the
/// same discipline `ShareContainer.swift` follows, and it deliberately borrows
/// that file's group identifier rather than restating it — a target that
/// includes this file must include `ShareContainer.swift` too, which costs
/// nothing (it is Foundation-only and was written to be shared) and removes the
/// one constant that must never be spelled two ways.
///
/// Every accessor is optional rather than throwing. A build signed without the
/// App Group entitlement — an unsigned CI build, a macOS target whose group has
/// not been prefixed with the team id yet — returns `nil` here, and that is a
/// state both sides survive: the app by reporting the write as refused, the
/// surfaces by drawing their "open Weft on your phone" state.
enum WeftSnapshotContainer {
  /// The App Group every companion surface shares with the host app.
  ///
  /// Deliberately the *same* group as the Share Extension's, and read from
  /// there rather than restated. One group, one entitlement to provision, one
  /// string that can be wrong.
  ///
  /// On macOS this identifier has to be spelled `<TeamID>.group.com.bostrot.weft`
  /// in the entitlements file — App Groups on macOS are team-prefixed and iOS's
  /// are not. That is a signing decision rather than a code one, so it is
  /// recorded in `docs/decisions/adr-002-ios-signing-handoff.md` and this
  /// returns `nil` until it is made.
  static var appGroupIdentifier: String { WeftShareContainer.appGroupIdentifier }

  /// Everything snapshot-related under one directory, so the share drain's
  /// sweep and this never have to know about each other's files.
  static let snapshotDirectoryName = "snapshot"

  /// The encoded `InboxSnapshot`, exactly as `SnapshotCodec` produced it.
  static let payloadFileName = "inbox.json"

  /// Whether the home screen widgets may render the payload.
  ///
  /// In the group's `UserDefaults` rather than in the payload, because it is
  /// not about the conversations: one file feeds the widgets and the watch, and
  /// these two keys are how someone who wants the watch and not the widget gets
  /// that. A default read is also the cheapest thing a widget's
  /// `TimelineProvider` can do before deciding whether to read the file at all.
  static let widgetsEnabledKey = "weft.snapshot.widgets"

  /// Whether the watch companions may.
  static let watchEnabledKey = "weft.snapshot.watch"

  /// The same ceiling `kMaxSnapshotBytes` enforces on the Dart side, checked
  /// again on this one.
  ///
  /// The reader is a WidgetKit extension under a memory limit low enough that
  /// decoding megabytes of JSON is how a widget stops being scheduled at all —
  /// so the refusal has to exist on the side that gets killed, not only on the
  /// side with memory to spare.
  static let maxPayloadBytes = 64 * 1024

  static func containerURL(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
  }

  static func snapshotURL(fileManager: FileManager = .default) -> URL? {
    containerURL(fileManager: fileManager)?.appendingPathComponent(
      snapshotDirectoryName, isDirectory: true)
  }

  static func payloadURL(fileManager: FileManager = .default) -> URL? {
    snapshotURL(fileManager: fileManager)?.appendingPathComponent(
      payloadFileName, isDirectory: false)
  }

  /// The group's shared defaults, or `nil` without the entitlement.
  static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  /// Whether the home screen widgets may draw.
  ///
  /// False unless stored — fail-closed, the same way every gate above this is.
  /// A widget woken before the app has ever written draws its own empty state
  /// rather than assuming consent it cannot check.
  static var widgetsEnabled: Bool {
    defaults?.bool(forKey: widgetsEnabledKey) ?? false
  }

  /// Whether the watch companions may. Same fail-closed default.
  static var watchEnabled: Bool {
    defaults?.bool(forKey: watchEnabledKey) ?? false
  }

  /// The stored payload, or `nil` when there is none to read.
  ///
  /// Size-checked before it is read into memory rather than after: the point of
  /// the cap is not to reject a large string, it is not to allocate one.
  static func readPayload(fileManager: FileManager = .default) -> String? {
    guard let url = payloadURL(fileManager: fileManager) else { return nil }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxPayloadBytes else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Stores `json` and the two surface flags.
  ///
  /// Written atomically, because the reader is a process the system schedules
  /// on its own: `SnapshotCodec.decode` survives a half-written file — it is
  /// documented to — but not needing to is better than tolerating it.
  ///
  /// `completeUntilFirstUserAuthentication` rather than `complete`, and that is
  /// the whole reason this file protection is spelled out. A widget renders on
  /// a *locked* screen; a file protected as `complete` is unreadable there, so
  /// the Lock Screen accessory — the surface whose entire job is to show an
  /// unread count on a locked phone — would render nothing. The same class the
  /// share targets file uses, for a weaker version of the same reason.
  @discardableResult
  static func writePayload(
    _ json: String, widgets: Bool, watch: Bool, fileManager: FileManager = .default
  ) -> Bool {
    guard json.utf8.count <= maxPayloadBytes,
      let url = payloadURL(fileManager: fileManager),
      let directory = snapshotURL(fileManager: fileManager),
      let data = json.data(using: .utf8)
    else { return false }

    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: nil)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      return false
    }

    // After the payload, never before. A surface that woke between the two
    // writes would find the flag saying it may draw and the file still holding
    // the previous snapshot, which is the one ordering that shows stale content
    // to someone who has just changed their mind about showing any.
    let store = defaults
    store?.set(widgets, forKey: widgetsEnabledKey)
    store?.set(watch, forKey: watchEnabledKey)
    return true
  }

  /// Deletes the payload and both flags.
  ///
  /// Deliberately not the same as writing a switched-off payload. An absent
  /// file is how a surface tells "nobody is signed in" — where the honest thing
  /// to draw is a prompt to open Weft — from "signed in and switched off in
  /// Settings", where the honest thing is to say so. See `InboxSnapshot` for
  /// the three states.
  ///
  /// Flags first here, inverting the write's order and for the same reason: at
  /// no point may a surface see permission to draw beside content it should no
  /// longer have.
  static func clear(fileManager: FileManager = .default) {
    let store = defaults
    store?.removeObject(forKey: widgetsEnabledKey)
    store?.removeObject(forKey: watchEnabledKey)
    if let url = payloadURL(fileManager: fileManager) {
      try? fileManager.removeItem(at: url)
    }
  }
}
