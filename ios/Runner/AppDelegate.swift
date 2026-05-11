import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var blePeripheralPlugin: CubechatBlePeripheralPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
