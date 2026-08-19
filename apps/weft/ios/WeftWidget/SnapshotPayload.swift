import Foundation

/// Swift's reader for the payload `SnapshotCodec` writes.
///
/// The Dart side (`packages/weft_snapshot/lib/src/codec.dart`) is the only
/// writer of this format and names this file while doing it: *"the key names are
/// a cross-language contract. `WeftWidget.swift` and the Glance provider parse
/// this JSON by hand with no Dart on their side of it, so renaming a key here is
/// a silent break there."* This is that hand-written parser. Every key it reads
/// is spelled once, at the top, so the contract is greppable from this side too
/// — the same discipline `SnapshotFormat.kt` follows on Android, and the two
/// files are deliberately readable side by side.
///
/// ## Why `JSONSerialization` and not `Codable`
///
/// `Codable` is the shorter spelling and it is the wrong one here. A synthesised
/// `init(from:)` throws on the first field whose type does not match, which
/// turns "one row arrived with a string where an int should be" into "the widget
/// has no payload at all". This parser is required to be *total*: it degrades
/// per field and skips per row, because fifteen conversations and one unreadable
/// row is a widget, and no widget is not. `JSONSerialization` hands back
/// `Any` and lets every read make that decision for itself.
///
/// ## There is no encoder here
///
/// A widget renders and a widget taps; it never writes the payload back. The
/// snapshot is regenerated from the inbox rather than edited, which is also why
/// the Dart codec carries no `extras` round-trip. Unknown keys are ignored for
/// the same reason: nothing is lost by ignoring them.
enum WeftSnapshotFormat {
  /// The version this reader understands. Mirrors `kSnapshotFormatVersion`.
  ///
  /// Load-bearing here, unlike `kStagedShareFormatVersion` on the share path: a
  /// widget extension is started and kept by the system on its own schedule and
  /// can be held across an app update, so a reader older than its writer is the
  /// ordinary case rather than the pathological one. See
  /// `WeftInboxSnapshot.isFutureVersion` for what is done about it, which is
  /// degrade rather than refuse.
  static let version = 1

  /// Mirrors `kSnapshotStaleAfter` (12 hours), in seconds.
  static let staleAfter: TimeInterval = 12 * 60 * 60

  /// Mirrors `kUnreadBadgeCap`, and it is the one number on this side that
  /// genuinely had to be restated.
  ///
  /// A row's badge arrives pre-formatted as `SnapshotRow.unreadLabel` precisely
  /// so this rule lives in Dart. `InboxSnapshot.totalUnread` does not: it is a
  /// count, not a label, because the Lock Screen accessory and the watch
  /// complication want the number. So the accessory is the one renderer that has
  /// to apply the cap itself — see `unreadLabel(_:)`. The same restatement, for
  /// the same reason, as `SnapshotFormat.UNREAD_BADGE_CAP` on Android.
  static let unreadBadgeCap = 99

  /// [count] as a badge reads it, capped the way `WeftUnreadBadge` caps it.
  static func unreadLabel(_ count: Int) -> String {
    count > unreadBadgeCap ? "\(unreadBadgeCap)+" : "\(max(count, 0))"
  }

  /// Mirrors `kRedactedRowTitle`, for a row that arrives without a title.
  ///
  /// The Dart side already substitutes this when
  /// `SnapshotPolicy.includeSenderNames` is off, so reaching this constant here
  /// means a malformed row rather than a redacted one. It is the same word
  /// either way: a row that renders as an empty line is worse than one that
  /// admits it has no name.
  static let redactedTitle = "Conversation"

  // MARK: - The wire contract

  // One constant per key so a rename on the Dart side shows up here as a diff
  // rather than as an empty widget.
  private static let keyVersion = "version"
  private static let keyGeneratedAt = "generatedAt"
  private static let keyEnabled = "enabled"
  private static let keyTotalUnread = "totalUnread"
  private static let keyPalette = "palette"
  private static let keyRows = "rows"

  private static let rowId = "id"
  private static let rowTitle = "title"
  private static let rowLink = "link"
  private static let rowUnread = "unread"
  private static let rowUnreadLabel = "unreadLabel"
  private static let rowNetworks = "networks"
  private static let rowMerged = "merged"
  private static let rowPreview = "preview"
  private static let rowSender = "sender"
  private static let rowTimestamp = "timestamp"

  // MARK: - Decoding

