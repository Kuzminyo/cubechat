import 'package:flutter/services.dart';

import '../util/debug_log.dart';
import '../util/platform_info.dart';

/// iOS-only doorbell for an app that is no longer running.
///
/// ## Why this exists
///
/// A terminated iOS app receives nothing. The socket died with the process,
/// `BGAppRefreshTask` is not scheduled for an app the user swiped away, and the
/// one mechanism built for "wake up, there is a message" — APNs — needs a paid
/// developer account, signed distribution and a server that knows which npub
/// talks to whom. cubechat has none of those on purpose.
///
/// Significant-change monitoring is the only free way left to run again. iOS
/// relaunches the app into the background when the phone changes neighbourhood
/// — a cell hand-off, roughly half a kilometre, minutes apart — and the native
/// side spends that relaunch the way it spends a scheduled window: pull what
/// the relays are holding, store it, raise the notifications.
///
/// ## What it is not
///
/// It is not delivery. The trigger is the user moving, not anybody writing, so
/// a phone that stays put is a phone that hears nothing until it is opened.
/// What it buys is that walking to the shop catches you up, instead of the
/// messages waiting until you next unlock and open cubechat.
///
/// ## What it costs
///
/// Close to nothing: no GPS is started and no fix is requested — the position
/// is thrown away unread. It needs Always authorisation, which is why arming
/// is conditional rather than automatic: see [start].
class IosSignificantLocation {
  IosSignificantLocation._();

  static final IosSignificantLocation instance = IosSignificantLocation._();

  static const _channel = MethodChannel('cubechat/significant_location');

  bool _armed = false;

  bool get isArmed => _armed;

  /// Arm the doorbell. Returns false when the platform declined — which is the
  /// normal answer, not an error.
  ///
  /// The native side never prompts for anything: it arms only if Always
  /// authorisation is already granted, so a user who has not asked for the
  /// live map is not asked for their location on cubechat's behalf. Calling
  /// this repeatedly is cheap and idempotent.
  Future<bool> start() async {
    if (!PlatformInfo.isIOS) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('start') ?? false;
      if (ok != _armed) {
        DebugLog.instance.log(
          'SLC',
          ok ? 'armed' : 'not armed (no Always authorisation)',
        );
      }
      _armed = ok;
      return ok;
    } on MissingPluginException {
      return false;
    } catch (e) {
      DebugLog.instance.log('SLC', 'arm failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!PlatformInfo.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('stop');
      _armed = false;
    } on MissingPluginException {
      // No native side (tests, other platforms) — nothing to disarm.
    } catch (e) {
      DebugLog.instance.log('SLC', 'disarm failed: $e');
    }
  }
}
