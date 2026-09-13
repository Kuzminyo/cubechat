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

  /// One line per step of a call, under `[CALL]`.
  ///
  /// The first device test of calls failed with "could not connect the call"
  /// and two logs that did not contain a single line about it: every failure
  /// here was caught and reduced to a word, and the exception that said why was
  /// thrown away. Enough is written now that one attempt names the step it died
  /// on. Never the TURN password, never an SDP body — lengths and counts only.
  static void _log(String line) => DebugLog.instance.log('CALL', line);

  static String _short(String? peer) =>
      peer == null ? '?' : peer.substring(0, min(8, peer.length));

  static String _hex(Uint8List id) => id
      .take(4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  Future<void> _send(CallSignal signal) async {
    final peer = peerId;
    final generation = _generation;
    if (peer == null) return;
    try {
      final links = await send(peer, signal);
      _log('sent ${signal.kind.name} ${_hex(signal.callId)} to '
          '${_short(peer)}: $links link(s)');
      if (links == 0 &&
          generation == _generation &&
          active &&
          signal.kind != CallSignalKind.hangup &&
          signal.kind != CallSignalKind.decline) {
        _fail('unavailable');
      }
    } catch (e) {
      _log('sending ${signal.kind.name} failed: $e');
      if (generation == _generation && active) _fail('unavailable');
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> dial(String peer) async {
    if (active) {
      _log('dial ${_short(peer)} ignored: a call is already on');
      return;
    }
    if (!allowed(peer)) {
      _log('dial ${_short(peer)} refused: not a known, unblocked contact');
      return;
    }
    peerId = peer;
    error = null;
    preparing = true;
    micMuted = false;
    speakerOn = false;
    elapsed = Duration.zero;
    final generation = ++_generation;
    _changed();
    final watch = Stopwatch()..start();
    _log('dial ${_short(peer)}');
    try {
      final media = await _prepare(generation);
      if (media == null) return;
      final access = await obtainTurn();
      _log('relay access: ${access.urls.length} url(s), '
          '${access.expiresAt.difference(DateTime.now()).inSeconds} s left '
          '(${watch.elapsedMilliseconds} ms)');
      if (!_current(generation)) return;
      final direct = allowDirect();
      final sdp =
          await media.offer(access.configuration(allowDirect: direct));
      _log('offer ready: ${sdp.length} B, ${describeCandidates(sdp)}, '
          '${direct ? 'direct allowed' : 'relay only'} '
          '(${watch.elapsedMilliseconds} ms)');
      if (!_current(generation)) return;
      preparing = false;
      final random = Random.secure();
      final id = Uint8List.fromList(
          List.generate(callIdLen, (_) => random.nextInt(256)));
      _machine.startOutgoing(callId: id, sdp: sdp);
    } on TurnUnavailable catch (e) {
      _log('relay access refused: ${e.reason}');
      if (_current(generation)) _fail('turn');
    } catch (e) {
      _log('could not prepare the call after ${watch.elapsedMilliseconds} ms: '
          '$e');
      if (_current(generation)) _fail('media');
    }
  }

  /// How many candidates of each kind an SDP carries, e.g. `relay 1, host 0`.
  ///
  /// The call design depends on exactly one relay candidate being in the
  /// offer, so this is the single most useful fact about an SDP to have in a
  /// log — and it says nothing about anybody's address.
  static String describeCandidates(String sdp) {
    final counts = <String, int>{};
    for (final m in RegExp(r' typ (host|srflx|prflx|relay)\b').allMatches(sdp)) {
      counts.update(m.group(1)!, (n) => n + 1, ifAbsent: () => 1);
    }
    return 'relay ${counts['relay'] ?? 0}, srflx ${counts['srflx'] ?? 0}, '
        'host ${counts['host'] ?? 0}';
  }

  Future<CallMedia?> _prepare(int generation) async {
    await _released;
    if (!_current(generation)) return null;
    if (!await microphone()) {
      _log('microphone refused');
      if (_current(generation)) _fail('microphone');
      return null;
    }
    if (!_current(generation)) return null;
    await prepareAudio();
    if (!_current(generation)) return null;
    final media = _media = createMedia();
    _mediaEvents = media.events.listen((event) {
      if (!_current(generation)) return;
      _log('media ${event.name}');
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
    if (_disposed) return;
    final signal = event.signal;
    _log('received ${signal.kind.name} ${_hex(signal.callId)} from '
        '${_short(event.chatId)}');
    if (!allowed(event.chatId)) {
      _log('ignored: ${_short(event.chatId)} is not a known, unblocked contact');
      return;
    }
    if (signal.kind == CallSignalKind.invite) {
      if (!inviteIsFresh(sentAtMs: signal.sentAtMs!, now: DateTime.now())) {
        _log('invite dropped as stale: sent '
            '${DateTime.now().millisecondsSinceEpoch - signal.sentAtMs!} ms ago');
        return;
      }
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
    _log('answer received: ${sdp.length} B, ${describeCandidates(sdp)}');
    try {
      await _media?.accept(sdp);
    } catch (e) {
      _log('could not apply the answer: $e');
      if (_current(generation)) _fail('media');
    }
  }

  Future<void> answer() async {
    if (phase != CallPhase.incoming || preparing) return;
    preparing = true;
    final generation = ++_generation;
    _changed();
    final watch = Stopwatch()..start();
    _log('answering ${_short(peerId)}: offer ${_remoteOffer?.length ?? 0} B, '
        '${describeCandidates(_remoteOffer ?? '')}');
    try {
      final media = await _prepare(generation);
      if (media == null) return;
      final access = await obtainTurn();
      _log('relay access: ${access.urls.length} url(s) '
          '(${watch.elapsedMilliseconds} ms)');
      if (!_current(generation)) return;
      final sdp = await media.answer(
          access.configuration(allowDirect: allowDirect()), _remoteOffer!);
      _log('answer ready: ${sdp.length} B, ${describeCandidates(sdp)} '
          '(${watch.elapsedMilliseconds} ms)');
      if (!_current(generation)) return;
      preparing = false;
      _machine.accept(sdp: sdp);
      if (_connected) _machine.mediaConnected();
    } on TurnUnavailable catch (e) {
      _log('relay access refused: ${e.reason}');
      if (_current(generation)) _fail('turn');
    } catch (e) {
      _log('could not answer after ${watch.elapsedMilliseconds} ms: $e');
      if (_current(generation)) _fail('media');
    }
  }

  void _fail(String reason) {
    _log('failed: $reason (phase ${phase.name})');
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
    _log('ended ${_hex(outcome.callId)}: ${outcome.cause.name}, '
        '${outcome.outgoing ? 'outgoing' : 'incoming'}, '
        'talked ${outcome.talkedFor.inSeconds} s');
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
