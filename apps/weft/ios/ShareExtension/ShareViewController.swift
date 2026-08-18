import UIKit

#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers
#endif

/// Weft's iOS Share Extension: the whole of what Weft can do with a share while
/// it is not running.
///
/// ## Why this cannot send anything
///
/// A Share Extension is a separate process. It has its own container, its own
/// memory ceiling — a few tens of megabytes, well under what decrypting a room
/// costs — and, crucially, no Matrix session: the session lives in the host
/// app's keychain and its sync loop in the host app's process, and there is no
/// supported way to run a second one here without two clients racing on the same
/// Olm ratchet state. The same argument the notification service extension makes
/// for not decrypting applies here with less nuance, because sending needs
/// strictly more than reading does.
///
/// So this class does exactly three things and refuses the fourth:
///
/// 1. copies the shared items into the App Group container, streaming, never
///    holding a file in memory;
/// 2. optionally asks which conversation, from a list the host app wrote there
///    earlier;
/// 3. writes one `StagedShare` JSON blob beside the files and completes.
///
/// The host app drains it on next launch or resume and sends from there. That
/// is `staged_share_reader.dart` on the other side, and
/// `ShareStagingCodec` in `packages/weft_share` is the contract between them —
/// **written by hand on this side**, with no compiler checking the key names, so
/// every key below is spelled against that class's `toJson` and nothing else.
///
/// ## The failure modes this is written around
///
/// The system can kill an extension at any instant, including between two
/// writes. Two orderings do the work:
///
/// * **Files first, blob last.** A share whose blob exists is a share whose
///   files are already copied. The reverse — a blob naming files that were never
///   written — is the one shape the reader cannot tell from a valid share, so it
///   is made unreachable rather than handled.
/// * **The blob is written atomically**, which makes a truncated blob
///   impossible on this path. `ShareStagingCodec.decode` tolerates truncation
///   anyway and that tolerance is tested exhaustively; it is not weakened by
///   this, it is simply not the case that is left to it. What is left to it is
///   the kill *between* the two steps, which shows up as an orphaned `<id>/`
///   directory with no blob — swept by the drain, invisible to the decoder.
final class ShareViewController: UIViewController {
  // MARK: - Limits

  /// Mirrors `kMaxSharedFileBytes` in `apps/weft/lib/app/intents.dart`.
  ///
  /// Enforced here as well as there, not instead of there: refusing a 2 GB
  /// video *after* copying it into the container means spending the copy, the
  /// disk and the user's wait on something the app will drop on ingestion. This
  /// is the same cap read one step earlier.
  private static let maxFileBytes = 100 * 1024 * 1024

  /// How many rows of conversations the picker offers.
  ///
  /// Matches `kMaxShareTargetSlots` in `weft_share`, which is what the host app
  /// writes; the clamp is here so a target file from a newer build cannot make
  /// this list scroll forever.
  private static let maxTargetRows = 8

  // MARK: - State

  /// Chosen up front so the files directory can be named before anything is
  /// copied into it, and so the blob and its directory agree without a second
  /// source of truth.
  private let shareId = UUID().uuidString

  private var targets: [ShareTarget] = []
  private var capture: CapturedShare?
  private var selection: Selection?
  private var isFinishing = false

  /// An alert raised before the view was on screen, held until it can be shown.
  ///
  /// The container check happens in `viewDidLoad` because there is no point
  /// starting a copy that has nowhere to go, but `present(_:animated:)` from
  /// there lands on a view controller with no window and is dropped.
  private var pendingAlert: (title: String, message: String)?
  private var hasAppeared = false

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let spinner = UIActivityIndicatorView(style: .medium)

  /// What the user picked. Distinct from `String?` because "no chat" is a real
  /// choice — it stages with a null `targetChatId`, which the app reads as "ask
  /// me" — and is not the same as "has not chosen yet".
  private enum Selection {
    case askInApp
    case chat(String)

