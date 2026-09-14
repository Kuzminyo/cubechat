import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/util/debug_log.dart';

/// `end` comes from iOS, where CallKit's red button means decline while the
/// call rings and hang up once it is answered.
enum IncomingCallActionKind { answer, decline, end }

/// A button pressed on the phone's own incoming-call screen, for the call
/// identified by [key].
typedef IncomingCallAction = ({IncomingCallActionKind kind, String key});

/// The words that screen shows, in the app's language rather than the phone's.
typedef IncomingCallLabels = ({String title, String answer, String decline});

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

  Future<void> show({required String key, required String name});

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
  Future<void> show({required String key, required String name}) async {}

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

  @override
  Future<void> answered(String key) => dismiss(key);

  @override
  Future<void> show({required String key, required String name}) async {
    final words = labels();
    try {
      final fullScreen = await _channel.invokeMethod<bool>('show', {
        'key': key,
        'name': name,
        'title': words.title,
        'answer': words.answer,
        'decline': words.decline,
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

  @override
  Future<void> show({required String key, required String name}) async {
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