  /// `raw` as a snapshot, or nil when it is not a usable one.
  ///
  /// Refused, in every case without throwing: nil or blank input; anything past
  /// `WeftSnapshotContainer.maxPayloadBytes`, which is what a partially
  /// overwritten file looks like from here; anything `JSONSerialization`
  /// rejects, which is what a write killed partway through looks like; a root
  /// that is not a JSON object. Everything else degrades — see the field
  /// comments below.
  static func decode(_ raw: String?) -> WeftInboxSnapshot? {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    // The same two-step guard `SnapshotCodec.decode` uses, and for the same
    // reason: a UTF-16 code unit is never worth less than one UTF-8 byte, so a
    // string longer than the cap is over it whatever it contains, and the cheap
    // check avoids encoding a payload that is absurd rather than merely too big.
    guard raw.utf16.count <= WeftSnapshotContainer.maxPayloadBytes,
      let data = raw.data(using: .utf8),
      data.count <= WeftSnapshotContainer.maxPayloadBytes,
      let parsed = try? JSONSerialization.jsonObject(with: data),
      let root = parsed as? [String: Any]
    else { return nil }

    // Rows are skipped individually rather than taking the payload with them.
    let rows = (root[keyRows] as? [Any] ?? []).compactMap { decodeRow($0) }

    return WeftInboxSnapshot(
      // A missing version reads as ours rather than as zero — zero would be
      // indistinguishable from a build older than the format, which has never
      // existed.
      version: positiveInt(root[keyVersion]) ?? version,
      // A missing timestamp reads as the epoch, which makes the snapshot
      // maximally stale and sends the widget to its "open Weft on your phone"
      // state. That is the right answer for a payload that cannot say when it
      // was written.
      generatedAt: Date(timeIntervalSince1970: millis(root[keyGeneratedAt]) / 1000),
      // A missing flag reads as enabled, because the switched-off payload is the
      // one that states it.
      enabled: root[keyEnabled] as? Bool ?? true,
      // Falls back to the visible rows rather than to zero: a widget that says
      // "0 unread" while showing rows carrying unread counts is wrong in a way
      // the user reads as messages having been marked read.
      totalUnread: nonNegativeInt(root[keyTotalUnread])
        ?? rows.reduce(0) { $0 + $1.unreadCount },
      palette: decodePalette(root[keyPalette]),
      rows: rows
    )
  }

  private static func decodeRow(_ raw: Any) -> WeftSnapshotRow? {
    guard let raw = raw as? [String: Any] else { return nil }
    // Usable means it has an id: without one the row cannot be tapped, and a row
    // that renders but does nothing is worse than a row that is not there. The
    // link is what a tap actually uses, so a row missing *that* is dropped too —
    // unlike Dart's `SnapshotRow.fromJson`, which can call `chatDeepLink` to
    // rebuild it. This side deliberately cannot: the percent-encoding is
    // `chatDeepLink`'s to own, and a second Swift implementation of it is
    // exactly the "link that differs by one escape" that comment warns about.
    guard let id = nonEmpty(raw[rowId]), let link = nonEmpty(raw[rowLink]) else {
      return nil
    }
    // And it has to be a URL SwiftUI will actually route. `Link` and
    // `widgetURL` both take a `URL`; a row whose link does not parse would
    // render as a tap target that silently does nothing, which is the state this
    // whole file exists to avoid.
    guard let url = URL(string: link) else { return nil }

    let networks = (raw[rowNetworks] as? [Any] ?? []).compactMap { nonEmpty($0) }
    let unread = nonNegativeInt(raw[rowUnread]) ?? 0

    return WeftSnapshotRow(
      chatId: id,
      title: nonEmpty(raw[rowTitle]) ?? redactedTitle,
      link: url,
      unreadCount: unread,
      // Formatted in Dart (`SnapshotRow.unreadLabel`) so the `99+` cap is
      // written once rather than once per platform. The local fallback is for a
      // payload that predates the field, not a second rule.
      unreadLabel: nonEmpty(raw[rowUnreadLabel]) ?? "\(unread)",
      networks: networks,
      isMerged: raw[rowMerged] as? Bool ?? (networks.count > 1),
      preview: nonEmpty(raw[rowPreview]),
      senderName: nonEmpty(raw[rowSender]),
      timestamp: millis(raw[rowTimestamp]) > 0
        ? Date(timeIntervalSince1970: millis(raw[rowTimestamp]) / 1000)
        : nil
    )
  }

  /// `ChatNetwork.id` → `0xAARRGGBB`.
  ///
  /// Read through `NSNumber.int64Value` and narrowed explicitly. On Android the
  /// equivalent read is a genuine trap — an opaque brand colour has its alpha
  /// byte set, so `0xFF25D366` is 4 280 818 534, half a billion past
  /// `Int.MAX_VALUE`, and Kotlin's `optInt` silently returns the fallback. Swift
  /// is not exposed to that (`Int` is 64-bit on every platform this ships to),
  /// but the value is still carried as a `UInt32` rather than an `Int` from here
  /// on, because that is the width the colour actually is and it makes the byte
  /// shifts in `WeftWidgetTokens.color(fromARGB:)` total rather than
  /// conditionally trapping.
  private static func decodePalette(_ raw: Any?) -> [String: UInt32] {
    guard let raw = raw as? [String: Any] else { return [:] }
    var palette: [String: UInt32] = [:]
    for (key, value) in raw {
      guard let number = value as? NSNumber else { continue }
      let wide = number.int64Value
      guard wide >= 0, wide <= Int64(UInt32.max) else { continue }
      palette[key] = UInt32(wide)
    }
    return palette
  }

