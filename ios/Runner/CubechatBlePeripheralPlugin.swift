import CoreBluetooth
import Flutter
import Foundation

/// Peripheral-role BLE plugin for cubechat.
///
/// Mirrors the Android implementation: advertises the cubechat service UUID
/// and hosts three characteristics (inbound notify, outbound write, peer info read).
/// Talks to Dart over the `cubechat/ble_peripheral` MethodChannel and the
/// `cubechat/ble_peripheral/events` EventChannel.
final class CubechatBlePeripheralPlugin: NSObject {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?

  private var manager: CBPeripheralManager?
  private var service: CBMutableService?
  private var inboundChar: CBMutableCharacteristic?
  private var outboundChar: CBMutableCharacteristic?
  private var peerInfoChar: CBMutableCharacteristic?

  private var serviceUuid: CBUUID?
  private var inboundUuid: CBUUID?
  private var outboundUuid: CBUUID?
  private var peerInfoUuid: CBUUID?

  private var peerName: String = ""
  private var pubkeyFingerprint: String?
  private var protocolVersion: Int = 1

  private var subscribers = Set<UUID>()
  private var running = false
  private var pendingStart = false

  /// Outbound notify backpressure. `updateValue` returns false when CoreBluetooth's
  /// transmit queue is full; frames wait here and drain from
  /// `peripheralManagerIsReadyToUpdateSubscribers`. Without this, a media burst
  /// filled the system queue and the whole transfer aborted (see the
  /// "notify failed on image chunk N" field bug).
  private var notifyQueue: [Data] = []
  private let maxNotifyQueue = 4096

  init(messenger: FlutterBinaryMessenger) {
    self.methodChannel = FlutterMethodChannel(
      name: "cubechat/ble_peripheral", binaryMessenger: messenger)
    self.eventChannel = FlutterEventChannel(
      name: "cubechat/ble_peripheral/events", binaryMessenger: messenger)
    super.init()
    self.methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.eventChannel.setStreamHandler(self)
  }

  // MARK: - Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // CoreBluetooth peripheral is available on all iOS devices since iOS 6,
      // but the simulator doesn't actually deliver advertisements. We can't
      // detect simulator reliably here; report true and let the user discover
      // the limitation on simulator runs.
      result(true)

    case "start":
      guard let args = call.arguments as? [String: Any],
        let svc = args["serviceUuid"] as? String,
        let inb = args["inboundCharUuid"] as? String,
        let outb = args["outboundCharUuid"] as? String,
        let info = args["peerInfoCharUuid"] as? String
      else {
        result(FlutterError(code: "ARG", message: "bad args", details: nil))
        return
      }
      self.serviceUuid = CBUUID(string: svc)
      self.inboundUuid = CBUUID(string: inb)
      self.outboundUuid = CBUUID(string: outb)
      self.peerInfoUuid = CBUUID(string: info)
      self.peerName = (args["peerName"] as? String) ?? ""
      self.pubkeyFingerprint = args["pubkeyFingerprint"] as? String
      self.protocolVersion = (args["protocolVersion"] as? Int) ?? 1
      result(startPeripheral())

    case "stop":
      stopPeripheral()
      result(nil)

    case "notifyInbound":
      guard let args = call.arguments as? [String: Any],
        let data = (args["data"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterError(code: "ARG", message: "missing data", details: nil))
        return
      }
      result(notifyInbound(data))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Lifecycle

  private func startPeripheral() -> Bool {
    if running { return true }
    if manager == nil {
      manager = CBPeripheralManager(delegate: self, queue: nil)
    }
    if manager?.state == .poweredOn {
      configureAndStart()
    } else {
      pendingStart = true
    }
    return true
  }

  private func stopPeripheral() {
    running = false
    pendingStart = false
    manager?.stopAdvertising()
    if let s = service {
      manager?.remove(s)
    }
    service = nil
    inboundChar = nil
    outboundChar = nil
    peerInfoChar = nil
    subscribers.removeAll()
    notifyQueue.removeAll()
  }

  private func configureAndStart() {
    guard let mgr = manager,
      let svcUuid = serviceUuid,
      let inUuid = inboundUuid,
      let outUuid = outboundUuid,
      let infoUuid = peerInfoUuid
    else { return }

    let inb = CBMutableCharacteristic(
      type: inUuid,
      properties: [.notify],
      value: nil,
      permissions: [.readable])

    let outb = CBMutableCharacteristic(
      type: outUuid,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable])

