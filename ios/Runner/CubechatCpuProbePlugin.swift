import Flutter
import Foundation

/// What the process spends CPU on, broken down by thread — the iOS half.
///
/// Android answers this by reading `/proc/self/task/<tid>/stat`, and that is
/// the whole of the Dart implementation next door in `cpu_probe.dart`. iOS has
/// no `/proc` at all, so the panel has been hiding itself on the phone that
/// most needs it: the frame meter says "GPU-bound" on both platforms, but only
/// one of them could say which thread was awake while it happened.
///
/// Mach keeps the same counters the Linux kernel does. `task_threads` lists the
/// threads of this task and `thread_info(THREAD_EXTENDED_INFO)` returns, per
/// thread, the name it was given and the user and system time it has burned
/// since it started. Two samples and a subtraction produce exactly the sentence
/// the Android side produces, from the same arithmetic.
///
/// Public Mach API, not a private one — `task_threads` against
/// `mach_task_self_` is what every crash reporter on the platform is built on.
/// It reads this process and nothing else; there is no way to ask it about
/// another app.
///
/// Nanoseconds come back here and microseconds go over the channel. The Dart
/// side works in microseconds for both platforms, which is a real gain on this
/// one: Linux hands out whole 10 ms ticks, so a thread that used 3 ms reads as
/// zero there and reads as 3 ms here.
final class CubechatCpuProbePlugin: NSObject {
  private let channel: FlutterMethodChannel

  /// The platform thread's mach port, taken in `init` *because* `init` runs on
  /// it — the engine sets this plugin up on the platform thread.
  ///
  /// Kept rather than looked up per sample: sampling happens off the main
  /// thread (below), so asking "which of these is me" at that point would name
  /// the wrong one. A port name is stable for the life of the thread, so one
  /// capture is good for the life of the app.
  private let platformThread: thread_t

  /// A walk over fifty-odd threads, off the thread being measured.
  ///
  /// The Android implementation is asynchronous for this exact reason, and it
  /// is written down there: an earlier version sampled synchronously on the UI
  /// thread and the panel ended up reporting a cost it had itself created. The
  /// syscalls here are far cheaper than opening fifty files, but a measurement
  /// that lands on the busiest thread in the app is the one error a diagnostic
  /// is not allowed to make.
  private let queue = DispatchQueue(label: "cubechat.cpu_probe", qos: .utility)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "cubechat/cpu_probe",
      binaryMessenger: messenger
    )
    platformThread = mach_thread_self()
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "sample" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.queue.async {
        let rows = self.sample()
        DispatchQueue.main.async { result(rows) }
      }
    }
  }

  deinit {
    mach_port_deallocate(mach_task_self_, platformThread)
  }

  /// One row per thread: its name, its CPU in microseconds, and whether it is
  /// the platform thread.
  ///
  /// A thread that vanishes mid-walk is skipped rather than failing the sample
  /// — threads come and go constantly, and the Dart side already treats a
  /// thread missing from one of the two samples as having started at zero.
  private func sample() -> [[String: Any]] {
    var list: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
      let threads = list
    else {
      return []
    }
    // `task_threads` hands out a send right per thread plus the array itself,
    // and every one of them leaks without this. A probe that samples every two
    // seconds leaks fifty ports a sample, which is how a diagnostic ends up
    // being the reason the app dies.
    defer {
      for i in 0..<Int(count) {
        mach_port_deallocate(mach_task_self_, threads[i])
      }
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
      )
    }

    var rows: [[String: Any]] = []
    rows.reserveCapacity(Int(count))
    for i in 0..<Int(count) {
      var info = thread_extended_info_data_t()
      // Computed rather than taken from `THREAD_EXTENDED_INFO_COUNT`: that is
      // a macro over `sizeof`, and macros like it do not survive the import
      // into Swift on every toolchain.
      var size = mach_msg_type_number_t(
        MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
      )
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
          thread_info(threads[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &size)
        }
      }
      guard status == KERN_SUCCESS else { continue }
      rows.append([
        "name": Self.name(in: info),
        "main": threads[i] == platformThread,
        "us": Int((info.pth_user_time &+ info.pth_system_time) / 1000),
      ])
    }
    return rows
  }

  /// The thread's name out of the fixed C array Mach fills in.
  ///
  /// Copied to a local first so the pointer has something with a stable address
  /// to point at, and sized from the value itself rather than from
  /// `MAXTHREADNAMESIZE` for the same reason the count above is computed.
  ///
  /// Unnamed threads — most of the dispatch pool — come back as the empty
  /// string, and the Dart side gives them a row name; naming them here would
  /// put a display decision in the half of the code that cannot be tested.
  private static func name(in info: thread_extended_info_data_t) -> String {
    var buffer = info.pth_name
    // Sized before the pointer is taken, not inside the closure. `&buffer`
    // claims exclusive access for the duration, and reading the same variable
    // to compute the capacity is a second, overlapping access — which Swift
    // rejects outright rather than warns about.
    let capacity = MemoryLayout.size(ofValue: buffer)
    return withUnsafePointer(to: &buffer) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
        String(cString: $0)
      }
    }
  }
}