    var chatId: String? {
      switch self {
      case .askInApp: return nil
      case .chat(let id): return id
      }
    }
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    configureViews()

    guard WeftShareContainer.prepareStagedDirectory() != nil else {
      // No container. The build is signed without the App Group entitlement, or
      // the group does not exist on this profile. Nothing here can recover, and
      // completing quietly would look to the user like a share that vanished.
      presentUnavailable()
      return
    }

    let targetsData = WeftShareContainer.targetsURL().flatMap { try? Data(contentsOf: $0) }
    targets = ShareTarget.decodeAll(targetsData, limit: Self.maxTargetRows)
    tableView.reloadData()

    beginCapture()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    hasAppeared = true
    if let pendingAlert {
      self.pendingAlert = nil
      present(title: pendingAlert.title, message: pendingAlert.message)
    }
  }

  // MARK: - Capture

  /// Copies every attachment into the container, off the main thread.
  ///
  /// Started before the user has chosen anything: the copy is the slow part —
  /// a video off the camera roll is hundreds of megabytes — and the choice is
  /// the part the user is doing meanwhile. By the time a row is tapped this has
  /// usually finished, and when it has not, `finishIfReady` waits.
  private func beginCapture() {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = items.flatMap { $0.attachments ?? [] }

    // Some hosts put the caption on the *item* rather than in a provider — a
    // share from Safari's "Share Page With…", a note attached to a photo. It is
    // only a fallback: when a provider gave us text, that text is the share, and
    // this is usually a duplicate of it or of the file's own name.
    let itemText = items
      .compactMap { $0.attributedContentText?.string }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    guard let directory = WeftShareContainer.filesURL(shareId: shareId) else {
      presentUnavailable()
      return
    }

    ShareCapturer(directory: directory, maxFileBytes: Self.maxFileBytes)
      .capture(providers: providers) { [weak self] captured in
        guard let self else { return }
        self.capture = captured.withFallbackText(itemText.isEmpty ? nil : itemText)
        self.finishIfReady()
      }
  }

  // MARK: - Completing

  private func choose(_ selection: Selection) {
    guard !isFinishing else { return }
    self.selection = selection
    // The copy may still be running. Lock the list so a second tap cannot pick
    // a different chat while the first one is waiting on it.
    tableView.isUserInteractionEnabled = false
    spinner.startAnimating()
    finishIfReady()
  }

