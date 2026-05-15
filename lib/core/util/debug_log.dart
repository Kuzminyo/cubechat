import 'package:flutter/foundation.dart';

/// In-app ring buffer of debug events.
///
/// We chain into [debugPrint] in [install], so every `debugPrint(...)` call
/// — both ours and Flutter's — is also captured here. The Diagnostics screen
/// in the profile renders this list. Cap is 200 lines so we don't grow the
/// heap unbounded when a chatty subsystem (Bluetooth) is going off.
class DebugLog extends ChangeNotifier {
  DebugLog._();

  static final DebugLog instance = DebugLog._();

  static const int _capacity = 200;
  final List<DebugLogEntry> _entries = [];

  /// Newest first.
  List<DebugLogEntry> get entries => List.unmodifiable(_entries.reversed);

  /// Hook into Flutter's debugPrint so every existing log site is captured
  /// automatically. Idempotent.
  static void install() {
    if (_installed) return;
    _installed = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        instance._push(message);
      }
      original(message, wrapWidth: wrapWidth);
    };
  }

  static bool _installed = false;

  /// Add a line that didn't come through debugPrint (e.g. an EventChannel
  /// callback). Tag is a short label like "BLE-CENTRAL" or "NOISE".
  void log(String tag, String message) {
    final line = '[$tag] $message';
    _push(line);
    debugPrint(line);
  }

  void _push(String line) {
    _entries.add(DebugLogEntry(line, DateTime.now()));
    if (_entries.length > _capacity) {
      _entries.removeRange(0, _entries.length - _capacity);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

class DebugLogEntry {
  DebugLogEntry(this.line, this.at);
  final String line;
  final DateTime at;
}
