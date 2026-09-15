import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit
import WebRTC

/// The iPhone's own incoming-call screen, and the push that can wake the app
/// to show it.
///
/// "Calls do not arrive on iOS when the app is fully closed" was the report. A
/// swiped-away iOS app runs nothing: no socket, no Dart, no ringtone. The only
/// thing that can start it for a call is a VoIP push through PushKit, and iOS
/// makes one condition of that absolute — the app must report a call to
/// CallKit before the push handler returns, every time, or the system kills it
/// and eventually stops delivering VoIP pushes to it at all. So the report
/// happens here, natively and first, before Dart has even started; Dart names
/// the caller a moment later when it has decrypted the invite.
///
/// CallKit is also what draws the screen that was asked for — the system's own,
/// over the lock screen, with Answer and Decline — and it owns the audio
/// session for the call. WebRTC is switched to manual audio for a CallKit call
/// and only starts when CallKit hands the session over in `didActivate`.
///
/// Dart to here, on `cubechat/callkit`: `voipToken`, `show`, `answered`,
/// `dismiss`, `takePending`. Here to Dart: `voipToken`, `answer`, `end`.
final class CubechatCallKit: NSObject {
  static let shared = CubechatCallKit()
  static let channelName = "cubechat/callkit"

  /// How long a call reported from a push may wait for Dart to say which call
  /// it is. The app has to launch, open its storage, reach a relay and decrypt
  /// the invite; past this, something is wrong and ringing on is a lie.
  private static let bindDeadline: TimeInterval = 25

  private let registry = PKPushRegistry(queue: .main)
  private let provider: CXProvider
  private let calls = CXCallController()
  private var channel: FlutterMethodChannel?

  private var voipToken: String?

  /// Dart's key for a call (its id in hex) to CallKit's UUID for it, and back.
  private var uuidByKey: [String: UUID] = [:]
  private var keyByUUID: [UUID: String] = [:]

  /// Reported from a push before Dart said which call it is.
  private var unbound: UUID?
  private var unboundDeadline: DispatchWorkItem?

  /// That call was already declined on CallKit's screen before Dart named it.
  /// Kept so the invite, when it arrives, is declined instead of ringing again.
  private var unboundEnded = false

  /// Answered through CallKit, so an answer from inside the app does not ask
  /// CallKit to answer the same call again.
  private var answered: Set<UUID> = []

  /// A button pressed before Dart could be told: before it bound the call, or
  /// before its handler existed.
  private var heldByUUID: [UUID: String] = [:]
  private var heldForDart: [[String: String]] = []