  /// Writes the blob and completes, once both a choice and a finished copy
  /// exist. Called from each of them; whichever arrives second does the work.
  private func finishIfReady() {
    guard !isFinishing, let selection, let capture else { return }

    guard !capture.isEmpty else {
      // Everything was refused — over the cap, or a provider that gave us
      // nothing loadable. Staging this would open a compose sheet with nothing
      // in it on next launch.
      isFinishing = true
      cleanUp()
      presentEmpty(oversizeCount: capture.oversizeCount)
      return
    }

    isFinishing = true
    guard writeBlob(capture: capture, chatId: selection.chatId) else {
      cleanUp()
      presentUnavailable()
      return
    }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// Serialises the share against `ShareStagingCodec`'s key names.
  private func writeBlob(capture: CapturedShare, chatId: String?) -> Bool {
    guard let blobURL = WeftShareContainer.blobURL(shareId: shareId) else { return false }

    var blob: [String: Any] = [
      // `kStagedShareFormatVersion`. Carried for diagnosis; the reader does not
      // gate on it, because the extension ships inside the app bundle and a
      // reader older than its writer cannot exist.
      "version": 1,
      "id": shareId,
      "capturedAt": Self.timestampFormatter.string(from: Date()),
      "files": capture.files.map { file in
        [
          "path": file.relativePath,
          "name": file.name,
          "mimeType": file.mimeType,
          "sizeBytes": file.sizeBytes,
        ] as [String: Any]
      },
    ]
    if let text = capture.text, !text.isEmpty { blob["text"] = text }
    // `ShareTargetSlot.chatId`, not `ShareTargetSlot.id`: the sanitised
    // shortcut id is lossy and only Android has a map back from it.
    if let chatId { blob["targetChatId"] = chatId }

    guard JSONSerialization.isValidJSONObject(blob),
      let data = try? JSONSerialization.data(withJSONObject: blob)
    else { return false }

    do {
      try data.write(
        to: blobURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      return false
    }
    return true
  }

  private func cancel() {
    guard !isFinishing else { return }
    isFinishing = true
    cleanUp()
    extensionContext?.cancelRequest(
      withError: NSError(domain: "com.bostrot.weft.ShareExtension", code: 0, userInfo: nil))
  }

  /// Removes whatever this run copied. Called on every path that does not stage
  /// a blob — the container is shared with the app and is not scratch space.
  private func cleanUp() {
    WeftShareContainer.removeStagedShare(shareId: shareId)
  }

  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    // `withInternetDateTime` alone, so the string is the `2026-08-18T09:41:00Z`
    // form `DateTime.tryParse` reads without ambiguity. Fractional seconds add
    // nothing a capture timestamp is judged on and are a second thing to get
    // wrong across two languages.
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  // MARK: - Views

  private func configureViews() {
    view.backgroundColor = .systemBackground

    let navigationBar = UINavigationBar()
    navigationBar.translatesAutoresizingMaskIntoConstraints = false
    let item = UINavigationItem(title: "Share to Weft")
    item.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    navigationBar.setItems([item], animated: false)
    view.addSubview(navigationBar)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ShareTargetCell.self, forCellReuseIdentifier: ShareTargetCell.identifier)
    view.addSubview(tableView)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    NSLayoutConstraint.activate([
      navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  @objc private func cancelTapped() {
    cancel()
  }

  private func presentUnavailable() {
    present(
      title: "Weft can’t take this share",
      message:
        "Weft’s shared storage isn’t available on this build. Open Weft and share from inside the app instead.")
  }

  private func presentEmpty(oversizeCount: Int) {
    present(
      title: oversizeCount > 0 ? "Too large to share" : "Nothing to share",
      message: oversizeCount > 0
        ? "Files over 100 MB can’t be sent from the share sheet. Open Weft and attach it from inside a conversation."
        : "Weft couldn’t read anything from this share.")
  }

  private func present(title: String, message: String) {
    spinner.stopAnimating()
    guard hasAppeared else {
      pendingAlert = (title, message)
      return
    }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "OK", style: .default) { [weak self] _ in
        self?.isFinishing = true
        self?.cleanUp()
        self?.extensionContext?.cancelRequest(
          withError: NSError(domain: "com.bostrot.weft.ShareExtension", code: 1, userInfo: nil))
      })
    present(alert, animated: true)
  }
}

// MARK: - Table

extension ShareViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { targets.isEmpty ? 1 : 2 }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : targets.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == 0 ? nil : "Recent"
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: ShareTargetCell.identifier, for: indexPath)
    if indexPath.section == 0 {
      cell.textLabel?.text = "Choose in Weft…"
      cell.detailTextLabel?.text = nil
      cell.imageView?.image = nil
      cell.accessoryType = .disclosureIndicator
      return cell
    }
    let target = targets[indexPath.row]
    cell.textLabel?.text = target.longLabel
    cell.detailTextLabel?.text = target.networkSummary
    cell.imageView?.image = ShareTargetCell.initialsImage(for: target)
    cell.accessoryType = .none
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      choose(.askInApp)
    } else {
      choose(.chat(targets[indexPath.row].chatId))
    }
  }
}

// MARK: - Targets

/// One row of the picker, read out of the target list the host app writes.
///
/// A subset of `ShareTargetSlot`: `avatarUrl` is an unresolved `mxc://` URI and
/// an extension has no credentials to fetch it with, `link` is the app's
/// business, and `rank` is already expressed by the order it was written in.
struct ShareTarget {
  let chatId: String
  let longLabel: String
  let networks: [String]

