import Flutter
import Foundation

/// The host app's end of the App Group container: `com.bostrot.weft/share`.
///
/// The Share Extension writes into that container and completes; nothing is sent
/// until Weft itself next runs. This is the draining side — `ShareViewController`
/// is the writing side and `WeftShareContainer` is the layout both agree on.
///
/// ## Why this is a channel of its own
///
/// Phase 03 and Phase 04 both decided that Android's shortcut calls belong on
/// the existing `com.bostrot.weft/intents` channel, because "a second channel
/// would be a second front door onto the same activity" — two publishers racing
/// on one shortcut set. None of that argument reaches here. `/intents` is
/// implemented by `MainActivity` and exists only on Android; there is no handler
/// for it in this process at all, and nothing on this channel touches state that
/// anything else writes. It is a different platform, a different file and a
/// disjoint set of methods, which is the case the earlier decision was
/// distinguishing itself *from*.
///
/// ## What crosses it
///
/// * `readStagedShares(ttlSeconds:)` — every blob in the container, with the id
///   its *filename* carries. The JSON is handed over unparsed: `ShareStagingCodec`
///   in `packages/weft_share` is the only decoder, it is total by construction
///   and it is exhaustively tested, and a second hand-written parse here would be
///   a second thing to keep in step with a format neither language checks.
/// * `ingestStagedShare(id:files:)` — takes a share out of the shared container
///   and puts its files in the app's own, returning where each one landed.
/// * `removeStagedShare(id:)` — drop one unread: expired, or unreadable.
/// * `writeShareTargets(json:)` — the opposite direction, the ranked list the
///   extension's picker reads.
///
/// Every method answers rather than throwing. This runs on the launch path, and
/// a `FlutterError` from a container that does not exist — an unsigned build, a
/// profile predating the App Group — would be an exception thrown into
/// `drain()` on every start.
enum WeftShareChannel {
  static let channelName = "com.bostrot.weft/share"

  /// Where an ingested share's files land, inside the app's own container.
  ///
  /// Caches rather than Documents, and named to match Android's
  /// `SHARE_CACHE_DIR` in `MainActivity.kt`: on both platforms a staged copy
  /// exists to be opened once per upload attempt and then forgotten, and both
  /// are swept on a day's TTL rather than deleted at send — an upload reads its
  /// file again on every retry.
  static let ingestDirectoryName = "weft-share"

  /// Largest blob worth reading into memory.
  ///
  /// A staged blob is a few hundred bytes and never more than a few kilobytes.
  /// Anything past this is not one, and `String(contentsOf:)` on a file that
  /// claims to be gigabytes is how a drain becomes a launch-time crash.
  private static let maxBlobBytes = 256 * 1024

  /// How many shares one drain will look at.
  ///
  /// Every share a drain reads is either ingested or removed, so this cannot
  /// starve — the next drain sees the next batch. It bounds the work a single
  /// launch does when a container has somehow accumulated hundreds.
  private static let maxSharesPerDrain = 16

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "readStagedShares":
      let ttl = TimeInterval(arguments["ttlSeconds"] as? Int ?? 86_400)
      background {
        let blobs = readStagedShares(ttl: ttl)
        DispatchQueue.main.async { result(blobs) }
      }

    case "ingestStagedShare":
      guard let id = arguments["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "id is required", details: nil))
        return
      }
      let files = arguments["files"] as? [[String: Any]] ?? []
      background {
        let paths = ingestStagedShare(id: id, files: files)
        DispatchQueue.main.async { result(paths) }
      }

    case "removeStagedShare":
      guard let id = arguments["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "id is required", details: nil))
        return
      }
      background {
        WeftShareContainer.removeStagedShare(shareId: id)
        DispatchQueue.main.async { result(nil) }
      }

