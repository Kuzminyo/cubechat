import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/util/platform_info.dart';

import '../../../core/util/debug_log.dart';
import 'call_tones.dart';

/// `end` comes from iOS, where CallKit's red button means decline while the
/// call rings and hang up once it is answered - and from Android's Hang up in
/// the shade. `speaker` from the call screen Android keeps over the lock
/// screen once a call is answered there.
enum IncomingCallActionKind { answer, decline, end, speaker }

/// A button pressed on the phone's own incoming-call screen, for the call
/// identified by [key].
typedef IncomingCallAction = ({IncomingCallActionKind kind, String key});

/// The words that screen shows, in the app's language rather than the phone's.
typedef IncomingCallLabels = ({
  String title,
  String answer,
  String decline,
  String ongoing,
  String hangUp,
  String speaker,
});

/// The incoming call drawn by the phone rather than by the app.
///
/// The app's own call screen only exists while the app is on screen. A call to
/// a phone whose app was in the background, or swiped away, rang a screen
/// nobody could see — so it looked, from both ends, like the call went nowhere.
/// This is the other half: a notification the system turns into a full-screen
/// call over the lock screen, or a heads-up with Answer and Decline.
abstract interface class IncomingCallSurface {
  Stream<IncomingCallAction> get actions;

  /// Whether this surface rings even while the app is on screen. CallKit does,
  /// and then it is the only thing that rings; Android's notification does
  /// not, and the app's own call screen rings instead.
  bool get ringsInForeground;

  Future<void> show({
    required String key,
    required String name,
    Uint8List? avatar,
  });

  /// The call is on: keep it where the phone shows calls in progress - the
  /// notification shade on Android, with the running time and Hang up. Called
  /// again when anything on it changes. CallKit shows its own.
  Future<void> ongoing({
    required String key,
    required String name,
    Uint8List? avatar,
    required DateTime since,
  });

  /// The call was answered, from anywhere. A notification is taken down; a
  /// CallKit call stays up, because it now carries the conversation's audio.
  Future<void> answered(String key);

  /// Take it down: the call is over, or it moved into the app. [key] names the
  /// call, so an older call's late dismiss cannot take down a newer one; null
  /// takes down whatever is showing.
  Future<void> dismiss(String? key);
}

/// For tests and desktop.
class NoIncomingCallSurface implements IncomingCallSurface {
  const NoIncomingCallSurface();

  @override
  Stream<IncomingCallAction> get actions => const Stream.empty();

  @override
  bool get ringsInForeground => false;

  @override
  Future<void> show({
    required String key,
    required String name,
    Uint8List? avatar,
  }) async {}

  @override
  Future<void> ongoing({
    required String key,
    required String name,
    Uint8List? avatar,
    required DateTime since,
  }) async {}

  @override
  Future<void> answered(String key) async {}

  @override
  Future<void> dismiss(String? key) async {}
}

/// `IncomingCall.kt` on the other end of `cubechat/incoming_call`.
class AndroidIncomingCallSurface implements IncomingCallSurface {
  AndroidIncomingCallSurface({required this.labels}) {
    _channel.setMethodCallHandler(_fromPlatform);
    // A button pressed while this isolate was still starting was held natively.
    unawaited(_takePending());
  }

  static const _channel = MethodChannel('cubechat/incoming_call');

  final IncomingCallLabels Function() labels;
  final _actions = StreamController<IncomingCallAction>.broadcast();

  @override
  Stream<IncomingCallAction> get actions => _actions.stream;

  @override
  bool get ringsInForeground => false;

  /// The ringing notification comes down; the call moves to the one in the
  /// shade, which [ongoing] puts up.
  @override
  Future<void> answered(String key) async {
    try {
      await _channel.invokeMethod<void>('dismiss', {'key': key});
    } catch (_) {}
  }

  @override
  Future<void> ongoing({
    required String key,
    required String name,
    Uint8List? avatar,
    required DateTime since,
  }) async {
    final words = labels();
    try {
      await _channel.invokeMethod<void>('ongoing', {
        'key': key,
        'name': name,
        'avatar': avatar,
        'since': since.millisecondsSinceEpoch,
        'title': words.ongoing,
        'hangUp': words.hangUp,
      });
    } catch (e) {
      DebugLog.instance.log('CALL', 'could not show the call in the shade: $e');
    }
  }

  @override
  Future<void> show({
    required String key,
    required String name,
    Uint8List? avatar,
  }) async {
    final words = labels();
    try {
      final fullScreen = await _channel.invokeMethod<bool>('show', {
        'key': key,
        'name': name,
        'avatar': avatar,
        'title': words.title,
        'answer': words.answer,
        'decline': words.decline,
        // For the call screen that stays over the lock screen when the call
        // is answered there.
        'ongoing': words.ongoing,
        'hangUp': words.hangUp,
        'speaker': words.speaker,
      });
      DebugLog.instance.log(
        'CALL',
        'ringing on the phone\'s own screen '
            '(${fullScreen == true ? 'full screen allowed' : 'heads-up only'})',
      );
    } catch (e) {
      DebugLog.instance.log('CALL', 'could not show the incoming call: $e');
    }
  }

  @override
  Future<void> dismiss(String? key) async {
    try {
      await _channel.invokeMethod<void>('dismiss', {'key': key});
      await _channel.invokeMethod<void>('ongoingStop');
    } catch (e) {
      DebugLog.instance.log('CALL', 'could not take the incoming call down: $e');
    }
  }

