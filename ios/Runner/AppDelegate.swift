import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var blePeripheralPlugin: CubechatBlePeripheralPlugin?
  private var audioTrimPlugin: CubechatAudioTrimPlugin?

  /// Channel the background window is driven over. Must match
  /// `IosBackgroundRefresh` on the Dart side.
  private static let refreshChannelName = "cubechat/background_refresh"
  private static let refreshMethod = "runRefresh"

  /// BGTaskScheduler identifier. Must also appear in Info.plist under
  /// `BGTaskSchedulerPermittedIdentifiers`, or registration throws at launch.
  private static let refreshTaskId = "com.cubechat.relayRefresh"

  /// Earliest the system should consider running the task again. A floor, not a
  /// schedule: iOS decides the real cadence from how the user opens the app, and
  /// asking for less does not make it run more often.
  private static let refreshInterval: TimeInterval = 15 * 60

  /// Hard cap on the Dart window. iOS grants a BGAppRefreshTask roughly 30
  /// seconds and kills the app outright if the task overruns, so we always
  /// complete the task ourselves before then — even if Dart never answers.
  private static let refreshDeadline: TimeInterval = 25

  private var refreshChannel: FlutterMethodChannel?

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

    // Registration has to happen before launch finishes, per BGTaskScheduler's
    // contract — including on a cold launch that iOS performs purely to run the
    // task.
    registerRefreshTask()

    let started = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    scheduleRefresh()
    return started
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Bridge our native peripheral plugin onto the engine's binary messenger.
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "CubechatBlePeripheralPlugin")?
      .messenger()
    {
      blePeripheralPlugin = CubechatBlePeripheralPlugin(messenger: messenger)
      audioTrimPlugin = CubechatAudioTrimPlugin(messenger: messenger)
      refreshChannel = FlutterMethodChannel(
        name: AppDelegate.refreshChannelName,
        binaryMessenger: messenger
      )
    }
  }

  // MARK: - Background refresh

  /// Ask for another window whenever we leave the foreground. A submitted
  /// request is replaced, not queued, so re-submitting on every background is
  /// the documented way to keep exactly one pending.
  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    scheduleRefresh()
  }

  private func registerRefreshTask() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: AppDelegate.refreshTaskId,
      using: nil
    ) { [weak self] task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.handleRefresh(task: refresh)
    }
  }

  private func scheduleRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTaskId)
    request.earliestBeginDate = Date(timeIntervalSinceNow: AppDelegate.refreshInterval)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Simulator has no BGTaskScheduler, and the system refuses submissions
      // for an app the user has restricted. Neither is worth failing launch
      // over — we simply get no background windows.
      NSLog("cubechat: could not schedule background refresh: \(error)")
    }
  }

  private func handleRefresh(task: BGAppRefreshTask) {
    // Chain the next one immediately: a window that forgets to re-submit is the
    // last one the app ever gets.
    scheduleRefresh()

    // Completed exactly once, whichever of the three paths gets there first:
    // Dart answering, our own deadline, or iOS pulling the window early.
    var finished = false
    let finish: (Bool) -> Void = { success in
      DispatchQueue.main.async {
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
      }
    }

    task.expirationHandler = { finish(false) }

    guard let channel = refreshChannel else {
      // Engine not up yet (or no messenger) — nothing can be fetched.
      finish(false)
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.refreshDeadline) {
      finish(false)
    }
    channel.invokeMethod(AppDelegate.refreshMethod, arguments: nil) { result in
      finish(!(result is FlutterError))
    }
  }
}
