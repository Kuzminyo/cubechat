import BackgroundTasks
import CoreLocation
import Flutter
import GoogleMaps
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var blePeripheralPlugin: CubechatBlePeripheralPlugin?
  private var audioTrimPlugin: CubechatAudioTrimPlugin?
  private var openInPlugin: CubechatOpenInPlugin?

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

  /// Channel the significant-location doorbell is armed over. Must match
  /// `IosSignificantLocation` on the Dart side.
  private static let locationChannelName = "cubechat/significant_location"

  private var locationChannel: FlutterMethodChannel?
  private var locationWatcher: SignificantLocationWatcher?

  /// How long to keep asking Dart to run the catch-up after a relaunch, and how
  /// often. A wake-up launches the process from nothing, so `main()` is still
  /// opening Hive when the location event lands and there is no handler on the
  /// channel yet — the first attempt is expected to miss.
  private static let catchUpRetries = 6
  private static let catchUpRetryDelay: TimeInterval = 1.5

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let mapsKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsApiKey") as? String,
       !mapsKey.isEmpty,
       !mapsKey.hasPrefix("$(") {
      GMSServices.provideAPIKey(mapsKey)
    } else {
      NSLog("cubechat: Google Maps API key is missing")
    }

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

    // After super, because that is what boots the engine and creates the
    // channels this talks over.
    //
    // Re-created on every launch, not only on a location one: CoreLocation
    // delivers a pending significant change to a *newly instantiated* manager,
    // so an app that only builds one when asked would be relaunched and then
    // sit there having thrown the event away. The watcher itself decides
    // whether monitoring is actually on, from what Dart last asked for.
    let watcher = SignificantLocationWatcher { [weak self] in
      self?.runCatchUp(reason: "significant location change")
    }
    locationWatcher = watcher
    watcher.restoreIfArmed()

    if launchOptions?[.location] != nil {
      // Launched *by* a location event. The event itself arrives in the
      // delegate a moment from now; this is only the log line that says the
      // doorbell is what woke us.
      NSLog("cubechat: relaunched by a significant location change")
    }

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
      openInPlugin = CubechatOpenInPlugin(messenger: messenger)
      refreshChannel = FlutterMethodChannel(
        name: AppDelegate.refreshChannelName,
        binaryMessenger: messenger
      )
      let location = FlutterMethodChannel(
        name: AppDelegate.locationChannelName,
        binaryMessenger: messenger
      )
      location.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "start":
          result(self?.locationWatcher?.start() ?? false)
        case "stop":
          self?.locationWatcher?.stop()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      locationChannel = location
    }
  }

  // MARK: - Catch-up after a wake-up

  /// Spend a wake-up the same way a scheduled background window is spent:
  /// hand it to Dart, which stands the relay transport up, drains whatever the
  /// relays are holding and raises the notifications.
  ///
  /// Held open with a background-task assertion because the ten seconds iOS
  /// grants a relaunched app is not enough to open a socket and finish a
  /// round trip, and dropped exactly once however it ends.
  private func runCatchUp(reason: String) {
    NSLog("cubechat: background catch-up (\(reason))")

    var taskId = UIBackgroundTaskIdentifier.invalid
    var finished = false
    let finish: () -> Void = {
      DispatchQueue.main.async {
        guard !finished else { return }
        finished = true
        if taskId != .invalid {
          UIApplication.shared.endBackgroundTask(taskId)
          taskId = .invalid
        }
      }
    }
    taskId = UIApplication.shared.beginBackgroundTask(withName: "cubechat.catchUp") {
      finish()
    }

    attemptCatchUp(remaining: AppDelegate.catchUpRetries, finish: finish)
  }

  /// One try at reaching Dart, retried while the engine is still booting.
  ///
  /// A relaunch runs `main()` from scratch, so for the first second or two
  /// there is no handler on the refresh channel and the reply comes back as
  /// not-implemented. That is not a failure to report, it is "ask again".
  private func attemptCatchUp(remaining: Int, finish: @escaping () -> Void) {
    guard remaining > 0 else {
      finish()
      return
    }
    guard let channel = refreshChannel else {
      // No engine yet. Same answer as no handler yet: wait and ask again.
      DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.catchUpRetryDelay) {
        [weak self] in
        self?.attemptCatchUp(remaining: remaining - 1, finish: finish)
      }
      return
    }
    channel.invokeMethod(AppDelegate.refreshMethod, arguments: nil) { [weak self] reply in
      if (reply as? Bool) == true {
        finish()
        return
      }
      guard let self else {
        finish()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.catchUpRetryDelay) {
        self.attemptCatchUp(remaining: remaining - 1, finish: finish)
      }
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

/// The one way a killed iOS app gets to run again without a push server.
///
/// Significant-change monitoring is a doorbell with the wrong bell: it rings
/// when the phone changes neighbourhood — a cell tower hand-off, roughly half a
/// kilometre, minutes apart — and never because a message arrived. What it does
/// do, and nothing else free does, is relaunch a *terminated* app into the
/// background. So it is used here purely as an excuse to run: the position is
/// thrown away, and the wake-up is spent draining the relays, which is how a
/// message that arrived hours ago finally raises its notification.
///
/// Costs almost nothing to leave on: no GPS is started, the data is what the
/// baseband already knows. Requires Always authorisation, and is armed only
/// once the user has granted it for the live map — nothing here asks for it.
final class SignificantLocationWatcher: NSObject, CLLocationManagerDelegate {
  /// Survives termination on purpose: after a relaunch there is no Dart yet to
  /// ask, and the manager has to be monitoring again before iOS will deliver
  /// the event that caused the relaunch.
  private static let armedKey = "cubechat.significantLocation.armed"

  private let manager = CLLocationManager()
  private let onWake: () -> Void
  private var monitoring = false

  init(onWake: @escaping () -> Void) {
    self.onWake = onWake
    super.init()
    manager.delegate = self
  }

  private var authorizedAlways: Bool {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    return status == .authorizedAlways
  }

  @discardableResult
  func start() -> Bool {
    guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
      return false
    }
    // Never prompts. While-in-use gets no background delivery, so arming under
    // it would only cost a manager that can never fire.
    guard authorizedAlways else { return false }
    UserDefaults.standard.set(true, forKey: Self.armedKey)
    guard !monitoring else { return true }
    monitoring = true
    manager.startMonitoringSignificantLocationChanges()
    NSLog("cubechat: significant location monitoring armed")
    return true
  }

  func stop() {
    UserDefaults.standard.set(false, forKey: Self.armedKey)
    guard monitoring else { return }
    monitoring = false
    manager.stopMonitoringSignificantLocationChanges()
  }

  /// Re-arm after a launch — including the launch this monitoring caused.
  func restoreIfArmed() {
    guard UserDefaults.standard.bool(forKey: Self.armedKey) else { return }
    start()
  }

  func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    // The position is deliberately unused. It is coarse by construction, and
    // the live map has its own, precise subscription for the times the app is
    // actually running.
    onWake()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("cubechat: significant location error: \(error.localizedDescription)")
  }

  /// Authorisation can be taken away in Settings while we are monitoring, and
  /// can arrive after the app decided it could not arm. Both spellings of the
  /// callback, because the deployment target is iOS 13 and the one-argument
  /// form only exists from 14.
  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationChanged()
  }

  func locationManager(
    _ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus
  ) {
    authorizationChanged()
  }

  private func authorizationChanged() {
    if authorizedAlways {
      if UserDefaults.standard.bool(forKey: Self.armedKey) { start() }
    } else if monitoring {
      monitoring = false
      manager.stopMonitoringSignificantLocationChanges()
    }
  }
}
