import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/map/data/map_presence_controller.dart';
import '../transport/messaging_service.dart';
import '../util/debug_log.dart';
import '../util/location_service.dart';

/// iOS-only catch-up window, driven by `BGAppRefreshTask` on the native side.
///
/// ## Why this exists
///
/// iOS suspends a backgrounded app, and a suspended process has no live relay
/// socket — so a message sent over the internet while cubechat is in the
/// background arrives only when the user next opens the app, notification and
/// all. Bluetooth is exempt (the `bluetooth-central` / `bluetooth-peripheral`
/// background modes keep us running for radio events), but the internet path is
/// not.
///
/// A real fix is a push server: something always-on that holds a device token
/// and pokes the phone. That needs a paid Apple Developer account for the
/// `aps-environment` entitlement, signed distribution instead of sideloading,
/// and a service that learns which npub talks to whom. `BGAppRefreshTask` is
/// the free, server-free alternative: iOS wakes us on a schedule *it* chooses,
/// we spend the granted seconds pulling whatever the relays are holding, and
/// the normal inbound pipeline stores it and raises notifications exactly as it
/// would in the foreground.
///
/// ## What it does and does not buy
///
/// Delivery is **delayed and not guaranteed**. iOS decides when (and whether)
/// to run the task, learning from how the user actually opens the app; in
/// practice that is tens of minutes, and Low Power Mode or a swiped-away app
/// suppresses it entirely. This is a catch-up, not a doorbell.
///
/// ## How the window is spent
///
/// Reading [messagingServiceProvider] is the main trick: constructing the
/// service stands the Nostr transport up (or, on a warm resume, the existing
/// socket reconnects on its own backoff timer), the relay replays everything
/// since our persisted watermark, and each frame walks the same path a
/// foreground message does — dedup, signature check, store, notify. The same
/// short window also pokes map presence, so a significant-location wake can
/// publish the user's current pin instead of only draining chat messages — and
/// when the wake-up *is* the location doorbell, the coarse fix it rang with
/// travels with it, so that pin costs no radio at all. See [fixFromWake].
class IosBackgroundRefresh {
  IosBackgroundRefresh._();

  static final IosBackgroundRefresh instance = IosBackgroundRefresh._();

  /// Must match the channel name and method in `AppDelegate.swift`.
  static const MethodChannel channel =
      MethodChannel('cubechat/background_refresh');
  static const String runMethod = 'runRefresh';

  /// How long we hold the window open. iOS grants a `BGAppRefreshTask` about
  /// 30 s and kills the app if the task overruns, so we stop well short and let
  /// the native side complete the task on our return. Long enough for a socket
  /// handshake plus a backlog replay on a slow connection.
  static const Duration window = Duration(seconds: 20);

  /// Unit tests use millisecond windows to prove boundedness; those are too
  /// short to do useful location work and would only start async provider work
  /// that outlives the test container. Real native windows are much longer.
  static const Duration mapPresenceMinimumWindow = Duration(seconds: 1);

  ProviderContainer? _container;

  /// True while a refresh is in flight — iOS can fire the task again while the
  /// previous one is still running, and a second overlapping window would
  /// achieve nothing but spend battery.
  bool _running = false;

  /// Let go of the in-flight guard, for a test that is about to open its own
  /// window.
  ///
  /// This is a singleton with a boolean in it, and the tests in one file share
  /// both. A window opened by an earlier test outlives the test that opened it
  /// whenever the machine is slower than the millisecond budget that test
  /// chose — so the next one called [refreshNow], was told "already running",
  /// and asserted against a poke that never happened. It passed on a
  /// workstation and failed on a CI runner, which is the shape of every flake
  /// that survives long enough to be annoying.
  ///
  /// Only the flag. Nothing is cancelled, because the previous window's work is
  /// harmless and finishing it is not this method's business.
  @visibleForTesting
  void releaseWindowForTest() => _running = false;

