import Flutter
import UIKit

/// Hands a file to another app and *switches to it*.
///
/// iOS has two ways to give a file away and they behave nothing alike. The
/// share sheet (`UIActivityViewController`, which is what share_plus presents)
/// runs the chosen app's share extension — a small window belonging to that app
/// drawn on top of ours, which never leaves cubechat. The other is this one:
/// `UIDocumentInteractionController`'s "Open in…" menu copies the file into the
/// target app's inbox and launches it, so the phone actually changes apps.
/// Nothing about the first can be configured into the second; they are separate
/// mechanisms, which is why this exists at all.
///
/// Returns false rather than an error when no installed app claims the file's
/// type — the menu would come up empty, so the Dart side falls back to the
/// share sheet instead of leaving a tap that does nothing.
final class CubechatOpenInPlugin: NSObject, UIDocumentInteractionControllerDelegate {
  private let channel: FlutterMethodChannel

  /// Held for as long as the menu is up. `UIDocumentInteractionController` is
  /// not retained by the presentation, so a local would be deallocated on the
  /// way out of `handle` and the menu would vanish with it.
  private var interaction: UIDocumentInteractionController?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cubechat/open_in",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "openIn" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      FileManager.default.fileExists(atPath: path),
      let view = Self.topViewController()?.view
    else {
      result(false)
      return
    }

    let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    controller.delegate = self
    if let uti = args["uti"] as? String, !uti.isEmpty {
      controller.uti = uti
    }
    interaction = controller

    // Same anchor rule as the share sheet: UIKit presents this as a popover and
    // rejects an empty or off-screen source rect outright. The Dart side
    // measures the control that was tapped (see `shareAnchorFor`); this only
    // clamps it back inside the view it is being presented from, since a rect
    // measured a frame ago can have scrolled away.
    let anchor = Self.rect(from: args["anchor"], within: view.bounds)
    let presented = controller.presentOpenInMenu(from: anchor, in: view, animated: true)
    if !presented {
      interaction = nil
    }
    result(presented)
  }

  private static func rect(from raw: Any?, within bounds: CGRect) -> CGRect {
    guard
      let a = raw as? [String: Any],
      let x = (a["x"] as? NSNumber)?.doubleValue,
      let y = (a["y"] as? NSNumber)?.doubleValue,
      let w = (a["width"] as? NSNumber)?.doubleValue,
      let h = (a["height"] as? NSNumber)?.doubleValue,
      w > 0, h > 0
    else {
      return CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
    }
    let candidate = CGRect(x: x, y: y, width: w, height: h)
    return bounds.contains(candidate)
      ? candidate
      : CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
  }

  // MARK: - UIDocumentInteractionControllerDelegate

  func documentInteractionControllerDidDismissOpenInMenu(
    _ controller: UIDocumentInteractionController
  ) {
    interaction = nil
  }

  func documentInteractionController(
    _ controller: UIDocumentInteractionController,
    didEndSendingToApplication application: String?
  ) {
    interaction = nil
  }

  // MARK: - View controller lookup

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let root =
      scenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    return root.map(top(of:))
  }

  private static func top(of controller: UIViewController) -> UIViewController {
    if let presented = controller.presentedViewController {
      return top(of: presented)
    }
    if let nav = controller as? UINavigationController,
      let visible = nav.visibleViewController
    {
      return top(of: visible)
    }
    return controller
  }
}