  Future<void> _takePending() async {
    try {
      final held = await _channel.invokeMapMethod<String, String>('takePending');
      if (held == null) return;
      _emit(held['action'], held['key']);
    } catch (_) {
      // No plugin on this engine — a test, or a platform without one.
    }
  }

  Future<Object?> _fromPlatform(MethodCall call) async {
    final args = call.arguments;
    _emit(call.method, args is Map ? args['key'] as String? : null);
    return null;
  }

  void _emit(String? action, String? key) {
    if (key == null) return;
    final kind = switch (action) {
      'answer' => IncomingCallActionKind.answer,
      'decline' => IncomingCallActionKind.decline,
      'end' => IncomingCallActionKind.end,
      'speaker' => IncomingCallActionKind.speaker,
      _ => null,
    };
    if (kind == null) return;
    _actions.add((kind: kind, key: key));
  }
}

/// CallKit, through `CubechatCallKit.swift` on `cubechat/callkit`.
///
/// Every incoming call on an iPhone goes here, on screen or not. A call that
/// arrives by VoIP push has already been reported to CallKit natively before
/// Dart existed; [show] then names it. One that arrives over a relay while the
/// app is running is reported by [show] itself. Either way it is CallKit's
/// screen and CallKit's ringtone, and the app's own call screen shows the call
/// behind it.
class IosCallKitSurface implements IncomingCallSurface {
  IosCallKitSurface({this.onVoipToken}) {
    _channel.setMethodCallHandler(_fromPlatform);
    unawaited(_takePending());
  }

  static const _channel = MethodChannel('cubechat/callkit');

  /// PushKit hands the token over a moment after launch, and again whenever
  /// it changes; the push registration has to be sent again with it.
  final void Function()? onVoipToken;

  final _actions = StreamController<IncomingCallAction>.broadcast();

  /// The token PushKit gave this install, or null before it has.
  static Future<String?> voipToken() async {
    try {
      return await _channel.invokeMethod<String>('voipToken');
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<IncomingCallAction> get actions => _actions.stream;

  @override
  bool get ringsInForeground => true;

  /// CallKit keeps an answered call on its own screen and in the status bar.
  @override
  Future<void> ongoing({
    required String key,
    required String name,
    Uint8List? avatar,
    required DateTime since,
  }) async {}

  /// No avatar: CallKit draws only a name, whatever the app has.
  @override
  Future<void> show({
    required String key,
    required String name,
    Uint8List? avatar,
  }) async {
    try {
      final shown = await _channel.invokeMethod<bool>('show', {
        'key': key,
        'name': name,
      });
      DebugLog.instance.log(
        'CALL',
        shown == true
            ? 'ringing on CallKit'
            : 'CallKit did not ring (declined already, or refused)',
      );
    } catch (e) {
      DebugLog.instance.log('CALL', 'could not report the call to CallKit: $e');
    }
  }

  @override
  Future<void> answered(String key) async {
    try {
      await _channel.invokeMethod<void>('answered', {'key': key});
    } catch (_) {}
  }

  @override
  Future<void> dismiss(String? key) async {
    try {
      await _channel.invokeMethod<void>('dismiss', {'key': key});
    } catch (_) {}
  }

  Future<void> _takePending() async {
    try {
      final held = await _channel.invokeListMethod<Object?>('takePending');
      for (final entry in held ?? const <Object?>[]) {
        if (entry is Map) _emit(entry['action'] as String?, entry['key'] as String?);
      }
    } catch (_) {}
  }

  Future<Object?> _fromPlatform(MethodCall call) async {
    if (call.method == 'voipToken') {
      onVoipToken?.call();
      return null;
    }
    final args = call.arguments;
    _emit(call.method, args is Map ? args['key'] as String? : null);
    return null;
  }

  void _emit(String? action, String? key) {
    if (key == null) return;
    final kind = switch (action) {
      'answer' => IncomingCallActionKind.answer,
      'end' => IncomingCallActionKind.end,
      _ => null,
    };
    if (kind == null) return;
    _actions.add((kind: kind, key: key));
  }
}

/// The phone's own ringtone and vibration, through `CallRinger.kt`.
///
/// For a call ringing while the app is on screen. It replaced a sound file
/// played through the media plugin, which could stay silent - "no sound when
/// it rings" was reported twice - and which ignored the ringer switch.
class AndroidSystemCallTones implements CallTones {
  const AndroidSystemCallTones();

  static const _channel = MethodChannel('cubechat/incoming_call');

  @override
  Future<void> play(CallTone tone) async {
    try {
      // The ringtone for a call to this phone; the dialler's own tones,
      // generated rather than played from a file, for the caller - "beeps
      // while calling and a sound when the call ends" was the report, and
      // until now a caller heard silence until the other side spoke.
      await _channel.invokeMethod<void>(switch (tone) {
        CallTone.incoming => 'ringStart',
        CallTone.ringback => 'ringbackStart',
        CallTone.ended => 'endTone',
      });
      DebugLog.instance.log('CALL', '${tone.name} tone on');
    } catch (e) {
      DebugLog.instance.log('CALL', '${tone.name} tone could not start: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('ringStop');
    } catch (_) {}
  }
}

/// The phone's own call surface for this platform, or none.
IncomingCallSurface platformCallSurface({
  required IncomingCallLabels Function() labels,
  void Function()? onVoipToken,
}) {
  if (PlatformInfo.isAndroid) return AndroidIncomingCallSurface(labels: labels);
  if (PlatformInfo.isIOS) return IosCallKitSurface(onVoipToken: onVoipToken);
  return const NoIncomingCallSurface();
}
