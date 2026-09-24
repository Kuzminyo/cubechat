class ProximityReading {
  const ProximityReading({
    this.closest,
    this.closestRssi,
    this.runnerUpRssi,
    required this.isClose,
    required this.warmth,
  });

  final String? closest;
  final int? closestRssi;
  final int? runnerUpRssi;
  final bool isClose;
  final double warmth;
}

class ProximityTracker {
  ProximityTracker({
    this.window = const Duration(seconds: 1),
    this.hold = const Duration(seconds: 3),
    this.closeRssi = ProximityTracker.bumpRssi,
    this.margin = ProximityTracker.bumpMargin,
    this.warmRssi = ProximityTracker.glowRssi,
  });

  // Starting point, not a measurement: phones touching read about -30 to -40 dBm, and half a metre away about -55 to -65 on the two phones this was written for, but models differ by up to 10 dB. Replace with what the BUMP log lines show on the owner's phones, and say so here.
  static const int bumpRssi = -40;
  static const int bumpMargin = 15;
  static const int glowRssi = -60;
  // Minimum number of samples required in the window for a peer to be considered close. A single burst of signal does not prove proximity; the spec requires sustained detection.
  static const int minCloseSamples = 3;

  final Duration window;
  final Duration hold;
  final int closeRssi;
  final int margin;
  final int warmRssi;

  final Map<String, List<(DateTime, int)>> _readings = {};

  // For testing: exposes the number of peers currently tracked.
  int get trackedPeers => _readings.length;

  void add(String peerHex, int rssi, DateTime at) {
    // Ignore readings >= 0 (sentinel and nonsense)
    if (rssi >= 0) {
      return;
    }

    _readings.putIfAbsent(peerHex, () => []);
    _readings[peerHex]!.add((at, rssi));

    // Drop samples older than hold
    final oldestValid = at.subtract(hold);
    _readings[peerHex]!.removeWhere((reading) => reading.$1.isBefore(oldestValid));
  }

  /// How many of [peerHex]'s samples inside the window read [rssi] or
  /// louder. Held readings do not count — the same rule as [minCloseSamples].
  int loudSamples(String peerHex, int rssi, DateTime now) {
    final readings = _readings[peerHex];
    if (readings == null) return 0;
    final windowStart = now.subtract(window);
    var n = 0;
    for (final (at, value) in readings) {
      if (at.isAfter(windowStart) && !at.isAfter(now) && value >= rssi) n++;
    }
    return n;
  }

  void forget(String peerHex) {
    _readings.remove(peerHex);
  }

  void clear() {
    _readings.clear();
  }

  ProximityReading read(DateTime now) {
    final windowStart = now.subtract(window);

    // Evict stale peers (those whose newest sample is older than hold)
    final keysToRemove = <String>[];
    for (final MapEntry(key: peerHex, value: readings) in _readings.entries) {
      if (readings.isNotEmpty) {
        final newest = readings.last;
        if (now.difference(newest.$1) > hold) {
          keysToRemove.add(peerHex);
        }
      }
    }
    for (final key in keysToRemove) {
      _readings.remove(key);
    }

    // Calculate median for each peer and track window sample count
    final medians = <String, int>{};
    final windowSampleCounts = <String, int>{};

    for (final MapEntry(key: peerHex, value: readings) in _readings.entries) {
      // Get samples within the window (windowStart, now]
      final windowSamples = readings
          .where((reading) => reading.$1.isAfter(windowStart) && !reading.$1.isAfter(now))
          .toList();

      late final int median;
      late final int windowCount;

      if (windowSamples.isNotEmpty) {
        // Use samples in window
        final rssiValues = windowSamples.map((r) => r.$2).toList();
        rssiValues.sort();
        median = rssiValues[(rssiValues.length - 1) ~/ 2];
        windowCount = windowSamples.length;
      } else {
        // No samples in window; use the newest sample if it's within hold time
        final newest = readings.last;
        if (now.difference(newest.$1) <= hold) {
          median = newest.$2;
          windowCount = 0; // Held reading, not from window
        } else {
          continue;
        }
      }

      medians[peerHex] = median;
      windowSampleCounts[peerHex] = windowCount;
    }

    if (medians.isEmpty) {
      return const ProximityReading(
        isClose: false,
        warmth: 0.0,
      );
    }

    // Find closest and runner-up
    final sortedEntries = medians.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final closestPeer = sortedEntries[0].key;
    final closestValue = sortedEntries[0].value;
    final runnerUpValue = sortedEntries.length > 1 ? sortedEntries[1].value : null;
    final closestWindowCount = windowSampleCounts[closestPeer] ?? 0;

    // Check if close: requires at least minCloseSamples in the window, sufficient RSSI, and margin over runner-up
    final isCloseValue = closestWindowCount >= minCloseSamples &&
        closestValue >= closeRssi &&
        (runnerUpValue == null || closestValue - runnerUpValue >= margin);

    // Calculate warmth
    final warmthValue = closestValue >= closeRssi
        ? 1.0
        : closestValue <= warmRssi
            ? 0.0
            : (closestValue - warmRssi) / (closeRssi - warmRssi);

    return ProximityReading(
      closest: closestPeer,
      closestRssi: closestValue,
      runnerUpRssi: runnerUpValue,
      isClose: isCloseValue,
      warmth: warmthValue,
    );
  }
}
