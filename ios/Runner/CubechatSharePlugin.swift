import Flutter
import UIKit

/// The app's half of "Share → CubeChat" on iPhone.
///
/// The share extension (ios/ShareExtension) leaves each share as a batch in
/// the App Group container: the files and a `manifest.json` written last. This
/// moves every finished batch into the app's own temporary directory — the
/// container is shared with another process and is not where the app's files
/// should live — and hands the result to Dart over the same channel Android
/// uses, `cubechat/share`, with the same two calls: `takeShared` for the files
/// and `takeSharedText` for a link or text. Dart then shows the picker.
///
/// Checked whenever the app becomes active, so a share is picked up whether
/// the extension managed to open the app or the person opened it themselves.
final class CubechatSharePlugin: NSObject {
  private static let group = "group.app.cubechat"
  private static let inboxName = "share-inbox"

  private let channel: FlutterMethodChannel
  private var files: [[String: String]] = []
  private var text: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cubechat/share", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "takeShared":
        _ = self.drain()
        result(self.files.isEmpty ? nil : self.files)
        self.files = []
      case "takeSharedText":
        _ = self.drain()
        result(self.text)
        self.text = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(becameActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func becameActive() {
    if drain() {
      channel.invokeMethod("shared", arguments: nil)
    }
  }

  /// Move every finished batch out of the container. True if anything came.
  private func drain() -> Bool {
    let fm = FileManager.default
    guard
      let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.group)
    else { return false }
    let inbox = container.appendingPathComponent(Self.inboxName, isDirectory: true)
    guard
      let batches = try? fm.contentsOfDirectory(
        at: inbox, includingPropertiesForKeys: nil)
    else { return false }
    let landing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("shared", isDirectory: true)
    try? fm.createDirectory(at: landing, withIntermediateDirectories: true)

    var found = false
    for batch in batches {
      let manifestURL = batch.appendingPathComponent("manifest.json")
      // No manifest yet: the extension is still writing this one.
      guard
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      for entry in manifest["files"] as? [[String: String]] ?? [] {
        guard let relative = entry["path"] else { continue }
        let source = batch.appendingPathComponent(relative)
        let target = landing.appendingPathComponent(
          "\(UUID().uuidString)-\(source.lastPathComponent)")
        guard (try? fm.moveItem(at: source, to: target)) != nil else { continue }
        files.append([
          "path": target.path,
          "name": entry["name"] ?? source.lastPathComponent,
          "mime": entry["mime"] ?? "application/octet-stream",
        ])
        found = true
      }
      if let shared = manifest["text"] as? String, !shared.isEmpty {
        text = text.map { "\($0)\n\(shared)" } ?? shared
        found = true
      }
      try? fm.removeItem(at: batch)
    }
    return found
  }
}