  var networkSummary: String? {
    networks.isEmpty ? nil : networks.map(Self.displayName).joined(separator: " · ")
  }

  /// Wire ids from `ChatNetwork.id`, which are not all the obvious spelling —
  /// Messenger's is `facebook`.
  private static func displayName(_ id: String) -> String {
    switch id {
    case "matrix": return "Matrix"
    case "signal": return "Signal"
    case "whatsapp": return "WhatsApp"
    case "facebook": return "Messenger"
    case "telegram": return "Telegram"
    case "instagram": return "Instagram"
    case "discord": return "Discord"
    default: return id.prefix(1).uppercased() + id.dropFirst()
    }
  }

  /// Every readable target in `data`, capped at `limit`.
  ///
  /// Total, in the same way `ShareStagingCodec.decodeTargets` is and for a
  /// sharper reason: this runs inside a share sheet hosted by *another app's*
  /// process tree, and an unhandled error here is that app's share sheet
  /// disappearing. A missing or unreadable list means no rows, which is the
  /// same state as a user who has never opened Weft.
  static func decodeAll(_ data: Data?, limit: Int) -> [ShareTarget] {
    guard let data, !data.isEmpty else { return [] }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = root["targets"] as? [Any]
    else { return [] }

    var targets: [ShareTarget] = []
    for entry in raw {
      guard targets.count < limit else { break }
      guard let map = entry as? [String: Any],
        let chatId = map["chatId"] as? String, !chatId.isEmpty
      else { continue }
      let longLabel = (map["longLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (map["shortLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? "Chat"
      let networks = (map["networks"] as? [Any] ?? []).compactMap { $0 as? String }
      targets.append(ShareTarget(chatId: chatId, longLabel: longLabel, networks: networks))
    }
    return targets
  }
}

/// A subtitle cell, subclassed only so `detailTextLabel` exists.
///
/// `UITableViewCell` registered by class is built with `.default` style, whose
/// `detailTextLabel` is nil — the network line under a name would silently not
/// appear, which is the sort of thing that looks like a data bug for an hour.
final class ShareTargetCell: UITableViewCell {
  static let identifier = "target"

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// A generated initials circle, for the same reason `ShareShortcuts.initialsIcon`
  /// draws one on Android: the alternative is eight rows of identical grey
  /// placeholders. It is *not* the chat's avatar — resolving an `mxc://` URI
  /// needs an access token this process does not have — so the two surfaces
  /// differ, cosmetically and on purpose.
  static func initialsImage(for target: ShareTarget) -> UIImage {
    let size = CGSize(width: 36, height: 36)
    let initials = self.initials(for: target.longLabel)
    let colour = palette[abs(stableHash(target.chatId)) % palette.count]

    return UIGraphicsImageRenderer(size: size).image { context in
      colour.setFill()
      context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: UIColor.white,
      ]
      let bounds = initials.size(withAttributes: attributes)
      initials.draw(
        at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2),
        withAttributes: attributes)
    }
  }

  private static func initials(for title: String) -> String {
    let words = title.split(whereSeparator: { $0.isWhitespace }).prefix(2)
    let letters = words.compactMap { $0.first.map(String.init) }
    return letters.isEmpty ? "#" : letters.joined().uppercased()
  }

  /// `String.hashValue` is salted per process on Swift, so the same chat would
  /// draw a different colour on every launch. This one is not.
  private static func stableHash(_ value: String) -> Int {
    var hash = 5381
    for byte in value.utf8 { hash = (hash &* 33) &+ Int(byte) }
    return hash
  }

  private static let palette: [UIColor] = [
    UIColor(red: 0.36, green: 0.42, blue: 0.75, alpha: 1),
    UIColor(red: 0.20, green: 0.55, blue: 0.49, alpha: 1),
    UIColor(red: 0.72, green: 0.40, blue: 0.28, alpha: 1),
    UIColor(red: 0.53, green: 0.36, blue: 0.64, alpha: 1),
    UIColor(red: 0.29, green: 0.50, blue: 0.68, alpha: 1),
    UIColor(red: 0.66, green: 0.36, blue: 0.47, alpha: 1),
  ]
}

