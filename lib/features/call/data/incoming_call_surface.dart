import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/util/debug_log.dart';

enum IncomingCallActionKind { answer, decline }

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

  Future<void> show({required String key, required String name});

  /// Take it down. [key] names the call, so an older call's late dismiss
  /// cannot take down a newer one; null takes down whatever is showing.
  Future<void> dismiss(String? key);
}

/// For tests, desktop, and iOS until CallKit exists there.
class NoIncomingCallSurface implements IncomingCallSurface {
  const NoIncomingCallSurface();

  @override
  Stream<IncomingCallAction> get actions => const Stream.empty();

  @override
  Future<void> show({required String key, required String name}) async {}

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
      _ => null,
    };
    if (kind == null) return;
    _actions.add((kind: kind, key: key));
  }
}