  // MARK: - Tolerant field reads

  private static func nonEmpty(_ raw: Any?) -> String? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    return value
  }

  private static func positiveInt(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber, number.intValue > 0 else { return nil }
    return number.intValue
  }

  private static func nonNegativeInt(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber, number.intValue >= 0 else { return nil }
    return number.intValue
  }

  /// Epoch milliseconds, or 0 when the field is absent or unusable.
  ///
  /// `Double` rather than `Int` because a JSON number arrives as an `NSNumber`
  /// that may have been parsed as a double, and because the division to seconds
  /// wants one anyway. The ISO-8601 string form `parseSnapshotTimestamp` also
  /// accepts is deliberately *not* read here: Dart's writer emits the integer,
  /// that string form exists there for hand-written fixtures, and a date
  /// formatter in an extension is a cost with no caller.
  private static func millis(_ raw: Any?) -> Double {
    guard let number = raw as? NSNumber else { return 0 }
    return number.doubleValue
  }
}

/// One conversation, as a Home Screen or a Lock Screen is allowed to see it.
///
/// The Swift mirror of `SnapshotRow`. Everything here has already been through
/// `SnapshotPolicy` on the phone; there is no second filter on this side and
/// there cannot be one, because this process has no session, no database and no
/// way to ask.
struct WeftSnapshotRow: Identifiable, Hashable {
  /// `Chat.id` — a room id, or `merged:<contactId>`. Never re-derived from
  /// anything: the app has already answered "which conversation is this".
  let chatId: String

  /// What the row is labelled, or `WeftSnapshotFormat.redactedTitle` when the
  /// policy withheld it.
  let title: String

  /// `weft://chat/<encoded id>`, exactly as `chatDeepLink` produced it, parsed.
  ///
  /// A request, not a promise. A merged chat reverts to a plain room id when one
  /// of its legs is left, and this process may hold the payload for hours
  /// afterwards — so the link can name a conversation that no longer exists. It
  /// is handed to the existing deep-link path rather than to anything new
  /// precisely because that path already tolerates an id it cannot resolve.
  let link: URL

  let unreadCount: Int

  /// The badge text, capped at `99+` by the writer.
  let unreadLabel: String

  /// `ChatNetwork.id` strings, in the stable enum order Dart wrote them in, so
  /// the glyph strip renders the same way round on every refresh.
  let networks: [String]

  let isMerged: Bool
  let preview: String?
  let senderName: String?
  let timestamp: Date?

  /// `Identifiable` for `ForEach`, keyed on the conversation rather than on the
  /// position. A timeline entry is rebuilt on every inbox tick and rows move
  /// within it constantly; keyed by position, SwiftUI animates row three's title
  /// into whatever is third *now*.
  var id: String { chatId }

  /// `Grace: on my way`, or the preview alone when names are withheld.
  ///
  /// The sender is already disambiguated by network for a merged chat
  /// (`snapshotSenderName`), so nothing is added here beyond the separator.
  var previewLine: String? {
    guard let preview else { return nil }
    guard let senderName, !senderName.isEmpty else { return preview }
    return "\(senderName): \(preview)"
  }
}

/// The whole of what left the encrypted store for a companion surface.
struct WeftInboxSnapshot: Hashable {
  let version: Int
  let generatedAt: Date
  let enabled: Bool

  /// Unread across every conversation the policy allowed — *including* the ones
  /// past the row cap, which is why the accessory shows this rather than a sum
  /// over `rows`.
  let totalUnread: Int

  /// `ChatNetwork.id` → `0xAARRGGBB`, carried once per payload rather than
  /// re-tabled on this side. A stale copy here would render a newly added
  /// network in the fallback grey with nothing to say it had gone wrong.
  let palette: [String: UInt32]

  /// In the order the inbox gave them. **Not re-sorted**, on any side: a widget
  /// with a different top three than the app it companions is a bug the user
  /// reads as the app being wrong about their messages.
  let rows: [WeftSnapshotRow]

  /// True when the payload came from a build newer than this reader.
  ///
  /// Not an error and not a refusal. An unread count and a chat id mean the same
  /// thing in every version this format will ever have; refusing them would cost
  /// the user a working widget to protect them from a field that might be
  /// spelled differently.
  var isFutureVersion: Bool { version > WeftSnapshotFormat.version }

  /// When this payload stops being presentable as current.
  ///
  /// Exposed as a *moment* rather than as an `isStale(at:)` predicate, which is
  /// the one place this parts company with the Kotlin mirror. WidgetKit asks for
  /// a timeline rather than polling, so the provider can schedule an entry at
  /// exactly this instant and the widget flips to its "open Weft" state on the
  /// second rather than at the next hourly wake. See `WeftSnapshotProvider`.
  var staleAt: Date { generatedAt.addingTimeInterval(WeftSnapshotFormat.staleAfter) }

  func isStale(at now: Date) -> Bool { now > staleAt }
}