// MARK: - Capturing attachments

/// What one run of the extension managed to read.
struct CapturedShare {
  let text: String?
  let files: [CapturedFile]

  /// How many attachments were refused for being over the cap. Kept so the
  /// empty case can say *why* it is empty — "too large" and "unreadable" are
  /// different messages and only one of them has a next step.
  let oversizeCount: Int

  /// Matches `StagedShare.isEmpty`: nothing to send.
  var isEmpty: Bool { (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    && files.isEmpty }

  /// This share with `fallback` as its text, if it had none of its own.
  func withFallbackText(_ fallback: String?) -> CapturedShare {
    guard let fallback, !fallback.isEmpty,
      text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    else { return self }
    return CapturedShare(text: fallback, files: files, oversizeCount: oversizeCount)
  }
}

struct CapturedFile {
  let relativePath: String
  let name: String
  let mimeType: String
  let sizeBytes: Int
}

/// Turns the share sheet's `NSItemProvider` list into files in the container.
///
/// Split out of the view controller because it is the part with no UIKit in it
/// and all of the ordering rules: providers load concurrently and out of order,
/// and the result has to come back in the order the user's source app listed
/// them, or a screenshot and its caption arrive transposed.
struct ShareCapturer {
  let directory: URL
  let maxFileBytes: Int

  private enum Loaded {
    case text(String)
    case file(CapturedFile)
    case oversize
    case nothing
  }

  /// Uniform type identifiers, spelled rather than imported: `UTType` is iOS 14
  /// and the deployment target is 13.
  private enum UTI {
    static let fileURL = "public.file-url"
    static let url = "public.url"
    static let plainText = "public.plain-text"

    /// Tried in order for anything that is not a URL or a string. Ordered
    /// most-specific first so a JPEG is loaded as an image rather than as
    /// `public.data`, which some providers represent differently.
    static let fileTypes = [
      "public.image", "public.movie", "public.audio", "com.adobe.pdf", "public.content",
      "public.data", "public.item",
    ]
  }

  func capture(
    providers: [NSItemProvider], completion: @escaping (CapturedShare) -> Void
  ) {
    guard !providers.isEmpty else {
      completion(CapturedShare(text: nil, files: [], oversizeCount: 0))
      return
    }

    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: nil)

    // Results land on whatever queue each provider calls back on, so they are
    // collected under one serial queue and keyed by index rather than appended.
    let lock = DispatchQueue(label: "com.bostrot.weft.share.capture")
    var results: [Int: Loaded] = [:]
    let group = DispatchGroup()

    for (index, provider) in providers.enumerated() {
      group.enter()
      load(provider: provider, index: index) { loaded in
        lock.async {
          results[index] = loaded
          group.leave()
        }
      }
    }

    group.notify(queue: .main) {
      lock.sync {}  // drain the last append before reading
      var texts: [String] = []
      var files: [CapturedFile] = []
      var oversize = 0
      for index in 0..<providers.count {
        switch results[index] ?? .nothing {
        case .text(let text):
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { texts.append(trimmed) }
        case .file(let file):
          files.append(file)
        case .oversize:
          oversize += 1
        case .nothing:
          break
        }
      }
      completion(
        CapturedShare(
          text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
          files: files,
          oversizeCount: oversize))
    }
  }

