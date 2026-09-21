import Flutter
import Speech

/// Turns a recorded voice note into text, on this phone.
///
/// `requiresOnDeviceRecognition` is set and never cleared. Without it Apple may
/// send the audio to its servers, and posting the decrypted contents of a
/// private message to anybody's API is the one thing this app exists not to
/// do. A locale with no local model is therefore a failure here rather than a
/// quiet trip over the network.
///
/// Failure paths return nil, the same way `CubechatAudioTrimPlugin` does — a
/// phone that cannot transcribe loses the transcript, not the voice note —
/// except "no model for any wanted language", which is an error so the app can
/// say which setting to change rather than just that it failed.
final class CubechatTranscribePlugin {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cubechat/transcribe",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "transcribe" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      FileManager.default.fileExists(atPath: path)
    else {
      result(nil)
      return
    }
    // The chosen language first, then the others worth trying — the phone's
    // own languages and the app's. The first one this iPhone can recognise on
    // the device is used: a note in Russian on a phone set to Ukrainian should
    // not fail for want of a Ukrainian model.
    var wanted: [String] = []
    if let localeId = args["locale"] as? String { wanted.append(localeId) }
    wanted.append(contentsOf: (args["fallbacks"] as? [String]) ?? [])
    if wanted.isEmpty { wanted.append(Locale.current.identifier) }

    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      self.recognise(path: path, wanted: wanted, result: result)
    }
  }

  private func recognise(
    path: String,
    wanted: [String],
    result: @escaping FlutterResult
  ) {
    let recogniser = wanted.lazy
      .compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
      .first { $0.isAvailable && $0.supportsOnDeviceRecognition }
    guard let recogniser = recogniser else {
      DispatchQueue.main.async {
        result(FlutterError(
          code: "language_not_supported",
          message: "No on-device model for the wanted languages",
          details: "wanted=\(wanted.joined(separator: ","))"
        ))
      }
      return
    }

    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    // The whole point: the audio stays here.
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false

    // Guards against the completion handler firing twice — it can, and calling
    // a FlutterResult a second time is a crash rather than a warning.
    var answered = false
    recogniser.recognitionTask(with: request) { response, error in
      guard !answered else { return }
      if error != nil {
        answered = true
        DispatchQueue.main.async { result(nil) }
        return
      }
      guard let response = response, response.isFinal else { return }
      answered = true
      let text = response.bestTranscription.formattedString
      DispatchQueue.main.async { result(text.isEmpty ? nil : text) }
    }
  }
}
