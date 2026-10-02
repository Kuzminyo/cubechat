import UIKit
import UniformTypeIdentifiers

/// "Share → CubeChat" on iPhone.
///
/// An extension is a separate process with a tight memory limit and no
/// Flutter, so it does the least it can: copy what was shared into the App
/// Group container both it and the app can see, write a manifest beside it,
/// and ask iOS to open CubeChat. The app picks the batch up when it becomes
/// active (`CubechatSharePlugin`) and shows the same "send to" picker Android
/// does — chats and Saved.
///
/// If opening the app does not happen (iOS is strict about extensions
/// launching their host), nothing is lost: the batch waits in the container
/// and the picker comes up the next time CubeChat is opened.
final class ShareViewController: UIViewController {
  static let group = "group.app.cubechat"
  static let inboxName = "share-inbox"

  /// Android's limit for one share, kept the same here.
  private static let maxFiles = 50

  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    spinner.startAnimating()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task { @MainActor in
      await collect()
      openHost()
      // A beat for the open to be handed over before the extension goes.
      try? await Task.sleep(nanoseconds: 300_000_000)
      extensionContext?.completeRequest(returningItems: nil)
    }
  }

  // MARK: - Collecting

  private func collect() async {
    let fm = FileManager.default
    guard
      let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.group)
    else { return }
    let batch = container
      .appendingPathComponent(Self.inboxName, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try fm.createDirectory(at: batch, withIntermediateDirectories: true)
    } catch {
      return
    }

    var files: [[String: String]] = []
    var texts: [String] = []
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    for item in items {
      for provider in item.attachments ?? [] {
        if files.count >= Self.maxFiles { break }
        if let file = await Self.file(from: provider, into: batch, index: files.count) {
          files.append(file)
        } else if let text = await Self.text(from: provider) {
          texts.append(text)
        }
      }
    }

    if files.isEmpty && texts.isEmpty {
      try? fm.removeItem(at: batch)
      return
    }
    // The manifest last, and atomically: the app treats a batch without one
    // as still being written.
    var manifest: [String: Any] = ["files": files]
    let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { manifest["text"] = text }
    if let data = try? JSONSerialization.data(withJSONObject: manifest) {
      try? data.write(to: batch.appendingPathComponent("manifest.json"), options: .atomic)
    }
  }

  /// A picture, a video or any other file, copied into [batch]. Pictures are
  /// re-encoded as JPEG: an iPhone photo is HEIC, which the app's own encoder
  /// cannot read, and a JPEG is what every phone on the other end can show.
  private static func file(
    from provider: NSItemProvider,
    into batch: URL,
    index: Int
  ) async -> [String: String]? {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      if let data = await loadData(provider, type: UTType.image.identifier),
        let image = UIImage(data: data),
        let jpeg = image.jpegData(compressionQuality: 0.92)
      {
        let name = "photo-\(index + 1).jpg"
        let url = batch.appendingPathComponent("\(index)-\(name)")
        if (try? jpeg.write(to: url)) != nil {
          return ["path": url.lastPathComponent, "name": name, "mime": "image/jpeg"]
        }
      }
    }
    // A file the sharing app hands over as a file: a video, a PDF, anything.
    // Plain text and web links are not files here; they go as text.
    guard
      let type = provider.registeredTypeIdentifiers.first(where: { id in
        guard let ut = UTType(id) else { return false }
        return ut.conforms(to: .data) && !ut.conforms(to: .text) && !ut.conforms(to: .url)
      })
    else { return nil }
    return await withCheckedContinuation { continuation in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type) { source, _ in
        // The source only lives until this block returns: copy it now.
        guard let source else {
          continuation.resume(returning: nil)
          return
        }
        let name = source.lastPathComponent
        let url = batch.appendingPathComponent("\(index)-\(name)")
        do {
          try FileManager.default.copyItem(at: source, to: url)
        } catch {
          continuation.resume(returning: nil)
          return
        }
        let mime =
          UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
          ?? UTType(type)?.preferredMIMEType
          ?? "application/octet-stream"
        continuation.resume(returning: ["path": url.lastPathComponent, "name": name, "mime": mime])
      }
    }
  }

  /// A web link or plain text.
  private static func text(from provider: NSItemProvider) async -> String? {
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
      let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
      let url = item as? URL, !url.isFileURL
    {
      return url.absoluteString
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
      let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
    {
      if let string = item as? String { return string }
      if let data = item as? Data { return String(data: data, encoding: .utf8) }
    }
    return nil
  }

  private static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  // MARK: - Opening the app

  /// Extensions may not call `UIApplication.shared` or its `open`, but the
  /// application object is in this view controller's responder chain, and
  /// asking it to open our own scheme is how a share extension hands off to
  /// its app. The call goes through the Objective-C runtime because the target
  /// must be built with APPLICATION_EXTENSION_API_ONLY — Xcode refuses an
  /// extension without it ("Application extensions ... must be built with
  /// APPLICATION_EXTENSION_API_ONLY set to YES", the first CI run of 1138) —
  /// and that setting hides `open` from the compiler, not from the object.
  /// `cubechat://share` is not a link the app follows anywhere; arriving is
  /// the whole message.
  private func openHost() {
    guard let url = URL(string: "cubechat://share") else { return }
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
    var responder: UIResponder? = self
    while let current = responder {
      if current.responds(to: selector) {
        let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
        open(current, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = current.next
    }
  }
}