  /// One provider, resolved by the first of four questions it answers yes to.
  ///
  /// The order is load-bearing. `public.file-url` conforms to `public.url`, and
  /// `public.plain-text` conforms to `public.data` — asking the general question
  /// first turns a shared file into its path as text, or a selected sentence
  /// into a file named `.txt`.
  private func load(
    provider: NSItemProvider, index: Int, completion: @escaping (Loaded) -> Void
  ) {
    if provider.hasItemConformingToTypeIdentifier(UTI.fileURL) {
      provider.loadItem(forTypeIdentifier: UTI.fileURL, options: nil) { item, _ in
        guard let url = Self.url(from: item), url.isFileURL else {
          completion(.nothing)
          return
        }
        completion(self.copy(url, index: index, suggestedName: provider.suggestedName))
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTI.url) {
      provider.loadItem(forTypeIdentifier: UTI.url, options: nil) { item, _ in
        guard let url = Self.url(from: item) else {
          completion(.nothing)
          return
        }
        // A web URL is text. Weft has no link-preview card to put it in, and a
        // room member reading `https://…` is reading what was shared.
        completion(
          url.isFileURL
            ? self.copy(url, index: index, suggestedName: provider.suggestedName)
            : .text(url.absoluteString))
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTI.plainText) {
      provider.loadItem(forTypeIdentifier: UTI.plainText, options: nil) { item, _ in
        if let text = item as? String {
          completion(.text(text))
        } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
          completion(.text(text))
        } else {
          completion(.nothing)
        }
      }
      return
    }

    guard
      let identifier = UTI.fileTypes.first(where: provider.hasItemConformingToTypeIdentifier)
    else {
      completion(.nothing)
      return
    }

    // `loadFileRepresentation` writes to a temporary file rather than handing
    // over `Data`. That is the difference between copying a 90 MB video and
    // being killed for holding it: the extension's memory ceiling is far below
    // what the files it is asked to carry can weigh.
    _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
      guard let url else {
        completion(.nothing)
        return
      }
      // The URL is only valid until this closure returns, so the copy is
      // synchronous here by necessity, not by preference.
      completion(self.copy(url, index: index, suggestedName: provider.suggestedName))
    }
  }

  private func copy(_ source: URL, index: Int, suggestedName: String?) -> Loaded {
    let fileManager = FileManager.default
    let declaredSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if declaredSize > maxFileBytes { return .oversize }

    let name = WeftShareContainer.sanitisedFileName(
      suggestedName ?? source.lastPathComponent, fallbackExtension: source.pathExtension)
    // Prefixed with the index so two attachments called `IMG_0001.HEIC` — a
    // multi-select from Photos routinely produces them — do not overwrite one
    // another, and so the container order matches the share order.
    let destination = directory.appendingPathComponent("\(index)-\(name)")

    try? fileManager.removeItem(at: destination)
    do {
      try fileManager.copyItem(at: source, to: destination)
      try? fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: destination.path)
    } catch {
      return .nothing
    }

    let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? declaredSize
    // Checked again: a provider that reported no size, or lied about it, is only
    // caught once the bytes are on disk. Cheaper to delete than to hand the app
    // a file it will refuse.
    if size > maxFileBytes {
      try? fileManager.removeItem(at: destination)
      return .oversize
    }

    guard let relativePath = WeftShareContainer.relativePath(of: destination) else {
      try? fileManager.removeItem(at: destination)
      return .nothing
    }

    return .file(
      CapturedFile(
        relativePath: relativePath,
        name: name,
        mimeType: Self.mimeType(forExtension: destination.pathExtension),
        sizeBytes: size))
  }

  private static func url(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
      return URL(string: string)
    }
    if let string = item as? String { return URL(string: string) }
    return nil
  }

  /// A *hint*. `StagedFile.mimeType` is documented as one and the host app
  /// re-sniffs from the bytes on ingestion, which is why the iOS 13 path can
  /// give up and say `application/octet-stream` without costing anything: the
  /// app's `sniffMimeType` is what actually decides, and it reads the header.
  private static func mimeType(forExtension pathExtension: String) -> String {
    guard !pathExtension.isEmpty else { return "application/octet-stream" }
    #if canImport(UniformTypeIdentifiers)
      if #available(iOS 14.0, *) {
        if let type = UTType(filenameExtension: pathExtension),
          let mime = type.preferredMIMEType
        {
          return mime
        }
      }
    #endif
    return "application/octet-stream"
  }
}