    let info = CBMutableCharacteristic(
      type: infoUuid,
      properties: [.read],
      value: encodePeerInfo(),
      permissions: [.readable])

    let svc = CBMutableService(type: svcUuid, primary: true)
    svc.characteristics = [inb, outb, info]
    mgr.add(svc)

    self.service = svc
    self.inboundChar = inb
    self.outboundChar = outb
    self.peerInfoChar = info

    var advertData: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [svcUuid]
    ]
    if !peerName.isEmpty {
      advertData[CBAdvertisementDataLocalNameKey] = peerName
    }
    mgr.startAdvertising(advertData)
    running = true
    pendingStart = false
    emit(["type": "advertising", "ok": true])
  }

  /// Enqueue a frame for notify and kick the drain. Returns true when the frame
  /// was accepted into our queue (there is at least one subscriber and a live
  /// characteristic) — a full CoreBluetooth transmit queue is handled by the
  /// drain + `peripheralManagerIsReadyToUpdateSubscribers`, not surfaced as a
  /// failure to Dart.
  private func notifyInbound(_ data: Data) -> Bool {
    guard manager != nil, inboundChar != nil, !subscribers.isEmpty else {
      return false
    }
    if notifyQueue.count >= maxNotifyQueue {
      // Sustained overrun — drop the oldest so we bound memory. The reassembler
      // on the far side times the partial transfer out.
      notifyQueue.removeFirst()
    }
    notifyQueue.append(data)
    drainNotifyQueue()
    return true
  }

  /// Feed the queue into CoreBluetooth until `updateValue` reports the transmit
  /// queue is full, then stop — the ready callback resumes us.
  private func drainNotifyQueue() {
    guard let mgr = manager, let ch = inboundChar else { return }
    while let head = notifyQueue.first {
      if mgr.updateValue(head, for: ch, onSubscribedCentrals: nil) {
        notifyQueue.removeFirst()
      } else {
        break
      }
    }
  }

  private func encodePeerInfo() -> Data {
    // version(1) | flags(1) | name | 0x00 | fingerprint
    let nameBytes = peerName.data(using: .utf8) ?? Data()
    let fpBytes = (pubkeyFingerprint ?? "").data(using: .utf8) ?? Data()
    var buf = Data()
    buf.append(UInt8(protocolVersion))
    buf.append(fpBytes.isEmpty ? 0x00 : 0x01)
    buf.append(nameBytes)
    buf.append(0x00)
    buf.append(fpBytes)
    return buf
  }

  fileprivate func emit(_ payload: [String: Any?]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}

// MARK: - CBPeripheralManagerDelegate

extension CubechatBlePeripheralPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      if pendingStart { configureAndStart() }
    case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
      emit([
        "type": "advertising", "ok": false, "errorCode": peripheral.state.rawValue,
      ])
      stopPeripheral()
    @unknown default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error = error {
      emit(["type": "advertising", "ok": false, "errorMessage": error.localizedDescription])
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      emit(["type": "advertising", "ok": false, "errorMessage": error.localizedDescription])
      running = false
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    subscribers.insert(central.identifier)
    emit(["type": "connected", "centralId": central.identifier.uuidString])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    subscribers.remove(central.identifier)
    emit(["type": "disconnected", "centralId": central.identifier.uuidString])
  }

  /// CoreBluetooth's transmit queue has room again — resume draining.
  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    drainNotifyQueue()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == peerInfoUuid else {
      peripheral.respond(to: request, withResult: .requestNotSupported); return
    }
    let payload = encodePeerInfo()
    if request.offset >= payload.count {
      peripheral.respond(to: request, withResult: .invalidOffset); return
    }
    request.value = payload.subdata(in: request.offset..<payload.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for r in requests {
      guard r.characteristic.uuid == outboundUuid, let data = r.value else { continue }
      emit([
        "type": "write",
        "centralId": r.central.identifier.uuidString,
        "charUuid": r.characteristic.uuid.uuidString,
        "data": FlutterStandardTypedData(bytes: data),
      ])
    }
    if let first = requests.first {
      peripheral.respond(to: first, withResult: .success)
    }
  }
}

// MARK: - EventChannel.StreamHandler

extension CubechatBlePeripheralPlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
