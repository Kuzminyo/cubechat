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
        // Said out loud rather than swallowed: "it does not transcribe on
        // iOS" came back with a log that held nothing at all, because every
        // way this can fail answered with the same silent nil. Permission
        // refused once is refused for good until Settings, and that is a
        // different thing from a missing language model.
        DispatchQueue.main.async {
          result(FlutterError(
            code: "not_authorized",
            message: "Speech recognition was not allowed",
            details: "status=\(status.rawValue)"
          ))
        }
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
    // Every candidate and what was wrong with it — the phone's own languages
    // after the wanted ones, since a note in a language this iPhone has no
    // model for should still be tried in one it does.
    var candidates = wanted
    for language in Locale.preferredLanguages where !candidates.contains(language) {
      candidates.append(language)
    }
    var tried: [String] = []
    var chosen: SFSpeechRecognizer?
    for id in candidates {
      guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: id)) else {
        tried.append("\(id):none")
        continue
      }
      if !recogniser.isAvailable {
        tried.append("\(id):unavailable")
        continue
      }
      if !recogniser.supportsOnDeviceRecognition {
        // On-device only, always: a cloud fallback would post the contents of
        // a private voice note to Apple, which is the one thing this app
        // exists not to do.
        tried.append("\(id):no-on-device")
        continue
      }
      tried.append("\(id):ok")
      chosen = recogniser
      break
    }
    guard let recogniser = chosen else {
      DispatchQueue.main.async {
        result(FlutterError(
          code: "language_not_supported",
          message: "No on-device model for the wanted languages",
          details: "tried=\(tried.joined(separator: ","))"
        ))
      }
      return
    }
    let note = "tried=\(tried.joined(separator: ","))"

    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    // The whole point: the audio stays here.
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false

    // Guards against the completion handler firing twice — it can, and calling
    // a FlutterResult a second time is a crash rather than a warning.
    var answered = false
    recogniser.recognitionTask(with: request) { response, error in
      guard !answered else { return }
      if let error = error as NSError? {
        answered = true
        DispatchQueue.main.async {
          result(FlutterError(
            code: "recognition_failed",
            message: error.localizedDescription,
            details: "\(note);domain=\(error.domain),code=\(error.code)"
          ))
        }
        return
      }
      guard let response = response, response.isFinal else { return }
      answered = true
      let text = response.bestTranscription.formattedString
      // The same shape Android answers with, so one log line reads the same
      // on both: the text, and the numbers behind it.
      DispatchQueue.main.async {
        result(["text": text.isEmpty ? nil : text, "notes": note])
      }
    }
  }
}
