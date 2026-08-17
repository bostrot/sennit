import Foundation

/// The App Group container an iOS share passes through, described once.
///
/// Two processes read and write these paths: `ShareViewController` in the Share
/// Extension, which writes, and the `com.bostrot.weft/share` channel in the host
/// app, which drains. They are different processes with different bundle ids,
/// and `containerURL(forSecurityApplicationGroupIdentifier:)` hands each of them
/// a *different absolute path* for the same group. Anything spelled twice —
/// the group id, the directory names, the rule for turning an absolute URL into
/// the container-relative string `StagedFile.relativePath` carries — is a pair
/// that can drift into a share the writer can see and the reader cannot. So it
/// is spelled here once.
///
/// **This file is a member of both the `Runner` and `ShareExtension` targets.**
/// That is deliberate and is the reason it imports `Foundation` and nothing
/// else: an extension cannot link Flutter, and the host app must not need a
/// second copy of these constants to talk to it.
///
/// Every accessor is optional rather than throwing. A build signed without the
/// App Group entitlement — an unsigned CI build, a provisioning profile that
/// predates the capability — returns `nil` here, and that is a state both sides
/// have to survive: the extension by telling the user it cannot stage, the app
/// by draining nothing. It is not an error to crash on.
enum WeftShareContainer {
  /// The App Group both targets are entitled to.
  ///
  /// Must match `com.apple.security.application-groups` in
  /// `Runner/Runner.entitlements` and
  /// `ShareExtension/ShareExtension.entitlements`, and the group registered on
  /// the developer portal. See `docs/decisions/adr-002-ios-signing-handoff.md`.
  static let appGroupIdentifier = "group.com.bostrot.weft"

  /// Everything share-related lives under one directory so a drain that wants
  /// to clear the lot does not have to know the container's other tenants.
  static let shareDirectoryName = "share"

  /// Captured shares — one `<id>.json` blob and one `<id>/` directory of files
  /// per capture.
  static let stagedDirectoryName = "staged"

  /// The ranked target list, written by the host app and read by the
  /// extension's picker. Opposite direction to everything else here.
  static let targetsFileName = "targets.json"

  /// Extension of a staged blob, and the only thing that distinguishes it from
  /// the sibling directory holding its files.
  static let blobExtension = "json"

  static func containerURL(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
  }

  static func shareURL(fileManager: FileManager = .default) -> URL? {
    containerURL(fileManager: fileManager)?.appendingPathComponent(
      shareDirectoryName, isDirectory: true)
  }

  static func stagedURL(fileManager: FileManager = .default) -> URL? {
    shareURL(fileManager: fileManager)?.appendingPathComponent(
      stagedDirectoryName, isDirectory: true)
  }

  static func targetsURL(fileManager: FileManager = .default) -> URL? {
    shareURL(fileManager: fileManager)?.appendingPathComponent(
      targetsFileName, isDirectory: false)
  }

  /// The blob for `shareId`. Its files sit in `filesURL(shareId:)`, beside it.
  static func blobURL(shareId: String, fileManager: FileManager = .default) -> URL? {
    guard isSafeIdentifier(shareId) else { return nil }
    return stagedURL(fileManager: fileManager)?
      .appendingPathComponent(shareId, isDirectory: false)
      .appendingPathExtension(blobExtension)
  }

  /// The directory holding `shareId`'s copied files.
  static func filesURL(shareId: String, fileManager: FileManager = .default) -> URL? {
    guard isSafeIdentifier(shareId) else { return nil }
    return stagedURL(fileManager: fileManager)?
      .appendingPathComponent(shareId, isDirectory: true)
  }

  /// Creates `share/staged/`, returning it, or `nil` when there is no container.
  @discardableResult
  static func prepareStagedDirectory(fileManager: FileManager = .default) -> URL? {
    guard let staged = stagedURL(fileManager: fileManager) else { return nil }
    do {
      try fileManager.createDirectory(
        at: staged, withIntermediateDirectories: true, attributes: nil)
    } catch {
      return nil
    }
    return staged
  }

  /// Every staged blob, oldest name first.
  ///
  /// Sorted by path only to make the list deterministic; capture order is
  /// decided by `capturedAt` inside each blob, which is the field the Dart
  /// decoder sorts on. A filename cannot carry it — the id is a UUID.
  static func stagedBlobURLs(fileManager: FileManager = .default) -> [URL] {
    guard let staged = stagedURL(fileManager: fileManager) else { return [] }
    let contents = try? fileManager.contentsOfDirectory(
      at: staged,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    return (contents ?? [])
      .filter { $0.pathExtension == blobExtension }
      .sorted { $0.path < $1.path }
  }

  /// Deletes `shareId`'s blob and its file directory, ignoring what is already
  /// gone.
  ///
  /// Blob first: it is the record that the share exists at all, so a delete
  /// killed halfway leaves orphaned bytes rather than a share pointing at files
  /// that are no longer there.
  static func removeStagedShare(shareId: String, fileManager: FileManager = .default) {
    if let blob = blobURL(shareId: shareId, fileManager: fileManager) {
      try? fileManager.removeItem(at: blob)
    }
    if let files = filesURL(shareId: shareId, fileManager: fileManager) {
      try? fileManager.removeItem(at: files)
    }
  }

  /// `url` as the container-relative path a `StagedFile` carries, or `nil` when
  /// it is not inside the container.
  ///
  /// Both sides are resolved through `resolvingSymlinksInPath()` first: the
  /// container path is under `/var`, which is itself a symlink to `/private/var`
  /// on iOS, and `NSItemProvider` hands back URLs spelled either way.
  static func relativePath(of url: URL, fileManager: FileManager = .default) -> String? {
    guard let root = containerURL(fileManager: fileManager) else { return nil }
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return nil }
    var relative = String(filePath.dropFirst(rootPath.count))
    while relative.hasPrefix("/") { relative.removeFirst() }
    return relative.isEmpty ? nil : relative
  }

  /// The absolute URL for a path read out of a staged blob, or `nil` when the
  /// path is not one this container would have written.
  ///
  /// Refuses absolute paths and any `..` component. The only writer is our own
  /// extension, so this is not defending against an attacker so much as against
  /// a decoder that is documented to be tolerant of anything: `ShareStagingCodec`
  /// will hand back whatever string a `path` key contained, and the host app
  /// opens it on the launch path. Bounding it to the container is one line.
  static func absoluteURL(forRelativePath path: String, fileManager: FileManager = .default)
    -> URL?
  {
    guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
    let components = path.split(separator: "/")
    guard !components.contains("..") else { return nil }
    guard let root = containerURL(fileManager: fileManager) else { return nil }
    return components.reduce(root) { $0.appendingPathComponent(String($1)) }
  }

  /// Whether `id` is safe to spell as a path component.
  ///
  /// Staged ids are UUIDs generated by the extension, so this always passes for
  /// anything we wrote. It exists for the other direction: an id read back out
  /// of a blob is used to build the delete path, and `removeStagedShare` must
  /// not be talked into `..`.
  static func isSafeIdentifier(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else { return false }
    return id.allSatisfy { character in
      character.isASCII && (character.isLetter || character.isNumber || character == "-"
        || character == "_")
    }
  }
}
