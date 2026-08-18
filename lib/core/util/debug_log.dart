import 'dart:async';

import 'package:flutter/foundation.dart';

/// In-app ring buffer of debug events.
///
/// We chain into [debugPrint] in [install], so every `debugPrint(...)` call
/// — both ours and Flutter's — is also captured here. The Diagnostics screen
/// in the profile renders this list. Cap is 200 lines so we don't grow the
/// heap unbounded when a chatty subsystem (Bluetooth) is going off.
///
/// A line identical to the one before it is *counted* rather than appended —
/// the syslog trick. The cap is what makes this matter: one subsystem repeating
/// itself used to evict every other line in the buffer inside a few seconds, so
/// the log reliably held nothing but the noise by the time anyone read it.
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
  ///
  /// Just routes through [debugPrint], which is hooked by [install] to push
  /// into the buffer exactly once. Pushing here directly would double every
  /// entry because the hook fires too.
  void log(String tag, String message) {
    debugPrint('[$tag] $message');
  }

  void _push(String line) {
    final last = _entries.isEmpty ? null : _entries.last;
    if (last != null && last.line == line) {
      last.repeats++;
      last.at = DateTime.now();
    } else {
      _entries.add(DebugLogEntry(line, DateTime.now()));
      if (_entries.length > _capacity) {
        _entries.removeRange(0, _entries.length - _capacity);
      }
    }
    _scheduleNotify();
  }

  Timer? _notifyTimer;

  /// At most one rebuild per [_notifyEvery], however chatty the subsystem.
  ///
  /// The one listener is the Diagnostics screen, and it rebuilds *itself* —
  /// panels, log list and all — for each notification. A relay writes several
  /// lines a second and a media transfer writes dozens, so the screen was
  /// rebuilding at the rate the log was written.
  ///
  /// That is not free anywhere and it is dreadful on a slow phone: one reported
  /// `build avg 35.5, p90 103.6 ms` with 149 of 240 frames over budget while
  /// sitting on this screen doing nothing — about five frames a second, which
  /// is exactly the log's line rate. The panel was measuring the cost of
  /// watching the panel.
  ///
  /// A quarter of a second is still faster than anyone reads, and it is the
  /// difference between one rebuild and twenty.
  static const Duration _notifyEvery = Duration(milliseconds: 250);

  void _scheduleNotify() {
    // One-shot rather than periodic: a quiet app costs no timer at all, which
    // matters because this object exists for the whole life of the process.
    _notifyTimer ??= Timer(_notifyEvery, () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void clear() {
    _entries.clear();
    // Straight through, not coalesced: this one is a tap, and a list that keeps
    // its contents for another quarter second reads as a button that did not
    // work.
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }
}

class DebugLogEntry {
  DebugLogEntry(this.line, this.at);
  final String line;

  /// When the line was last seen — updated as [repeats] climbs, so the
  /// timestamp always answers "how recently", not "how long ago it started".
  DateTime at;

  /// 1 for a line seen once. Rendered as a "×N" suffix.
  int repeats = 1;

  /// What the diagnostics screen and the shared log file print.
  String get text => repeats > 1 ? '$line  ×$repeats' : line;
}

/// Collapses per-packet logging into one line per [window], per counterparty.
///
/// A media transfer writes a BLE fragment every few milliseconds. Logging each
/// one filled the entire ring buffer in under twenty seconds and left nothing
/// to diagnose with — the log became the thing hiding the problem, and a shared
/// log was thousands of lines of `write from X (236B)`. The count and the total
/// say everything the individual lines did.
class TrafficMeter {
  TrafficMeter(
    this._tag,
    this._verb, {
    Duration window = const Duration(seconds: 1),
  }) : _window = window;

  final String _tag;

  /// Verb phrase the line opens with, e.g. `write from` or `inbound notify`.
  final String _verb;
  final Duration _window;

  final Map<String, ({int count, int bytes})> _pending = {};
  Timer? _flush;

  /// [who] is the peer the packets came from, or an empty string when the log
  /// line never named one.
  void add(String who, int bytes) {
    final prior = _pending[who];
    _pending[who] = (
      count: (prior?.count ?? 0) + 1,
      bytes: (prior?.bytes ?? 0) + bytes,
    );
    // One-shot rather than periodic: a quiet link costs no timer at all, which
    // matters because this runs on every link the app holds.
    _flush ??= Timer(_window, _emit);
  }

  void _emit() {
    _flush = null;
    for (final entry in _pending.entries) {
      final (:count, :bytes) = entry.value;
      final where = entry.key.isEmpty ? '' : ' ${entry.key}';
      DebugLog.instance.log(
        _tag,
        count == 1
            ? '$_verb$where (${bytes}B)'
            : '$_verb$where ×$count (${_size(bytes)})',
      );
    }
    _pending.clear();
  }

  static String _size(int bytes) => bytes < 1024
      ? '${bytes}B'
      : '${(bytes / 1024).toStringAsFixed(1)}KB';
}
