import Flutter
import UIKit
import UserNotifications

/// The APNs half of the doorbell.
///
/// A terminated iOS app receives nothing — the socket died with the process,
/// and `BGAppRefreshTask` is not scheduled for an app the user swiped away.
/// APNs is the only mechanism Apple provides for "wake up, there is a message",
/// and it needs a device token, which only the system can hand out and only
/// after the user has agreed.
///
/// This plugin is the whole of the native side: ask, register, hand the token
/// to Dart. What happens to the token afterwards — signing it into a Nostr
/// event and posting it to the push service — is Dart's, because that is where
/// the identity key lives and it is never going to leave.
///
/// Deliberately without a `UNUserNotificationCenterDelegate` of its own: the
/// notifications this app *shows* are local ones raised by
/// `flutter_local_notifications`, which owns that delegate. This only ever
/// deals in the token.
final class CubechatPushPlugin: NSObject {
  static let channelName = "cubechat/push"

  private let channel: FlutterMethodChannel

  /// A registration is in flight, and this is who is waiting for it.
  ///
  /// `registerForRemoteNotifications` answers through an app-delegate callback
  /// rather than a completion handler, so the result has to be parked
  /// somewhere. Cleared on the way out of both callbacks, and it is the reason
  /// a second call while one is pending is refused rather than queued: two
  /// results, one continuation.
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "status":
        self.status(result)
      case "register":
        self.register(result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// What the user has already decided, without asking them again.
  ///
  /// Asked on the settings screen so the switch can show the true state, and
  /// before registering so a build that has been denied does not put up a
  /// system prompt that iOS will not show a second time anyway.
  private func status(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let value: String
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        value = "granted"
      case .denied:
        value = "denied"
      case .notDetermined:
        value = "undecided"
      @unknown default:
        value = "undecided"
      }
      DispatchQueue.main.async { result(value) }
    }
  }

  /// Ask, then register, then hand back the token as lowercase hex.
  ///
  /// Hex rather than the raw bytes because that is the form APNs itself uses in
  /// its `/3/device/<token>` path, and the form the push service stores. There
  /// is nothing to gain from carrying it as anything else.
  private func register(_ result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(
        code: "busy",
        message: "a registration is already in flight",
        details: nil
      ))
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { [weak self] granted, error in
      guard let self else { return }
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(
            code: "authorization",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        guard granted else {
          // Not an error: a decision. The caller turns its switch back off.
          result(nil)
          return
        }
        self.pending = result
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  /// Called by the app delegate when APNs answers.
  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pending?(hex)
    pending = nil
  }

  /// And when it does not. Common enough to be worth a real message: a
  /// simulator has no APNs at all, and a build signed without the Push
  /// Notifications entitlement is refused with "no valid aps-environment".
  func didFailToRegister(error: Error) {
    pending?(FlutterError(
      code: "apns",
      message: error.localizedDescription,
      details: nil
    ))
    pending = nil
  }
}
