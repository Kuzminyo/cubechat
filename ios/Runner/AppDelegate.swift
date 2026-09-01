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

  /// Held for the life of the app, like the others: it captures the platform
  /// thread's mach port in its initialiser and would hand that port back on
  /// deallocation, taking the Diagnostics CPU panel with it.
  private var cpuProbePlugin: CubechatCpuProbePlugin?
  private var pushPlugin: CubechatPushPlugin?

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

  /// Channel Dart asks build questions on. Must match `BuildProbe`.
  private static let buildInfoChannelName = "cubechat/build_info"

  /// Last four characters of the Maps key handed to the SDK — never the key.
  private var mapsKeyTail = "none"

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
      mapsKeyTail = String(mapsKey.suffix(4))
    } else {
      NSLog("cubechat: Google Maps API key is missing")
      mapsKeyTail = "missing"
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
    let watcher = SignificantLocationWatcher { [weak self] location in
      self?.runCatchUp(reason: "significant location change", location: location)
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
      cpuProbePlugin = CubechatCpuProbePlugin(messenger: messenger)
      pushPlugin = CubechatPushPlugin(messenger: messenger)
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

      // What this install actually *is*, asked from inside it.
      //
      // A Maps key restricted to an iOS app is checked against the bundle
      // identifier of the running app — and a sideloaded build does not
      // necessarily keep the one that was compiled in: the signing tools
      // rewrite it to fit the Apple ID doing the signing. The map then draws
      // its own markers over a grey sheet and reports nothing, which is
      // exactly what a tester spent an evening looking at. Four characters of
      // the key and the bundle id are what tell the two suspects apart.
      FlutterMethodChannel(
        name: AppDelegate.buildInfoChannelName,
        binaryMessenger: messenger
      ).setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "buildFacts":
          result([
            "mapsKeyTail": self?.mapsKeyTail ?? "unknown",
            "bundleId": Bundle.main.bundleIdentifier ?? "unknown",
          ])
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  // MARK: - APNs

  /// The token, handed straight to the plugin that asked for it.
  ///
  /// Nothing else here reads it. It is not stored natively and it is not sent
  /// anywhere from Swift: Dart signs it into a Nostr event with the identity
  /// key and posts that, because the key lives on the Dart side and is not
  /// going to be lifted out for this.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    pushPlugin?.didRegister(deviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pushPlugin?.didFailToRegister(error: error)
  }

  // MARK: - Catch-up after a wake-up

  /// Spend a wake-up the same way a scheduled background window is spent:
  /// hand it to Dart, which stands the relay transport up, drains whatever the
  /// relays are holding and raises the notifications.
  ///
  /// Held open with a background-task assertion because the ten seconds iOS
  /// grants a relaunched app is not enough to open a socket and finish a
  /// round trip, and dropped exactly once however it ends.
  ///
  /// [location] is the fix that came with the doorbell, when there was one. It
  /// travels to Dart because the alternative is Dart asking the platform where
  /// the phone is — and a cold fix in the background is radio time, which is
  /// the single most expensive thing this app does. Coarse by construction and
  /// carrying its own timestamp, so the far side can decline it.
  private func runCatchUp(reason: String, location: CLLocation?) {
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

    attemptCatchUp(
      remaining: AppDelegate.catchUpRetries,
      arguments: AppDelegate.wakeArguments(location),
      finish: finish
    )
  }

  /// The doorbell's own fix, in the shape Dart reads, or nil when there is
  /// nothing worth sending.
  ///
  /// A negative `horizontalAccuracy` is CoreLocation's way of saying the
  /// coordinate is invalid, and the timestamp is the location's own rather than
  /// now: a relaunch spends seconds booting Dart before anybody looks at this,
  /// and a fix has to be able to be judged stale on arrival.
  private static func wakeArguments(_ location: CLLocation?) -> [String: Any]? {
    guard let location, location.horizontalAccuracy >= 0 else { return nil }
    return [
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy,
      "at": Int(location.timestamp.timeIntervalSince1970 * 1000),
    ]
  }

  /// One try at reaching Dart, retried while the engine is still booting.
  ///
  /// A relaunch runs `main()` from scratch, so for the first second or two
  /// there is no handler on the refresh channel and the reply comes back as
  /// not-implemented. That is not a failure to report, it is "ask again".
  private func attemptCatchUp(
    remaining: Int,
    arguments: [String: Any]?,
    finish: @escaping () -> Void
  ) {
    guard remaining > 0 else {
      finish()
      return
    }
    guard let channel = refreshChannel else {
      // No engine yet. Same answer as no handler yet: wait and ask again.
      DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.catchUpRetryDelay) {
        [weak self] in
        self?.attemptCatchUp(
          remaining: remaining - 1,
          arguments: arguments,
          finish: finish
        )
      }
      return
    }
    channel.invokeMethod(AppDelegate.refreshMethod, arguments: arguments) { [weak self] reply in
      if (reply as? Bool) == true {
        finish()
        return
      }
      guard let self else {
        finish()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.catchUpRetryDelay) {
        self.attemptCatchUp(
          remaining: remaining - 1,
          arguments: arguments,
          finish: finish
        )
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
/// background. So it is mostly an excuse to run: the wake-up is spent draining
/// the relays, which is how a message that arrived hours ago finally raises its
/// notification.
///
/// The position it rings with is handed over rather than dropped. It is coarse
/// — the same half-kilometre that decided the phone had moved — but it is a
/// position the baseband already had, so republishing the live-map pin from it
/// costs nothing, where asking CoreLocation for a fresh fix in the background
/// costs the one thing an Android battery report named as this app's largest
/// single expense. The far side judges it and can decline; see
/// `IosBackgroundRefresh.fixFromWake`.
///
/// Costs almost nothing to leave on: no GPS is started, the data is what the
/// baseband already knows. Requires Always authorisation, and is armed only
/// once the user has granted it for the live map — nothing here asks for it.
final class SignificantLocationWatcher: NSObject, CLLocationManagerDelegate {
  /// Survives termination on purpose: after a relaunch there is no Dart yet to
  /// ask, and the manager has to be monitoring again before iOS will deliver
  /// the event that caused the relaunch.
  private static let armedKey = "cubechat.significantLocation.armed"

  /// The circle we sit inside, and leaving it is the event.
  ///
  /// Significant-change monitoring rings on a cell hand-off: roughly half a
  /// kilometre, often more. That is the difference between "left the house"
  /// and "left the district", and for a live map it is the difference between
  /// useful and silent — a phone at home never changes cell, so a closed app
  /// reports nothing for days. Region monitoring is the finer instrument iOS
  /// offers for the same job, and it relaunches a terminated app just as SLC
  /// does.
  ///
  /// One region, moved rather than accumulated: iOS allows twenty per app and
  /// a stale one left behind is a wake-up for a place the user is no longer
  /// near. Re-armed from positions we are given anyway — an SLC delivery, or
  /// the exit itself — so this starts no GPS of its own and costs what the
  /// doorbell already cost, which was close to nothing.
  private static let regionId = "cubechat.here"

  /// A hundred metres, and not less.
  ///
  /// Apple's own guidance puts the practical floor around this: smaller
  /// circles are honoured on paper and fire late, early, or repeatedly in
  /// practice, because the position that decides is the same coarse one the
  /// system already has. Small enough to catch leaving a building, large
  /// enough not to ring while somebody walks around inside it.
  private static let regionRadius: CLLocationDistance = 100

  private let manager = CLLocationManager()
  private let onWake: (CLLocation?) -> Void
  private var monitoring = false

  init(onWake: @escaping (CLLocation?) -> Void) {
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
    // The wish is recorded before the ability to grant it is checked, and that
    // ordering is the whole of this. It used to be the other way round, so a
    // phone on While-Using fell out at the guard below with the flag still
    // false — and `authorizationChanged` only re-arms when the flag is true.
    // Granting Always afterwards in Settings therefore armed nothing, and
    // Settings is exactly where people go: iOS shows the upgrade prompt at
    // most once, and anyone who dismissed it has no other route. The symptom
    // was a live-map pin that simply stopped updating once the app was closed,
    // with every switch in the app turned on and nothing to see anywhere.
    //
    // Nothing is monitoring yet. This says somebody asked for it, so a later
    // grant has something to act on; `monitoring` still says whether it is
    // actually running, and `stop()` clears the flag when the wish is
    // withdrawn.
    UserDefaults.standard.set(true, forKey: Self.armedKey)
    guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
      return false
    }
    // Never prompts. While-in-use gets no background delivery, so arming under
    // it would only cost a manager that can never fire.
    guard authorizedAlways else { return false }
    guard !monitoring else { return true }
    monitoring = true
    manager.startMonitoringSignificantLocationChanges()
    // From the position the system already holds, if it holds one. A cold
    // launch often has none; the first SLC delivery then arms it, and until
    // then the coarse doorbell is still ringing.
    armRegion(around: manager.location)
    NSLog("cubechat: significant location monitoring armed")
    return true
  }

  func stop() {
    UserDefaults.standard.set(false, forKey: Self.armedKey)
    guard monitoring else { return }
    monitoring = false
    manager.stopMonitoringSignificantLocationChanges()
    clearRegions()
  }

  /// Put the circle around where we are now, replacing the one before it.
  private func armRegion(around location: CLLocation?) {
    guard let location else { return }
    guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
      return
    }
    guard authorizedAlways else { return }

    clearRegions()
    let region = CLCircularRegion(
      center: location.coordinate,
      radius: Self.regionRadius,
      identifier: Self.regionId
    )
    // Only leaving matters. Entry would fire the moment the region is created,
    // since we are standing in the middle of it, and every wake-up costs the
    // relaunch it was meant to save.
    region.notifyOnEntry = false
    region.notifyOnExit = true
    manager.startMonitoring(for: region)
    NSLog("cubechat: watching a \(Int(Self.regionRadius)) m circle from here")
  }

  /// Ours only. Another framework's regions are not this class's to cancel.
  private func clearRegions() {
    for region in manager.monitoredRegions where region.identifier == Self.regionId {
      manager.stopMonitoring(for: region)
    }
  }

  /// Re-arm after a launch — including the launch this monitoring caused.
  func restoreIfArmed() {
    guard UserDefaults.standard.bool(forKey: Self.armedKey) else { return }
    start()
  }

  func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    // The newest of the batch. CoreLocation can deliver several at once after
    // a relaunch, and the pin wants the one that is true now, not the one that
    // rang the doorbell first.
    let newest = locations.last
    // The circle follows us. Without this it would stay where it was first
    // drawn, and the second time somebody left home nothing would ring.
    armRegion(around: newest)
    onWake(newest)
  }

  /// Left the circle — the fine-grained half of the doorbell.
  ///
  /// `manager.location` rather than a fresh fix: it is the position the system
  /// used to decide we had left, already paid for. Asking for a new one here
  /// would start GPS in the background, which is the single largest thing this
  /// app can do to a battery and the reason the coarse doorbell hands its
  /// position over instead of requesting one.
  func locationManager(
    _ manager: CLLocationManager, didExitRegion region: CLRegion
  ) {
    guard region.identifier == Self.regionId else { return }
    NSLog("cubechat: left the watched circle")
    let here = manager.location
    // Re-armed first, so the next departure is covered even if the catch-up
    // below is cut short by the system reclaiming us.
    armRegion(around: here)
    onWake(here)
  }

  /// A region that could not be monitored is not a silent failure.
  func locationManager(
    _ manager: CLLocationManager,
    monitoringDidFailFor region: CLRegion?,
    withError error: Error
  ) {
    NSLog("cubechat: region monitoring failed: \(error.localizedDescription)")
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
      // Authorisation taken away in Settings takes the circle with it. A
      // region left monitored under While-Using never fires, and a watcher
      // that cannot ring should not look armed.
      clearRegions()
    }
  }
}