    case "writeShareTargets":
      guard let json = arguments["json"] as? String else {
        result(FlutterError(code: "bad_args", message: "json is required", details: nil))
        return
      }
      background {
        let written = writeShareTargets(json: json)
        DispatchQueue.main.async { result(written) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Off the platform thread, because two of these move files.
  ///
  /// A same-volume move is a rename and returns immediately, but the fallback
  /// when it fails is a byte copy, and a 90 MB copy on the platform thread is a
  /// frozen first frame.
  private static func background(_ work: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
  }

  // MARK: - Reading

  /// Every staged blob, plus the id its filename carries.
  ///
  /// The id travels separately from the JSON on purpose: a blob that cannot be
  /// decoded still has to be *deleted*, and the id inside it is exactly the part
  /// that cannot be read. Without the filename's copy, one corrupt blob would be
  /// re-read on every launch forever.
  ///
  /// A `blob` of `nil` means the file could not be read — unreadable, or too
  /// large to be a staged share. Dart's decoder answers `nil` for that too, so
  /// it takes the same path: delete it.
  private static func readStagedShares(ttl: TimeInterval) -> [[String: Any]] {
    sweepIngestCache(ttl: ttl)
    sweepOrphanedFiles(ttl: ttl)

    var blobs: [[String: Any]] = []
    for url in WeftShareContainer.stagedBlobURLs() {
      guard blobs.count < maxSharesPerDrain else { break }
      let id = url.deletingPathExtension().lastPathComponent
      // A name this process would not have written is a name it must not build
      // a delete path from either.
      guard WeftShareContainer.isSafeIdentifier(id) else { continue }
      blobs.append(["id": id, "blob": readBlob(at: url) as Any])
    }
    return blobs
  }

  private static func readBlob(at url: URL) -> String? {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxBlobBytes else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - Ingesting

  /// Takes `id` out of the shared container and returns where its files landed.
  ///
  /// The answer maps each file's container-relative path — the string the blob
  /// carried, and the only name Dart knows it by — to an absolute path in the
  /// app's own cache. A file missing from the answer could not be moved, which
  /// the reader treats as one lost attachment rather than a lost share.
  ///
  /// **The blob is deleted before anything moves.** That ordering is what makes
  /// the drain idempotent: once this app has committed to ingesting a share, a
  /// second reader — a resume racing a launch, a kill halfway through — must not
  /// find it again and offer it twice. The files it moves are in the app's own
  /// cache either way, and a kill between the two steps leaves an orphaned
  /// `<id>/` directory that the next drain's sweep collects.
  private static func ingestStagedShare(id: String, files: [[String: Any]]) -> [String: String] {
    guard WeftShareContainer.isSafeIdentifier(id) else { return [:] }

    let fileManager = FileManager.default
    if let blob = WeftShareContainer.blobURL(shareId: id) {
      try? fileManager.removeItem(at: blob)
    }

    var moved: [String: String] = [:]
    if let destination = ingestDirectory(for: id) {
      for entry in files {
        guard let relativePath = entry["path"] as? String,
          let source = WeftShareContainer.absoluteURL(forRelativePath: relativePath)
        else { continue }
        let name = WeftShareContainer.sanitisedFileName(
          entry["name"] as? String, fallbackExtension: source.pathExtension)
        guard let target = move(source, into: destination, named: name) else { continue }
        moved[relativePath] = target.path
      }
    }

    // Whatever is left under `<id>/` failed to move and is unreachable now that
    // the blob naming it is gone.
    if let staged = WeftShareContainer.filesURL(shareId: id) {
      try? fileManager.removeItem(at: staged)
    }
    return moved
  }

  private static func ingestDirectory(for id: String) -> URL? {
    let fileManager = FileManager.default
    guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let directory =
      caches
      .appendingPathComponent(ingestDirectoryName, isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: nil)
    } catch {
      return nil
    }
    return directory
  }

  /// `source` moved into `directory` under `name`, or copied when it cannot be
  /// moved.
  ///
  /// A move, because both containers sit on the same volume and a rename costs
  /// nothing where a copy of a shared video costs its whole length twice. The
  /// copy is the fallback for the case that is not supposed to happen, so that a
  /// share is degraded rather than lost.
  private static func move(_ source: URL, into directory: URL, named name: String) -> URL? {
    let fileManager = FileManager.default
    var target = directory.appendingPathComponent(name, isDirectory: false)
    // The container prefixed every file with its index to keep a Photos
    // multi-select of two `IMG_0001.HEIC` apart; ingestion drops that prefix,
    // because the name is what the room sees. So the collision comes back here,
    // and is answered here.
    var attempt = 1
    while fileManager.fileExists(atPath: target.path) {
      let base = (name as NSString).deletingPathExtension
      let suffix = (name as NSString).pathExtension
      let candidate = suffix.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(suffix)"
      target = directory.appendingPathComponent(candidate, isDirectory: false)
      attempt += 1
      if attempt > 64 { return nil }
    }

    do {
      try fileManager.moveItem(at: source, to: target)
      return target
    } catch {
      guard (try? fileManager.copyItem(at: source, to: target)) != nil else { return nil }
      try? fileManager.removeItem(at: source)
      return target
    }
  }

  // MARK: - Sweeping

  /// Deletes ingested copies older than `ttl`.
  ///
  /// Mirrors `pruneStagedShares` in `MainActivity.kt`, for the same reason: an
  /// upload opens its file once per attempt, so deleting at send would break the
  /// retry the copy exists to make possible.
  private static func sweepIngestCache(ttl: TimeInterval) {
    let fileManager = FileManager.default
    guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return }
    let root = caches.appendingPathComponent(ingestDirectoryName, isDirectory: true)
    removeEntries(under: root, olderThan: ttl)
  }

  /// Deletes `<id>/` directories with no blob beside them.
  ///
  /// The extension copies files first and writes the blob last, so a share whose
  /// blob exists is a share whose files are already there. The reverse — a kill
  /// between the two steps — leaves bytes no blob names, invisible to the
  /// decoder and permanent without this. Only past the TTL, because a share
  /// being captured *right now*, while this app is being resumed in the
  /// background, looks exactly the same from here.
  private static func sweepOrphanedFiles(ttl: TimeInterval) {
    let fileManager = FileManager.default
    guard let staged = WeftShareContainer.stagedURL(),
      let entries = try? fileManager.contentsOfDirectory(
        at: staged, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    else { return }

    let cutoff = Date().addingTimeInterval(-ttl)
    for entry in entries {
      let isDirectory =
        (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      guard isDirectory else { continue }
      let blob = entry.appendingPathExtension(WeftShareContainer.blobExtension)
      guard !fileManager.fileExists(atPath: blob.path) else { continue }
      guard modificationDate(of: entry) < cutoff else { continue }
      try? fileManager.removeItem(at: entry)
    }
  }

  private static func removeEntries(under root: URL, olderThan ttl: TimeInterval) {
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsSubdirectoryDescendants])
    else { return }
    let cutoff = Date().addingTimeInterval(-ttl)
    for entry in entries where modificationDate(of: entry) < cutoff {
      try? fileManager.removeItem(at: entry)
    }
  }

  /// `.distantPast` for an entry with no date, so an unreadable one is swept
  /// rather than kept forever.
  private static func modificationDate(of url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  // MARK: - Targets

  /// Writes the ranked target list the extension's picker reads.
  ///
  /// Atomically, because the reader is a process inside another app's share
  /// sheet: `ShareTarget.decodeAll` survives a half-written file, but not
  /// needing to is better than tolerating it.
  private static func writeShareTargets(json: String) -> Bool {
    guard let url = WeftShareContainer.targetsURL(),
      let share = WeftShareContainer.shareURL(),
      let data = json.data(using: .utf8)
    else { return false }

    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: share, withIntermediateDirectories: true, attributes: nil)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      return false
    }
    return true
  }
}
