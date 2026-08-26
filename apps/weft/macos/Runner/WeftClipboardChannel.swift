import Cocoa
import FlutterMacOS

/// Reads images out of the system pasteboard.
///
/// Flutter's own `Clipboard` is text only — `Clipboard.getData` takes a format
/// and the only format it accepts is `text/plain`. So pressing ⌘V in a chat
/// with a screenshot on the pasteboard pasted nothing at all, which on a
/// desktop is the single most common way anyone sends a picture.
///
/// Two shapes come back, because the pasteboard holds two different things and
/// they want different handling:
///
///  * **File URLs** — what the Finder puts there when you copy a file. The
///    path is returned as-is, so the send path reads the original bytes and
///    keeps the original name rather than round-tripping a re-encoded copy.
///  * **Raw image data** — what a screenshot, a browser's "Copy Image" or
///    Preview puts there. Returned as bytes with an extension, and Dart spools
///    it to a temp file from there.
///
/// TIFF is normalised to PNG on the way out: it is what macOS leaves on the
/// pasteboard for almost everything, it is enormous, and no Matrix client on
/// the other end wants to receive one.
enum WeftClipboardChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.bostrot.weft/clipboard",
      binaryMessenger: registrar.messenger)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "readImages":
        result(readImages())
      case "hasImage":
        result(!readImages().isEmpty)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Every image on the pasteboard, richest representation first.
  private static func readImages() -> [[String: Any]] {
    let pasteboard = NSPasteboard.general

    // Files first: a path costs nothing to hand over and preserves the name,
    // the format and the exact bytes the user copied.
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      let images = urls.filter { isImage($0) }
      if !images.isEmpty {
        return images.map { ["path": $0.path, "name": $0.lastPathComponent] }
      }
    }

    // PNG as-is when it is there — re-encoding a PNG through NSBitmapImageRep
    // costs quality on nothing.
    if let png = pasteboard.data(forType: .png) {
      return [["bytes": FlutterStandardTypedData(bytes: png), "name": name("png")]]
    }

    if let tiff = pasteboard.data(forType: .tiff),
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    {
      return [["bytes": FlutterStandardTypedData(bytes: png), "name": name("png")]]
    }

    return []
  }

  private static func isImage(_ url: URL) -> Bool {
    let known = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"]
    return known.contains(url.pathExtension.lowercased())
  }

  /// A name with a timestamp in it, as every screenshot tool produces.
  ///
  /// The pasteboard carries no name for raw data, and "image.png" for every
  /// paste means a conversation full of files that cannot be told apart in a
  /// download folder.
  private static func name(_ ext: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "Pasted \(formatter.string(from: Date())).\(ext)"
  }
}
