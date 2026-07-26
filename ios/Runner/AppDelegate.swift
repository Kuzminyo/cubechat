import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var blePeripheralPlugin: CubechatBlePeripheralPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications, and the reason notifications
    // were invisible on iOS: without a UNUserNotificationCenter delegate the
    // system never calls willPresentNotification, so a notification raised
    // while the app is in the foreground is dropped instead of shown, and taps
    // don't route back into Dart. FlutterAppDelegate already conforms to the
    // protocol and forwards to the registered plugins.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Bridge our native peripheral plugin onto the engine's binary messenger.
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "CubechatBlePeripheralPlugin")?
      .messenger()
    {
      blePeripheralPlugin = CubechatBlePeripheralPlugin(messenger: messenger)
    }
  }
}
