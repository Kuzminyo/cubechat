import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/transport/call_signal.dart';
import '../../../core/transport/control_delivery.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/locale/locale_controller.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/platform_info.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/voice_playback_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../profile/data/call_routing_controller.dart';
import '../domain/call_record.dart';
import '../domain/call_rules.dart';
import '../domain/call_state_machine.dart';
import 'call_media.dart';
import 'call_tones.dart';
import 'incoming_call_surface.dart';
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
    this.tones = const SilentCallTones(),
    this.surface = const NoIncomingCallSurface(),
    bool Function()? foreground,
  }) : _foreground = foreground ?? _alwaysForeground {
    _machine =
        CallStateMachine(send: _send, onOutcome: _outcome, now: DateTime.now)
          ..addListener(_changed);
    _signals = signals.listen(_receive);
    _surfaceActions = surface.actions.listen(_onSurfaceAction);
  }

  /// Puts one signal on the wire and says what is known about it afterwards.
  ///
  /// Not a link count any more: zero links used to mean both "nothing left
  /// this phone" and "seven relays took it and none answered in time", and the
  /// second one is how a ringing call was hung up. See [DeliveryCertainty].
  final Future<ControlDelivery> Function(String peer, CallSignal signal) send;
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
  final CallTones tones;

  /// The phone's own incoming-call screen, for while the app is not on screen.
  final IncomingCallSurface surface;
  late final CallStateMachine _machine;
  late final StreamSubscription<ReceivedCallSignal> _signals;
  late final StreamSubscription<IncomingCallAction> _surfaceActions;

  /// Whether the app is on screen, asked at the moment it matters.
  ///
  /// Decides where a ringing call is shown: on the app's own call screen with
  /// its tone, or on the phone's, with the system ringtone. Never both — two
  /// ringtones at once is the one thing worse than none.
  ///
  /// A question rather than a flag kept from lifecycle callbacks, because on
  /// Android the engine starts headless and a transition can go unseen — see
  /// `AppLifecycle.isForeground` for the phone that stayed "offline" all day
  /// that way. [noteLifecycle] only says when to ask again.
  final bool Function() _foreground;
  static bool _alwaysForeground() => true;

  /// The call the phone's own screen is showing, by [_key].
  String? _surfaceKey;
  Future<void> _surfaceWork = Future<void>.value();
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
  CallTone? _tone;
  Future<void> _toneWork = Future<void>.value();

  /// Calls already over that have been answered with a hangup once, so a
  /// ringing or accept that keeps arriving for one is not answered forever.
  final Set<String> _staleReplies = {};
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
    _updateRinging();
    if (!_disposed) notifyListeners();
  }

  /// Ring while this phone is being called and nobody has touched Answer —
  /// in the app when it is on screen, on the phone's own call screen when not.
  ///
  /// Driven off the phase rather than from each place a call starts or stops,
  /// because a call stops ringing in seven ways — answered, declined, the
  /// caller hanging up, the timer, a glare, a dispose, the app closing — and a
  /// ringtone left running by the seventh is worse than no ringtone.
  void _updateRinging() {
    final ringing = !_disposed && phase == CallPhase.incoming && !preparing;
    final id = _machine.callId;
    final onScreen = ringing && _foreground();
    _updateTone(ringing && onScreen ? CallTone.incoming : null);
    _updateSurface(ringing && !onScreen && id != null ? _key(id) : null);
  }

  void _updateTone(CallTone? wanted) {
    if (wanted == _tone) return;
    _tone = wanted;
    final previous = _toneWork;
    _toneWork = (() async {
      await previous;
      try {
        if (wanted == null) {
          await tones.stop();
        } else {
          await tones.play(wanted);
        }
      } catch (e) {
        _log('ringtone: $e');
      }
    })();
  }

  void _updateSurface(String? wanted) {
    if (wanted == _surfaceKey) return;
    final shown = _surfaceKey;
    _surfaceKey = wanted;
    final caller = name;
    final previous = _surfaceWork;
    _surfaceWork = (() async {
      await previous;
      try {
        if (wanted == null) {
          await surface.dismiss(shown);
        } else {
          await surface.show(key: wanted, name: caller);
        }
      } catch (e) {
        _log('incoming-call screen: $e');
      }
    })();
  }

  static String _key(Uint8List callId) =>
      callId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Answer or Decline pressed on the phone's own incoming-call screen.
  ///
  /// Checked against the call that is ringing now, because the button can be
  /// pressed on a screen that outlived its call by a moment — the caller gave
  /// up while a finger was on the way.
  void _onSurfaceAction(IncomingCallAction action) {
    final id = _machine.callId;
    if (_disposed ||
        id == null ||
        _key(id) != action.key ||
        phase != CallPhase.incoming) {
      _log('${action.kind.name} on the phone\'s call screen ignored: '
          'that call is no longer ringing');
      unawaited(surface.dismiss(action.key));
      return;
    }
    _log('${action.kind.name} pressed on the phone\'s call screen');
    switch (action.kind) {
      case IncomingCallActionKind.answer:
        unawaited(answer());
      case IncomingCallActionKind.decline:
        decline();
    }
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
    ControlDelivery delivery;
    try {
      delivery = await send(peer, signal);
    } catch (e) {
      // Thrown while sealing or before any transport took it, so nothing left.
      _log('sending ${signal.kind.name} ${_hex(signal.callId)} failed: $e');
      delivery = ControlDelivery.notSent;
    }
    final ends = _undeliverableEndsCall(signal, delivery, generation, peer);
    _log('sent ${signal.kind.name} ${_hex(signal.callId)} to '
        '${_short(peer)}: $delivery${_sendNote(signal, delivery, ends)}');
    if (ends) _fail('unavailable', source: CallEndSource.transport);
  }

  /// Whether a send that went nowhere ends the call it belongs to.
  ///
  /// **Only a send that went nowhere.** An unconfirmed one is a relay being
  /// quiet, and callId 9ba4922a is what treating that as failure costs: the
  /// other phone received the invite in 290 ms and was ringing, the caller
  /// heard no `OK` inside two seconds, filed the call unavailable and hung up
  /// on it — then received the ringing acknowledgement a second later. The
  /// call deadlines already bound how long silence is waited out.
  ///
  /// **And only while the call is still at the step that send was for.** The
  /// result of a publish arrives up to two seconds after it started, and a lot
  /// happens in two seconds: the acknowledgement, the answer, the media. A late
  /// verdict on the invite must not end a call that has since rung, connected
  /// or started talking — so the generation, the call id and the phase all
  /// have to still be the ones the send was made in.
  bool _undeliverableEndsCall(
    CallSignal signal,
    ControlDelivery delivery,
    int generation,
    String peer,
  ) {
    if (!delivery.isNotSent) return false;
    if (!_current(generation) || peerId != peer) return false;
    if (!listEquals(_machine.callId, signal.callId)) return false;
    return switch (signal.kind) {
      // Nobody else can hear about this call: nothing is waiting to answer.
      CallSignalKind.invite => phase == CallPhase.dialing,
      // The caller will never get the answer, and this side would sit in
      // `connecting` for thirty seconds finding that out.
      CallSignalKind.accept => phase == CallPhase.connecting,
      // A lost ringing acknowledgement is the caller's deadline to judge, and
      // the answer can still reach them. A hangup, decline or busy has
      // already ended the call here.
      CallSignalKind.ringing ||
      CallSignalKind.hangup ||
      CallSignalKind.decline ||
      CallSignalKind.busy =>
        false,
    };
  }

  static String _sendNote(
    CallSignal signal,
    ControlDelivery delivery,
    bool ends,
  ) {
    if (ends) return ' — nothing left the phone, ending the call';
    if (delivery.certainty == DeliveryCertainty.unconfirmed &&
        signal.kind == CallSignalKind.invite) {
      return ' — waiting up to ${CallTimings.ringingAck.inSeconds} s '
          'for their acknowledgement';
    }
    if (delivery.isNotSent) return ' — the call is past this step, not ended';
    return '';
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
    // The ringtone gives the audio session back before the microphone asks
    // for it. Bounded, because a plugin that never answers must not be able
    // to stop a call from being answered.
    await Future.wait([_toneWork, _surfaceWork])
        .timeout(const Duration(seconds: 1), onTimeout: () => const []);
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
        _disconnected ??= Timer(const Duration(seconds: 10), () {
          _log('media stayed disconnected for 10 s');
          _fail('media');
        });
      }
    });
    return media;
  }

  void _receive(ReceivedCallSignal event) {
    if (_disposed) return;
    final signal = event.signal;
    final reason = signal.reason;
    _log('received ${signal.kind.name} ${_hex(signal.callId)} from '
        '${_short(event.chatId)}${reason == null ? '' : ' (reason ${reason.name})'}');
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
      // Before the busy reply below: an invite for a call that is already
      // over is not a call to be busy for.
      if (_machine.hasEnded(signal.callId)) {
        _log('invite ${_hex(signal.callId)} dropped: that call is already over');
        return;
      }
      if (active && (peerId != event.chatId || preparing)) {
        unawaited(send(event.chatId, CallSignal.busy(signal.callId))
            .catchError((Object _) => ControlDelivery.notSent));
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
    if (event.chatId != peerId ||
        !listEquals(_machine.callId, signal.callId) ||
        !_machine.isLive) {
      _settleStale(event.chatId, signal);
      return;
    }
    final wasWaiting = phase == CallPhase.dialing || phase == CallPhase.ringing;
    _machine.handleSignal(signal);
    if (signal.kind == CallSignalKind.accept &&
        wasWaiting &&
        phase == CallPhase.connecting) {
      final generation = _generation;
      unawaited(_acceptRemote(signal.sdp!, generation));
    }
  }

  /// A signal for a call that is not running here.
  ///
  /// Two cases are worth acting on, and both are a call that would otherwise
  /// ring or wait for nobody.
  ///
  /// A hangup, decline or busy that arrives *before* its own invite — a relay
  /// hands stored events over newest first — is remembered, so the invite that
  /// follows is dropped instead of ringing for forty-five seconds.
  ///
  /// A ringing or accept for a call already over here means the other phone
  /// never got our hangup. It is told again, once per call.
  void _settleStale(String chatId, CallSignal signal) {
    final id = signal.callId;
    switch (signal.kind) {
      case CallSignalKind.hangup:
      case CallSignalKind.decline:
      case CallSignalKind.busy:
        if (_machine.hasEnded(id)) return;
        _machine.rememberEnded(id);
        _log('${signal.kind.name} ${_hex(id)} names no call here — remembered, '
            'so its invite cannot ring later');
      case CallSignalKind.ringing:
      case CallSignalKind.accept:
        if (!_machine.hasEnded(id)) return;
        final key = _key(id);
        if (_staleReplies.length > 64) _staleReplies.clear();
        if (!_staleReplies.add(key)) return;
        _log('${signal.kind.name} ${_hex(id)} is for a call already over — '
            'telling ${_short(chatId)} to stop');
        unawaited(
          send(
            chatId,
            CallSignal.hangup(callId: id, reason: CallEndReason.hungUp),
          ).then(
            (delivery) => _log('sent hangup ${_hex(id)} to ${_short(chatId)}: '
                '$delivery'),
            onError: (Object e) =>
                _log('sending hangup ${_hex(id)} failed: $e'),
          ),
        );
      case CallSignalKind.invite:
        return;
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

  void _fail(String reason, {CallEndSource source = CallEndSource.media}) {
    _log('failed: $reason (phase ${phase.name}, ${source.name})');
    error = reason;
    preparing = false;
    if (_machine.isLive) {
      if (source == CallEndSource.transport) {
        _machine.signallingFailed();
      } else {
        _machine.mediaFailed(source: source);
      }
    } else {
      ++_generation;
      _release();
      _changed();
    }
  }

  void _outcome(CallOutcome outcome) {
    final theirs = outcome.remoteReason;
    _log('ended ${_hex(outcome.callId)}: ${outcome.cause.name}, '
        '${outcome.outgoing ? 'outgoing' : 'incoming'}, '
        'talked ${outcome.talkedFor.inSeconds} s, by ${outcome.source.name}'
        '${theirs == null ? '' : ' (their reason ${theirs.name})'}');
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

  void decline({CallEndSource source = CallEndSource.button}) =>
      _machine.decline(source: source);

  void hangUp({CallEndSource source = CallEndSource.button}) {
    if (phase == CallPhase.idle || phase == CallPhase.ended) {
      if (preparing) {
        _log('cancelled while preparing, by ${source.name}');
      }
      ++_generation;
      preparing = false;
      error = 'hungUp';
      _release();
      _changed();
    } else {
      _machine.hangUp(source: source);
    }
  }

  /// The app moved between foreground, background and closing mid-call.
  ///
  /// Logged because a call that ends while the app is in the background reads
  /// in the log exactly like one that ends by a finger, and only one of them
  /// is a bug. Closing is the one state that also ends the call: the process is
  /// going, and the other phone should stop ringing now rather than when its
  /// own timer runs out.
  ///
  /// It also moves a ringing call between the two screens that can show it.
  void noteLifecycle(AppLifecycleState state) {
    if (!active) return;
    _log('app ${state.name} during ${preparing ? 'preparing' : phase.name}');
    if (state == AppLifecycleState.detached) {
      hangUp(source: CallEndSource.lifecycle);
      return;
    }
    _changed();
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
    // Flagged first, so the outcome below does not notify listeners that are
    // being torn down with this.
    _disposed = true;
    // A call still on when the controller goes is a call the other phone is
    // still in. It used to be dropped without a word — no hangup, no outcome,
    // no line in the log — and the other side rang or talked to nobody until
    // its own deadline.
    if (_machine.isLive) {
      _log('controller disposed during ${phase.name}');
      _machine.hangUp(source: CallEndSource.dispose);
    }
    ++_generation;
    _updateRinging();
    unawaited(_signals.cancel());
    unawaited(_surfaceActions.cancel());
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
    tones: AudioCallTones(),
    // Android only for now. iOS draws an incoming call over the lock screen
    // through CallKit alone, and CallKit needs a VoIP push to reach an app
    // that is not running — a server path and a native side that do not exist
    // yet. Until they do, iOS keeps ringing inside the app.
    surface: PlatformInfo.isAndroid
        ? AndroidIncomingCallSurface(
            labels: () {
              final t = lookupAppLocalizations(ref.read(localeControllerProvider));
              return (
                title: t.previewCallIncoming,
                answer: t.callAnswer,
                decline: t.callDecline,
              );
            },
          )
        : const NoIncomingCallSurface(),
    // The framework's own lifecycle, which it updates before any observer is
    // told. `inactive` counts as on screen: it is the notification shade or a
    // permission dialog passing over the app, and the app is still what the
    // person is looking at. Null — the engine pre-warmed with no Activity —
    // is not on screen.
    foreground: () => switch (WidgetsBinding.instance.lifecycleState) {
          AppLifecycleState.resumed || AppLifecycleState.inactive => true,
          _ => false,
        },
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
