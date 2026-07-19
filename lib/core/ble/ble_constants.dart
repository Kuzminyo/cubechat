/// BLE protocol constants for the Cubechat mesh transport.
///
/// UUIDs were generated once with `dart:math.Random.secure` + RFC 4122 v4
/// and are deliberately fixed — they identify the cubechat GATT service
/// and let peers filter scan results to "things that speak cubechat".
abstract final class BleConstants {
  /// Primary GATT service. Every cubechat node advertises this UUID.
  static const String serviceUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c20';

  /// Characteristic for sending an outbound frame to a peer (write w/o response).
  static const String outboundCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c21';

  /// Characteristic for receiving inbound frames from a peer (notify).
  static const String inboundCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c22';

  /// Read-only characteristic exposing this peer's static metadata
  /// (pubkey fingerprint, protocol version, capability flags).
  static const String peerInfoCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c23';

  /// Protocol version we currently speak.
  static const int protocolVersion = 1;

  /// Manufacturer data ID we tag scan-response packets with.
  /// (Picked deliberately in the unassigned range; not a real CIC.)
  static const int manufacturerId = 0xC0BE; // "CuBE"

  /// MTU we request when connecting. 247 is the practical Android max
  /// minus overhead; iOS will cap to its own ceiling automatically.
  static const int preferredMtu = 247;

  /// How long a single scan window runs before we restart it, while the user
  /// is actually watching for peers (app in the foreground) or we're holding
  /// messages to hand over.
  static const Duration scanWindow = Duration(seconds: 10);

  /// Quiet period between active scan windows (battery friendliness).
  static const Duration scanGap = Duration(seconds: 4);

  /// Peer is considered stale if we haven't seen it for this long, at the
  /// active cadence. Comfortably over one scan cycle, so a single missed
  /// window doesn't drop a peer that's still there.
  static const Duration peerStaleAfter = Duration(seconds: 30);

  // ---- idle cadence ----
  //
  // The active cadence above keeps the radio on 71% of the time. That is the
  // right trade while someone is looking at the Nearby list, and the wrong one
  // for an app sitting backgrounded in a pocket for an hour — it was the
  // second-biggest battery drain after the animated backdrop. Idle drops the
  // duty cycle to 20%: a peer takes longer to notice, which nobody is awake to
  // see. Anything that needs prompt discovery (foreground, or a pending
  // store-and-forward delivery) pins the scanner back to the active cadence.

  /// Scan window while idle (backgrounded, nothing waiting to deliver).
  static const Duration scanWindowIdle = Duration(seconds: 6);

  /// Quiet period between idle scan windows.
  static const Duration scanGapIdle = Duration(seconds: 24);

  /// Stale threshold at the idle cadence. The idle cycle is 30 s end to end,
  /// so the active 30 s threshold would expire peers that are still right
  /// there; this is ~2.5 cycles, the same margin the active pair uses.
  static const Duration peerStaleAfterIdle = Duration(seconds: 75);

  // ---- iOS cadence ----
  //
  // The cadences above are sized for Android, where the scan callback fires
  // repeatedly for the same device and a long window keeps RSSI fresh. iOS
  // does not work that way. We scan with `continuousUpdates: false`, so
  // flutter_blue_plus leaves CBCentralManagerScanOptionAllowDuplicatesKey
  // unset, and CoreBluetooth then reports each peripheral EXACTLY ONCE per
  // scan session.
  //
  // So on iOS a 10 s window tells us precisely what a 3 s window would: every
  // peer already in range is reported in the first moments, and the remaining
  // seconds only exist to catch someone who walks up mid-window — which the
  // next window catches anyway. The window is close to pure waste, and the
  // radio is in continuous receive for all of it.
  //
  // That makes the iOS trade a rare one with no downside: shorten the window
  // *and* the whole cycle. Radio-on time drops, and because discovery latency
  // is dominated by the cycle period rather than the window, a peer is found
  // SOONER than under the Android numbers, not later.
  //
  //   active: 10 s / 4 s  (71%, 14 s cycle) → 3 s / 3 s  (50%,  6 s cycle)
  //   idle:    6 s / 24 s (20%, 30 s cycle) → 2 s / 20 s (9%,  22 s cycle)
  //
  // androidScanMode is a no-op on iOS, so this cycle shape is the only power
  // knob CoreBluetooth actually gives us.

  /// Scan window on iOS while active. One report per peer per session means
  /// this only has to be long enough to receive the batch.
  static const Duration scanWindowIos = Duration(seconds: 3);

  /// Quiet period between active iOS scan windows.
  static const Duration scanGapIos = Duration(seconds: 3);

  /// Scan window on iOS while idle.
  static const Duration scanWindowIdleIos = Duration(seconds: 2);

  /// Quiet period between idle iOS scan windows.
  static const Duration scanGapIdleIos = Duration(seconds: 20);

  // The stale thresholds are deliberately shared with Android rather than
  // scaled down to match the shorter iOS cycles. They are already ≥ 2 cycles
  // there by a wide margin, and a peer blinking out of the Nearby list is a
  // far worse bug than holding a departed one a few seconds too long.

  /// How long a queued delivery keeps the scanner at the active cadence.
  ///
  /// Holding frames for an unreachable peer is a reason to look for them
  /// harder — but the store-and-forward buffer keeps frames for a whole hour,
  /// and "we owe someone a delivery" was pinning the radio to the active
  /// cadence for all of it. A single undeliverable message therefore cost an
  /// hour at 71% duty (Android) or 50% (iOS) on a backgrounded phone, which is
  /// most of the battery complaint this branch exists to fix.
  ///
  /// Someone who walks out of range and comes back typically does so within a
  /// few minutes; past that the idle cadence still finds them within a cycle
  /// (~22–30 s) and the flush happens then. So chase hard briefly, then let the
  /// frames wait cheaply — they are held either way.
  static const Duration pendingDeliveryChase = Duration(minutes: 5);

  /// Scan window for the running cadence on this platform.
  static Duration scanWindowFor({required bool active, required bool isIOS}) {
    if (isIOS) return active ? scanWindowIos : scanWindowIdleIos;
    return active ? scanWindow : scanWindowIdle;
  }

  /// Quiet period for the running cadence on this platform.
  static Duration scanGapFor({required bool active, required bool isIOS}) {
    if (isIOS) return active ? scanGapIos : scanGapIdleIos;
    return active ? scanGap : scanGapIdle;
  }
}
