import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/transport/call_signal.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/platform_info.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/voice_playback_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../profile/data/call_routing_controller.dart';
import '../domain/call_record.dart';
import '../domain/call_rules.dart';
import '../domain/call_state_machine.dart';
import 'call_media.dart';
import 'turn_credentials_controller.dart';

typedef ReceivedCallSignal = ({String chatId, CallSignal signal});

class CallController extends ChangeNotifier {
  CallController({
    required Stream<ReceivedCallSignal> signals,
    required this.send,
    required this.obtainTurn,
    required this.microphone,
    required this.createMedia,
    required this.record,
    required this.peerName,
    required this.allowed,
    required this.allowDirect,
    required this.prepareAudio,
  }) {
    _machine =
        CallStateMachine(send: _send, onOutcome: _outcome, now: DateTime.now)
          ..addListener(_changed);
    _signals = signals.listen(_receive);
  }
  final Future<int> Function(String peer, CallSignal signal) send;
  final Future<TurnAccess> Function() obtainTurn;
  final Future<bool> Function() microphone;
  final CallMedia Function() createMedia;
  final void Function(String peer, CallOutcome outcome) record;
  final String Function(String peer) peerName;
  final bool Function(String peer) allowed;

  /// Read at the moment a connection is built, not captured at construction:
  /// the switch can change between two calls without restarting anything.
  /// False means relay only, and a relay that cannot be reached ends the call
  /// rather than quietly trying a direct path — see [dial].
  final bool Function() allowDirect;
  final Future<void> Function() prepareAudio;
  late final CallStateMachine _machine;
  late final StreamSubscription<ReceivedCallSignal> _signals;
  StreamSubscription<CallMediaEvent>? _mediaEvents;
  CallMedia? _media;
  Future<void> _released = Future<void>.value();
  Timer? _elapsedTimer;
  Timer? _disconnected;
  DateTime? _talkingSince;
  String? peerId;
  String? error;
  String? _remoteOffer;
  bool preparing = false;
  bool micMuted = false;
  bool speakerOn = false;
  bool _disposed = false;
  bool _connected = false;
  bool _changingMute = false;
  bool _changingSpeaker = false;
  int _generation = 0;
  Duration elapsed = Duration.zero;
  CallPhase get phase => _machine.phase;
  bool get active =>
      preparing || (phase != CallPhase.idle && phase != CallPhase.ended);
  String get name => peerId == null ? '' : peerName(peerId!);