  /// Wire the native channel to [container]. Called from `main()` before
  /// `runApp` so the handler exists even when iOS launches us straight into the
  /// background, where no frame is ever rendered and the widget tree may never
  /// build.
  void install(ProviderContainer container) {
    _container = container;
    channel.setMethodCallHandler(_handle);
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != runMethod) {
      throw MissingPluginException('unknown method ${call.method}');
    }
    await refreshNow(offered: fixFromWake(call.arguments));
    return true;
  }

  /// The position a significant-location wake-up arrived with, or null.
  ///
  /// A scheduled window carries no arguments at all; a doorbell carries the
  /// coarse fix the baseband already had. Taking it is the difference between
  /// republishing the pin for free and asking CoreLocation for a cold fix in
  /// the background, which is radio time on the one path where nobody is
  /// watching the screen to see it spent.
  ///
  /// Everything is checked, because this is a platform boundary and a wrong
  /// number here becomes a pin somewhere the user has never been. The stamp is
  /// the fix's own, not the moment it arrived: a relaunch spends seconds
  /// booting Dart before this runs, and [StampedLocationFix.fresh] is what
  /// decides whether the position survived that.
  @visibleForTesting
  static StampedLocationFix? fixFromWake(Object? arguments) {
    if (arguments is! Map) return null;
    final lat = arguments['lat'];
    final lon = arguments['lon'];
    final accuracy = arguments['accuracy'];
    final at = arguments['at'];
    if (lat is! num || lon is! num || accuracy is! num || at is! num) {
      return null;
    }
    if (lat.isNaN || lon.isNaN || accuracy.isNaN) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    if (accuracy < 0 || at <= 0) return null;
    return StampedLocationFix(
      LocationFix(
        latitude: lat.toDouble(),
        longitude: lon.toDouble(),
        accuracyMetres: accuracy.round(),
      ),
      DateTime.fromMillisecondsSinceEpoch(at.toInt()),
    );
  }

  /// Spend one background window pulling relay traffic. Returns when the window
  /// closes; never throws, since the native side is waiting to complete its
  /// task either way.
  Future<void> refreshNow({
    Duration? window,
    StampedLocationFix? offered,
  }) async {
    final container = _container;
    if (container == null) {
      DebugLog.instance
          .log('BGFETCH', 'refresh requested before install() — ignoring');
      return;
    }
    if (_running) {
      DebugLog.instance.log('BGFETCH', 'refresh already running — ignoring');
      return;
    }
    _running = true;
    final started = DateTime.now();
    try {
      // Stands the relay transport up and pokes every relay immediately. A
      // background window is short; spending it waiting for a reconnect backoff
      // is exactly how iOS internet messages sat on relays until the user
      // manually opened the app.
      final effectiveWindow = window ?? IosBackgroundRefresh.window;
      container.read(messagingServiceProvider).wakeRelays(force: true);
      if (effectiveWindow >= mapPresenceMinimumWindow) {
        unawaited(_pokeMapPresence(container, offered));
      }
      // Which of the two wake-ups this is, because they are not the same event
      // and the log could not tell them apart.
      //
      // A shared log had nine windows between 13:07 and 13:19 and then none
      // for 106 minutes, which reads as iOS spending a background-refresh
      // budget and cutting us off. It also reads exactly like somebody walking
      // for twelve minutes and then sitting down — a significant-location
      // doorbell rings on cell hand-offs, as often as the cells change. Those
      // are opposite conclusions and the line said nothing that separated
      // them, so the throttle I nearly wrote here would have been aimed at a
      // cause I had not established.
      //
      // A doorbell arrives with the coarse fix the baseband already had; a
      // scheduled window carries no arguments at all. That is the whole tell,
      // and it was already in scope.
      DebugLog.instance.log(
        'BGFETCH',
        'window open (${offered == null ? 'scheduled' : 'location wake'})',
      );
      await Future<void>.delayed(effectiveWindow);
      final ms = DateTime.now().difference(started).inMilliseconds;
      DebugLog.instance.log('BGFETCH', 'window closed after ${ms}ms');
    } catch (e) {
      DebugLog.instance.log('BGFETCH', 'refresh failed: $e');
    } finally {
      _running = false;
    }
  }

  Future<void> _pokeMapPresence(
    ProviderContainer container,
    StampedLocationFix? offered,
  ) async {
    try {
      await container
          .read(mapPresenceControllerProvider.notifier)
          .pokeNow(offered: offered)
          .timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          DebugLog.instance.log('BGFETCH', 'map presence poke timed out');
        },
      );
    } catch (e) {
      DebugLog.instance.log('BGFETCH', 'map presence poke failed: $e');
    }
  }
}
