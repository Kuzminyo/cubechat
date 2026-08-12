import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/messaging_service.dart';
import '../util/debug_log.dart';

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
/// Reading [messagingServiceProvider] is the whole trick: constructing the
/// service stands the Nostr transport up (or, on a warm resume, the existing
/// socket reconnects on its own backoff timer), the relay replays everything
/// since our persisted watermark, and each frame walks the same path a
/// foreground message does — dedup, signature check, store, notify. So there is
/// nothing to duplicate here; we just have to stay awake while it happens.
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

  ProviderContainer? _container;

  /// True while a refresh is in flight — iOS can fire the task again while the
  /// previous one is still running, and a second overlapping window would
  /// achieve nothing but spend battery.
  bool _running = false;

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
    await refreshNow();
    return true;
  }

  /// Spend one background window pulling relay traffic. Returns when the window
  /// closes; never throws, since the native side is waiting to complete its
  /// task either way.
  Future<void> refreshNow({Duration? window}) async {
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
      container.read(messagingServiceProvider).wakeRelays();
      DebugLog.instance.log('BGFETCH', 'window open');
      await Future<void>.delayed(window ?? IosBackgroundRefresh.window);
      final ms = DateTime.now().difference(started).inMilliseconds;
      DebugLog.instance.log('BGFETCH', 'window closed after ${ms}ms');
    } catch (e) {
      DebugLog.instance.log('BGFETCH', 'refresh failed: $e');
    } finally {
      _running = false;
    }
  }
}
