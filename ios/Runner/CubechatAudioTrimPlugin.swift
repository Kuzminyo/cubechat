import AVFoundation
import Flutter

/// Cuts a section out of a recorded voice message.
///
/// Voice notes are AAC-LC in an MP4 container, which cannot be trimmed by
/// slicing bytes — the sample tables in `moov` describe every frame's offset,
/// so a truncated file is a corrupt one. `AVAssetExportSession` with the
/// passthrough-flavoured `AppleM4A` preset re-muxes instead: compressed frames
/// are copied across untouched, so the cut costs no quality and takes
/// milliseconds.
///
/// Every failure path returns nil rather than an error. The Dart side then
/// sends the untrimmed recording, so a device that cannot do this loses the
/// trim, not the message.
final class CubechatAudioTrimPlugin {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cubechat/audio_trim",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "trim" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let source = args["source"] as? String,
      let dest = args["dest"] as? String,
      let startMs = (args["startMs"] as? NSNumber)?.int64Value,
      let endMs = (args["endMs"] as? NSNumber)?.int64Value,
      endMs > startMs
    else {
      result(nil)
      return
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: source))
    guard
      let export = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetAppleM4A
      )
    else {
      result(nil)
      return
    }

    let destURL = URL(fileURLWithPath: dest)
    // The exporter refuses to write over an existing file.
    try? FileManager.default.removeItem(at: destURL)

    export.outputURL = destURL
    export.outputFileType = .m4a
    export.timeRange = CMTimeRange(
      start: CMTime(value: startMs, timescale: 1000),
      end: CMTime(value: endMs, timescale: 1000)
    )

    export.exportAsynchronously {
      // Hop back to the platform thread: FlutterResult must not be called
      // from the exporter's private queue.
      DispatchQueue.main.async {
        result(export.status == .completed ? dest : nil)
      }
    }
  }
}