  private override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    // Not in the Phone app's recents. A call here is end-to-end encrypted and
    // nothing else about it is written anywhere the owner did not choose; a
    // system call log synced to iCloud would be the one place it leaked.
    configuration.includesCallsInRecents = false
    if let icon = UIImage(named: "CallKitIcon")?.pngData() {
      configuration.iconTemplateImageData = icon
    }
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: .main)
  }

  /// From `didFinishLaunching`, on every launch. PushKit delivers a pending
  /// VoIP push only to a registry that exists by the time launch finishes.
  func start() {
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "voipToken":
        result(self.voipToken)
      case "show":
        guard let key = args?["key"] as? String else {
          result(false)
          return
        }
        self.show(key: key, name: args?["name"] as? String ?? "", result: result)
      case "answered":
        if let key = args?["key"] as? String { self.answeredInApp(key: key) }
        result(nil)
      case "dismiss":
        self.dismiss(key: args?["key"] as? String)
        result(nil)
      case "takePending":
        let held = self.heldForDart
        self.heldForDart = []
        result(held)
      case "nearEar":
        // The screen off while the phone is at an ear during a call. iOS does
        // it for the Phone app and for CallKit's own screen; the app's call
        // screen has to ask. Dart decides when — see
        // `CallController._updateNearEar`.
        let watch = args?["watch"] as? Bool ?? false
        DispatchQueue.main.async {
          UIDevice.current.isProximityMonitoringEnabled = watch
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Dart asks

  private func show(key: String, name: String, result: @escaping FlutterResult) {
    let update = callUpdate(name: name)
    if let uuid = uuidByKey[key] {
      provider.reportCall(with: uuid, updated: update)
      result(true)
      return
    }
    if let uuid = unbound {
      // The push already rang for this call; now it has a name.
      let ended = unboundEnded
      unbound = nil
      unboundEnded = false
      unboundDeadline?.cancel()
      unboundDeadline = nil
      bind(uuid: uuid, key: key)
      let held = heldByUUID.removeValue(forKey: uuid)
      if ended {
        // Declined before it had a name: tell Dart, which tells the caller.
        deliver("end", key: key)
        forget(uuid: uuid)
        result(false)
        return
      }
      provider.reportCall(with: uuid, updated: update)
      if let held { deliver(held, key: key) }
      result(true)
      return
    }
    // The app was awake and heard the invite before any push: report it here,
    // which iOS allows a running app to do.
    let uuid = UUID()
    bind(uuid: uuid, key: key)
    setManualAudio(true)
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if let error {
        NSLog("cubechat: CallKit refused the call: \(error.localizedDescription)")
        self?.forget(uuid: uuid)
        result(false)
      } else {
        result(true)
      }
    }
  }

  /// Answered on the app's own screen. CallKit is told, so its screen moves on
  /// and it hands over the audio session like for any answered call.
  private func answeredInApp(key: String) {
    guard let uuid = uuidByKey[key], !answered.contains(uuid) else { return }
    answered.insert(uuid)
    calls.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
      if let error {
        NSLog("cubechat: CallKit answer request failed: \(error.localizedDescription)")
      }
    }
  }

  /// The call is over. A nil key ends whatever is showing.
  private func dismiss(key: String?) {
    let targets: [UUID]
    if let key {
      targets = uuidByKey[key].map { [$0] } ?? []
    } else {
      targets = Array(keyByUUID.keys) + (unbound.map { [$0] } ?? [])
    }
    for uuid in targets {
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      forget(uuid: uuid)
    }
  }

  // MARK: - Bookkeeping

  private func callUpdate(name: String) -> CXCallUpdate {
    let update = CXCallUpdate()
    let shown = name.isEmpty ? "Cubechat" : name
    update.remoteHandle = CXHandle(type: .generic, value: shown)
    update.localizedCallerName = shown
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  private func bind(uuid: UUID, key: String) {
    uuidByKey[key] = uuid
    keyByUUID[uuid] = key
  }

  private func forget(uuid: UUID) {
    if let key = keyByUUID.removeValue(forKey: uuid) {
      uuidByKey.removeValue(forKey: key)
    }
    if unbound == uuid {
      unbound = nil
      unboundEnded = false
      unboundDeadline?.cancel()
      unboundDeadline = nil
    }
    answered.remove(uuid)
    heldByUUID.removeValue(forKey: uuid)
    if keyByUUID.isEmpty && unbound == nil {
      setManualAudio(false)
    }
  }

  /// A button pressed on CallKit's screen, handed to Dart — or held until it
  /// can be.
  private func deliver(_ action: String, uuid: UUID) {
    guard let key = keyByUUID[uuid] else {
      heldByUUID[uuid] = action
      return
    }
    deliver(action, key: key)
  }

  private func deliver(_ action: String, key: String) {
    guard let channel else {
      heldForDart.append(["action": action, "key": key])
      return
    }
    channel.invokeMethod(action, arguments: ["key": key]) { [weak self] outcome in
      if (outcome as AnyObject) === FlutterMethodNotImplemented {
        self?.heldForDart.append(["action": action, "key": key])
      }
    }
  }

  // MARK: - WebRTC audio

  /// WebRTC must not start its own audio for a CallKit call: iOS activates the
  /// session for it and says so in `didActivate`. Off again once no CallKit
  /// call is left, so a call placed from the app starts its audio the way it
  /// always has.
  private func setManualAudio(_ on: Bool) {
    let session = RTCAudioSession.sharedInstance()
    session.useManualAudio = on
    session.isAudioEnabled = !on
  }

  // MARK: - Push

  private func reportFromPush(completion: @escaping () -> Void) {
    // A push for a call that is already showing — the app heard the invite over
    // a relay first — is still reported, because iOS counts the attempt; the
    // duplicate is refused and changes nothing on screen.
    if let existing = (unboundEnded ? nil : unbound) ?? keyByUUID.keys.first {
      provider.reportNewIncomingCall(with: existing, update: callUpdate(name: "")) { _ in
        completion()
      }
      return
    }
    let uuid = UUID()
    unbound = uuid
    unboundEnded = false
    setManualAudio(true)
    provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: "")) { [weak self] error in
      guard let self else {
        completion()
        return
      }
      if let error {
        NSLog("cubechat: CallKit refused a pushed call: \(error.localizedDescription)")
        self.forget(uuid: uuid)
      } else {
        let deadline = DispatchWorkItem { [weak self] in
          guard let self, self.unbound == uuid else { return }
          if !self.unboundEnded {
            NSLog("cubechat: no invite arrived for a pushed call; ending it")
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
          }
          self.forget(uuid: uuid)
        }
        self.unboundDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bindDeadline, execute: deadline)
      }
      completion()
    }
  }
}

// MARK: - PKPushRegistryDelegate

extension CubechatCallKit: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = hex
    channel?.invokeMethod("voipToken", arguments: hex)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    voipToken = nil
    channel?.invokeMethod("voipToken", arguments: nil)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    reportFromPush(completion: completion)
  }
}

// MARK: - CXProviderDelegate

extension CubechatCallKit: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    for uuid in Array(keyByUUID.keys) {
      if let key = keyByUUID[uuid] { deliver("end", key: key) }
      forget(uuid: uuid)
    }
    if let uuid = unbound { forget(uuid: uuid) }
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    let wasAnsweredInApp = answered.contains(action.callUUID)
    answered.insert(action.callUUID)
    if !wasAnsweredInApp { deliver("answer", uuid: action.callUUID) }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    deliver("end", uuid: action.callUUID)
    if keyByUUID[action.callUUID] != nil {
      forget(uuid: action.callUUID)
    } else if unbound == action.callUUID {
      // Declined before Dart knew which call it was: keep the word until the
      // invite arrives, so the caller is told rather than left ringing.
      unboundEnded = true
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidActivate(audioSession)
    session.isAudioEnabled = true
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidDeactivate(audioSession)
    session.isAudioEnabled = false
  }
}
