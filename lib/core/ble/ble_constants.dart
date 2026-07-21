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
  ///
  /// Long, and deliberately longer than Android's idle cycle — which inverts
  /// the "iOS finds a peer sooner" property the active cadence still holds. The
  /// reason that is safe, and the reason this number moved from 20 s:
  ///
  /// Duty cycle was never the iOS problem. iOS already scanned *less* than
  /// Android at both cadences (9% vs 20% idle, 50% vs 71% active), yet iPhones
  /// ran hot where Android didn't — so the cost was not radio-on time but the
  /// per-cycle churn of tearing down and re-establishing a CoreBluetooth scan
  /// session, on a process that (unlike Android's, which is a foreground
  /// service the OS schedules) is never suspended and so does it forever. A
  /// 22 s cycle is ~3900 restarts a day; 60 s is ~1400.
  ///
  /// Slower background discovery costs less than it appears to, because
  /// advertising is continuous and independent of scanning: a backgrounded
  /// phone stays discoverable the whole time, and the peer who wants to reach
  /// us is by definition the one in the foreground, scanning at the active
  /// cadence and connecting to our peripheral. Our own background scanning
  /// mainly exists to notice peers we owe a store-and-forward delivery to —
  /// and anything fresh pins us back to the active cadence anyway
  /// (see [pendingDeliveryChase]).
  static const Duration scanGapIdleIos = Duration(seconds: 58);

  /// Stale threshold at the iOS idle cadence.
  ///
  /// Needs its own number now: the iOS idle cycle is 60 s end to end, so the
  /// shared 75 s threshold would be barely over *one* cycle and a peer sitting
  /// still would blink out of the list and back in every cycle. ~2.5 cycles,
  /// the same margin every other pair here uses.
  static const Duration peerStaleAfterIdleIos = Duration(seconds: 150);

  // The *active* stale threshold is still shared with Android rather than
  // scaled down to the shorter iOS active cycle. It is ≥ 2 cycles there by a
  // wide margin, and a peer blinking out of the Nearby list is a far worse bug
  // than holding a departed one a few seconds too long.

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

  // ---- idle backoff (nobody around) ----
  //
  // The idle cadence assumes someone might be nearby. Most of the time nobody
  // is: a phone in a pocket on the bus runs the idle cycle all day and finds
  // nothing every single time — ~1400 scan sessions a day on iOS, each one a
  // CoreBluetooth start/stop on a process that is never suspended.
  //
  // So when a run of idle windows turns up nothing at all, stretch the gap.
  // Empty windows are evidence that the next one will also be empty, and the
  // whole point of scanning while nobody is there is to notice the moment
  // somebody arrives — which this still does, just less often.
  //
  // Backing off is safe in a way that a blanket-longer idle cadence is not:
  //
  //  * it only engages when the peer map is EMPTY, so no peer's stale
  //    threshold can be undermined by the stretched gap — there is nothing
  //    there to expire.
  //  * it collapses to the base cadence the instant anything is seen, or the
  //    cadence flips back to active (app resumed, delivery owed).
  //  * a peer who wants to reach us does not depend on it. Advertising is
  //    continuous, and they are the one in the foreground scanning at the
  //    active cadence; they find us and connect to our peripheral. Our own
  //    background scanning only decides how fast *we* initiate.

  /// Consecutive empty idle windows tolerated before the gap starts growing.
  /// Small, but >1 so a single unlucky window doesn't trigger a back-off.
  static const int idleBackoffAfterEmptyWindows = 3;

  /// Ceiling on the stretched idle gap. Bounds the worst case for noticing a
  /// peer who walks up while we're backed off.
  static const Duration idleGapMax = Duration(minutes: 4);

  /// Idle gap after [emptyWindows] consecutive sightings of nothing.
  ///
  /// Doubles once per empty window past [idleBackoffAfterEmptyWindows], capped
  /// at [idleGapMax]. Returns [base] unchanged until the threshold is crossed,
  /// so the common "someone is around" case is untouched.
  static Duration idleGapWithBackoff({
    required Duration base,
    required int emptyWindows,
  }) {
    final over = emptyWindows - idleBackoffAfterEmptyWindows;
    if (over <= 0) return base;
    var gap = base;
    for (var i = 0; i < over; i++) {
      gap *= 2;
      if (gap >= idleGapMax) return idleGapMax;
    }
    return gap;
  }

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

  /// How long a peer may go unseen before it's dropped, for the running
  /// cadence on this platform. Platform-aware only while idle — that's the one
  /// cadence whose cycle length differs enough between the two to matter.
  static Duration peerStaleAfterFor({
    required bool active,
    required bool isIOS,
  }) {
    if (active) return peerStaleAfter;
    return isIOS ? peerStaleAfterIdleIos : peerStaleAfterIdle;
  }
}