  void _changed() {
    if (phase == CallPhase.talking && _elapsedTimer == null && !_disposed) {
      _talkingSince = DateTime.now();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed = DateTime.now().difference(_talkingSince!);
        if (!_disposed) notifyListeners();
      });
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _send(CallSignal signal) async {
    final peer = peerId;
    final generation = _generation;
    if (peer == null) return;
    try {
      final links = await send(peer, signal);
      if (links == 0 &&
          generation == _generation &&
          active &&
          signal.kind != CallSignalKind.hangup &&
          signal.kind != CallSignalKind.decline) {
        _fail('unavailable');
      }
    } catch (_) {
      if (generation == _generation && active) _fail('unavailable');
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> dial(String peer) async {
    if (active || !allowed(peer)) return;
    peerId = peer;
    error = null;
    preparing = true;
    micMuted = false;
    speakerOn = false;
    elapsed = Duration.zero;
    final generation = ++_generation;
    _changed();
    try {
      final media = await _prepare(generation);
      if (media == null) return;
      final access = await obtainTurn();
      if (!_current(generation)) return;
      final sdp =
          await media.offer(access.configuration(allowDirect: allowDirect()));
      if (!_current(generation)) return;
      preparing = false;
      final random = Random.secure();
      final id = Uint8List.fromList(
          List.generate(callIdLen, (_) => random.nextInt(256)));
      _machine.startOutgoing(callId: id, sdp: sdp);
    } on TurnUnavailable {
      if (_current(generation)) _fail('turn');
    } catch (_) {
      if (_current(generation)) _fail('media');
    }
  }

  Future<CallMedia?> _prepare(int generation) async {
    await _released;
    if (!_current(generation)) return null;
    if (!await microphone()) {
      if (_current(generation)) _fail('microphone');
      return null;
    }
    if (!_current(generation)) return null;
    await prepareAudio();
    if (!_current(generation)) return null;
    final media = _media = createMedia();
    _mediaEvents = media.events.listen((event) {
      if (!_current(generation)) return;
      if (event == CallMediaEvent.connected) {
        _connected = true;
        _disconnected?.cancel();
        _disconnected = null;
        _machine.mediaConnected();
      } else if (event == CallMediaEvent.failed) {
        _fail('media');
      } else {
        _connected = false;
        _disconnected ??=
            Timer(const Duration(seconds: 10), () => _fail('media'));
      }
    });
    return media;
  }

  void _receive(ReceivedCallSignal event) {
    if (_disposed || !allowed(event.chatId)) return;
    final signal = event.signal;
    if (signal.kind == CallSignalKind.invite) {
      if (!inviteIsFresh(sentAtMs: signal.sentAtMs!, now: DateTime.now()))
        return;
      if (active && (peerId != event.chatId || preparing)) {
        unawaited(send(event.chatId, CallSignal.busy(signal.callId))
            .catchError((Object _) => 0));
        return;
      }
      if (!active) {
        peerId = event.chatId;
        error = null;
        micMuted = false;
        speakerOn = false;
        elapsed = Duration.zero;
      }
      _machine.handleInvite(signal);
      if (phase == CallPhase.incoming &&
          listEquals(_machine.callId, signal.callId)) {
        _remoteOffer = signal.sdp;
      }
      return;
    }
    if (event.chatId != peerId || !listEquals(_machine.callId, signal.callId))
      return;
    final wasWaiting = phase == CallPhase.dialing || phase == CallPhase.ringing;
    _machine.handleSignal(signal);
    if (signal.kind == CallSignalKind.accept &&
        wasWaiting &&
        phase == CallPhase.connecting) {
      final generation = _generation;
      unawaited(_acceptRemote(signal.sdp!, generation));
    }
  }

  Future<void> _acceptRemote(String sdp, int generation) async {
    try {
      await _media?.accept(sdp);
    } catch (_) {
      if (_current(generation)) _fail('media');
    }
  }

  Future<void> answer() async {
    if (phase != CallPhase.incoming || preparing) return;
    preparing = true;
    final generation = ++_generation;
    _changed();
    try {
      final media = await _prepare(generation);
      if (media == null) return;
      final access = await obtainTurn();
      if (!_current(generation)) return;
      final sdp = await media.answer(
          access.configuration(allowDirect: allowDirect()), _remoteOffer!);
      if (!_current(generation)) return;
      preparing = false;
      _machine.accept(sdp: sdp);
      if (_connected) _machine.mediaConnected();
    } on TurnUnavailable {
      if (_current(generation)) _fail('turn');
    } catch (_) {
      if (_current(generation)) _fail('media');
    }
  }

  void _fail(String reason) {
    error = reason;
    preparing = false;
    if (phase != CallPhase.idle && phase != CallPhase.ended) {
      _machine.mediaFailed();
    } else {
      ++_generation;
      _release();
      _changed();
    }
  }

  void _outcome(CallOutcome outcome) {
    ++_generation;
    preparing = false;
    error ??= outcome.cause.name;
    if (outcome.cause == CallEndCause.glareLost) error = null;
    final peer = peerId;
    try {
      if (peer != null) record(peer, outcome);
    } catch (_) {
      DebugLog.instance.log('CALL', 'history write failed');
    }
    _release();
    _changed();
  }

  void _release() {
    _connected = false;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _disconnected?.cancel();
    _disconnected = null;
    final subscription = _mediaEvents;
    _mediaEvents = null;
    final media = _media;
    _media = null;
    final previous = _released;
    _released = (() async {
      await previous;
      await subscription?.cancel();
      try {
        await media?.close();
      } catch (_) {
        DebugLog.instance.log('CALL', 'audio cleanup failed');
      }
    })();
  }

  void decline() => _machine.decline();
  void hangUp() {
    if (phase == CallPhase.idle || phase == CallPhase.ended) {
      ++_generation;
      preparing = false;
      error = 'hungUp';
      _release();
      _changed();
    } else {
      _machine.hangUp();
    }
  }

  void dismiss() {
    if (active) return;
    peerId = null;
    error = null;
    _changed();
  }

  Future<void> toggleMute() async {
    if (phase != CallPhase.talking || _media == null || _changingMute) return;
    _changingMute = true;
    final generation = _generation;
    final next = !micMuted;
    try {
      await _media!.setMuted(next);
      if (!_current(generation)) return;
      micMuted = next;
      _changed();
    } catch (_) {
      if (_current(generation)) _fail('media');
    } finally {
      _changingMute = false;
    }
  }

  Future<void> toggleSpeaker() async {
    if (phase != CallPhase.talking || _media == null || _changingSpeaker) return;
    _changingSpeaker = true;
    final generation = _generation;
    final next = !speakerOn;
    try {
      await _media!.setSpeaker(next);
      if (!_current(generation)) return;
      speakerOn = next;
      _changed();
    } catch (_) {
      if (_current(generation)) _fail('media');
    } finally {
      _changingSpeaker = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_signals.cancel());
    _machine.dispose();
    _release();
    super.dispose();
  }
}

final callControllerProvider = ChangeNotifierProvider<CallController>((ref) {
  final messaging = ref.read(messagingServiceProvider);
  return CallController(
    signals: messaging.callSignals,
    send: (peer, signal) =>
        messaging.sendCallSignal(canonicalId: peer, signal: signal),
    obtainTurn: () => ref.read(turnCredentialsProvider).obtain(),
    microphone: () async =>
        PlatformInfo.isMobile &&
        (await Permission.microphone.request()).isGranted,
    createMedia: WebRtcCallMedia.new,
    prepareAudio: () =>
        ref.read(voicePlaybackControllerProvider.notifier).stop(),
    peerName: (peer) =>
        ref.read(knownPeersControllerProvider)[peer]?.displayName ??
        peer.substring(0, 8),
    allowDirect: () => ref.read(callAllowsDirectProvider),
    allowed: (peer) =>
        RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) &&
        ref.read(knownPeersControllerProvider)[peer] != null &&
        !ref.read(knownPeersControllerProvider)[peer]!.isBlocked,
    record: (peer, outcome) {
      final text = encodeCallRecord(outcome);
      if (text.isEmpty) return;
      final id = outcome.callId
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      ref.read(messagesControllerProvider.notifier).append(
          peer,
          Message(
            id: 'call-$id',
            wireId: 'call-$id',
            chatId: peer,
            text: text,
            sentAt: DateTime.now(),
            isMine: outcome.outgoing,
          ));
    },
  );
});
