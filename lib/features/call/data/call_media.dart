import 'dart:async';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/util/debug_log.dart';
import 'call_candidate_wait.dart';
import '../domain/call_network_quality.dart';

enum CallMediaEvent { connected, disconnected, failed }

/// Where a call's sound comes out.
enum CallAudioRouteKind { earpiece, speaker, bluetooth, wired }

/// One place the sound can go, as the platform names it.
class CallAudioRoute {
  const CallAudioRoute({
    required this.id,
    required this.label,
    required this.kind,
  });

  /// What the platform wants back to select it.
  final String id;

  /// The device's own name - "Pixel Buds", "AirPods Pro" - when it has one.
  final String label;
  final CallAudioRouteKind kind;
}

abstract interface class CallMedia {
  Stream<CallMediaEvent> get events;
  Future<String> offer(Map<String, dynamic> configuration);
  Future<String> answer(Map<String, dynamic> configuration, String remoteSdp);
  Future<void> accept(String remoteSdp);
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool speaker);

  /// Every place the sound can go right now: the earpiece, the loudspeaker, a
  /// wired headset, a Bluetooth one.
  Future<List<CallAudioRoute>> routes();

  Future<void> selectRoute(CallAudioRoute route);
  Future<void> close();
}

class WebRtcCallMedia implements CallMedia {
  final _events = StreamController<CallMediaEvent>.broadcast();

  /// Muted before there was a microphone to mute - the person being called
  /// pressed it while the call still rang. Applied to the track as it opens.
  bool _muted = false;
  RTCPeerConnection? _peer;
  MediaStream? _local;
  Future<String>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  final _quality = CallNetworkQuality();
  Timer? _qualityTimer;
  Future<void>? _qualityWork;
  int? _appliedBitrate;
  int _qualityTicks = 0;
  bool _qualityErrorLogged = false;
  final Map<String, num> _remoteReports = {};
  final _gathered = Completer<void>();
  final _relayReady = Completer<void>();

  @override
  Stream<CallMediaEvent> get events => _events.stream;

  @override
  Future<String> offer(Map<String, dynamic> configuration) =>
      _opening = _open(configuration, null);

  @override
  Future<String> answer(Map<String, dynamic> configuration, String remoteSdp) =>
      _opening = _open(configuration, remoteSdp);

  void _checkOpen() {
    if (_closed) throw StateError('call closed');
  }

  static void _log(String line) => DebugLog.instance.log('CALL', line);

  Future<String> _open(
      Map<String, dynamic> configuration, String? remote) async {
    _checkOpen();
    final watch = Stopwatch()..start();
    // Gathered once, said out loud rather than left to the platform default.
    // Nothing trickles candidates here — the whole SDP goes in one frame — so
    // this waits for gathering to finish, and a policy that gathers
    // continually never finishes: the offer would time out every time, before
    // an invite ever left. Android's default happens to be once today; the
    // design should not rest on a default nobody chose.
    final config = <String, dynamic>{
      ...configuration,
      'continualGatheringPolicy': 'gather_once',
    };
    final peer = _peer = await createPeerConnection(config);
    _checkOpen();
    peer.onIceCandidate = (candidate) {
      // Both test phones timed out at 12 s waiting for every network
      // interface. A usable relay route is sufficient for a complete SDP
      // snapshot; dead interfaces must not hold back a working route.
      if (candidate.candidate?.contains(' typ relay') ?? false) {
        _log('usable relay candidate (${watch.elapsedMilliseconds} ms)');
        if (!_relayReady.isCompleted) _relayReady.complete();
      }
    };
    peer.onIceGatheringState = (state) {
      _log('gathering ${state.name} (${watch.elapsedMilliseconds} ms)');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !_gathered.isCompleted) {
        _gathered.complete();
      }
    };
    peer.onIceConnectionState =
        (state) => _log('ice ${state.name} (${watch.elapsedMilliseconds} ms)');
    peer.onConnectionState = (state) {
      _log('connection ${state.name} (${watch.elapsedMilliseconds} ms)');
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _startQualityMonitor();
          _events.add(CallMediaEvent.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _events.add(CallMediaEvent.disconnected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _events.add(CallMediaEvent.failed);
        default:
          break;
      }
    };
    // Configure communication before capture activates the native audio
    // session. Bluetooth must open as a bidirectional voice route.
    if (Platform.isAndroid) {
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.communication,
      );
    } else if (Platform.isIOS) {
      await _configureAppleAudio();
    }
    _checkOpen();
    final local = _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        // flutter_webrtc 0.12's native parser ignores top-level browser
        // constraints. Supply its optional list so AGC/NS/AEC actually reach
        // the audio source, including a quiet Bluetooth headset microphone.
        'optional': [
          {'googEchoCancellation': true},
          {'googNoiseSuppression': true},
          {'googAutoGainControl': true},
        ],
      },
      'video': false,
    });
    _checkOpen();
    if (_muted) {
      for (final track in local.getAudioTracks()) {
        await Helper.setMicrophoneMute(true, track);
      }
    }
    await setSpeaker(false);
    for (final track in local.getAudioTracks()) {
      await peer.addTrack(track, local);
      _checkOpen();
    }
    if (remote != null)
      await peer.setRemoteDescription(RTCSessionDescription(remote, 'offer'));
    _checkOpen();
    final description =
        remote == null ? await peer.createOffer() : await peer.createAnswer();
    await peer.setLocalDescription(description);
    _log('microphone open, local description set '
        '(${watch.elapsedMilliseconds} ms)');
    // The wire carries a complete SDP, without candidate trickling. Never
    // invite a peer with an offer which cannot reach our required TURN relay.
    try {
      await waitForCallCandidates(
        gathered: _gathered.future,
        relayReady: _relayReady.future,
      );
    } on TimeoutException {
      // Named, because this is the failure that ends a call before anybody is
      // rung, and "TimeoutException after 0:00:12" says nothing about which
      // wait it was.
      throw StateError('candidate gathering did not finish in 12 s');
    }
    _checkOpen();
    final sdp = (await peer.getLocalDescription())?.sdp;
    if (sdp == null || !sdp.contains('a=candidate:')) {
      throw StateError('gathering finished with no candidates at all — '
          'the relay did not answer');
    }
    if (configuration['iceTransportPolicy'] == 'relay' &&
        !sdp.contains(' typ relay')) {
      throw StateError('gathering finished with no relay candidate — the '
          'relay refused this phone\'s credentials or could not be reached');
    }
    return sdp;
  }

  @override
  Future<void> accept(String remoteSdp) async {
    _checkOpen();
    await _peer!
        .setRemoteDescription(RTCSessionDescription(remoteSdp, 'answer'));
  }

  @override
  Future<void> setMuted(bool muted) async {
    _checkOpen();
    _muted = muted;
    for (final track in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      await Helper.setMicrophoneMute(muted, track);
    }
  }

  /// On or off, and actually applied either way.
  ///
  /// **"Speaker on and normal sound exactly the same" was the report, and on
  /// Android it was true.** flutter_webrtc's audio switch ranks the loudspeaker
  /// above the earpiece in its default preference list, so every call started
  /// on the loudspeaker while the button said it was off - pressing it turned
  /// on what was already on. Nothing ever asked for the earpiece. The call now
  /// states its route when the microphone opens and again when media connects,
  /// so the button and the sound agree from the first second. Off still
  /// prefers a headset over the earpiece when one is connected.
  @override
  Future<void> setSpeaker(bool speaker) async {
    _checkOpen();
    if (Platform.isIOS) {
      // The plugin's setSpeakerphoneOn helper re-enables A2DP. Keep the
      // bidirectional HFP voice category and change only the output override.
      await _configureAppleAudio();
      if (!_closed)
        await Helper.selectAudioOutput(speaker ? 'Speaker' : 'none');
    } else {
      await Helper.setSpeakerphoneOn(speaker);
    }
  }

  Future<void> _configureAppleAudio() =>
      Helper.setAppleAudioConfiguration(AppleAudioConfiguration(
        appleAudioCategory: AppleAudioCategory.playAndRecord,
        appleAudioMode: AppleAudioMode.voiceChat,
        appleAudioCategoryOptions: {AppleAudioCategoryOption.allowBluetooth},
      ));

  void _startQualityMonitor() {
    if (_qualityTimer != null || _closed) return;
    void poll() {
      if (_closed || _qualityWork != null) return;
      _qualityWork = _sampleQuality().whenComplete(() => _qualityWork = null);
    }

    _qualityTimer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    poll();
  }

  Future<void> _sampleQuality() async {
    final peer = _peer;
    if (_closed || peer == null) return;
    try {
      final reports = await peer.getStats().timeout(const Duration(seconds: 2));
      if (_closed) return;
      var freshReport = false;
      double? loss;
      double? rtt;
      for (final report in reports) {
        final values = report.values;
        // Remote inbound describes how the OTHER phone receives OUR audio.
        // Local inbound loss is the opposite direction and cannot be fixed by
        // reducing our encoder's bandwidth.
        if (report.type != 'remote-inbound-rtp' ||
            (values['kind'] ?? values['mediaType']) != 'audio') continue;
        final counter =
            values['reportsReceived'] ?? values['roundTripTimeMeasurements'];
        final marker = counter is num ? counter : report.timestamp;
        if (_remoteReports[report.id] == marker) continue;
        _remoteReports[report.id] = marker;
        freshReport = true;
        final fraction = values['fractionLost'];
        final roundTrip = values['roundTripTime'];
        if (fraction is num) loss = fraction.toDouble();
        if (roundTrip is num) rtt = roundTrip.toDouble();
      }
      // RTCP often arrives less frequently than getStats is polled. Count
      // actual feedback, not polling gaps, toward sustained recovery.
      if (freshReport) _quality.sample(loss: loss, rtt: rtt);
      final target = _quality.bitrate;
      final changed = _appliedBitrate != target;
      if (changed) {
        // Fetch fresh parameters: a cached addTrack sender can precede SDP
        // negotiation and have no negotiated encodings yet.
        final senders =
            await peer.getSenders().timeout(const Duration(seconds: 2));
        if (_closed) return;
        var applied = false;
        for (final sender in senders) {
          if (sender.track?.kind != 'audio') continue;
          final parameters = sender.parameters;
          final encodings = parameters.encodings;
          if (encodings == null || encodings.isEmpty) continue;
          for (final encoding in encodings) {
            encoding.maxBitrate = target;
          }
          if (!await sender
              .setParameters(parameters)
              .timeout(const Duration(seconds: 2))) {
            throw StateError('audio sender refused bitrate');
          }
          if (_closed) return;
          applied = true;
        }
        if (applied) _appliedBitrate = target;
      }
      // One line every 15 seconds, plus real policy changes. Never log SDP,
      // addresses or captured speech; just the measurements needed to debug.
      if (++_qualityTicks % 5 == 0 || changed && _appliedBitrate == target) {
        _log('audio quality: cap ${_appliedBitrate ?? 0} bps, '
            'loss ${loss == null ? "unknown" : (loss * 100).toStringAsFixed(1)}%, '
            'rtt ${rtt == null ? "unknown" : (rtt * 1000).round()} ms');
      }
      _qualityErrorLogged = false;
    } catch (e) {
      if (!_closed && !_qualityErrorLogged) {
        _log('audio quality update unavailable: $e');
        _qualityErrorLogged = true;
      }
      // A platform that cannot set a cap retains WebRTC's own congestion
      // control. Monitoring must never tear down an otherwise usable call.
    }
  }

  @override
  Future<List<CallAudioRoute>> routes() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      if (Platform.isAndroid) return _androidRoutes(devices);
      if (Platform.isIOS) return _iosRoutes(devices);
    } catch (e) {
      _log('could not list audio routes: $e');
    }
    return const [];
  }

  /// Android names its outputs by kind: `earpiece`, `speaker`, `wired-headset`,
  /// `bluetooth` - and selecting one is selecting that name.
  static List<CallAudioRoute> _androidRoutes(List<MediaDeviceInfo> devices) {
    final routes = <CallAudioRoute>[];
    for (final device in devices.where((d) => d.kind == 'audiooutput')) {
      final kind = switch (device.deviceId) {
        'earpiece' => CallAudioRouteKind.earpiece,
        'speaker' => CallAudioRouteKind.speaker,
        'wired-headset' => CallAudioRouteKind.wired,
        'bluetooth' => CallAudioRouteKind.bluetooth,
        _ => null,
      };
      if (kind == null) continue;
      routes.add(CallAudioRoute(
        id: device.deviceId,
        label: device.label,
        kind: kind,
      ));
    }
    return routes;
  }

  /// iOS has no list of outputs to pick from, only inputs, and the output
  /// follows the input: choosing a headset's microphone routes the call to that
  /// headset. The loudspeaker is the one output that is chosen directly.
  static List<CallAudioRoute> _iosRoutes(List<MediaDeviceInfo> devices) {
    final routes = <CallAudioRoute>[];
    for (final device in devices.where((d) => d.kind == 'audioinput')) {
      final kind = switch (device.groupId) {
        'MicrophoneBuiltIn' => CallAudioRouteKind.earpiece,
        'BluetoothHFP' => CallAudioRouteKind.bluetooth,
        'HeadsetMic' || 'USBAudio' => CallAudioRouteKind.wired,
        _ => null,
      };
      if (kind == null) continue;
      routes.add(CallAudioRoute(
        id: device.deviceId,
        label: device.label,
        kind: kind,
      ));
    }
    routes.add(const CallAudioRoute(
      id: 'Speaker',
      label: 'Speaker',
      kind: CallAudioRouteKind.speaker,
    ));
    return routes;
  }

  @override
  Future<void> selectRoute(CallAudioRoute route) async {
    _checkOpen();
    if (Platform.isAndroid) {
      await Helper.selectAudioOutput(route.id);
      return;
    }
    if (route.kind == CallAudioRouteKind.speaker) {
      await Helper.selectAudioOutput('Speaker');
      return;
    }
    // Loudspeaker override off first, or the chosen headset stays silent
    // behind it.
    await Helper.selectAudioOutput('none');
    await Helper.selectAudioInput(route.id);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _qualityTimer?.cancel();
    _qualityTimer = null;
    if (!_gathered.isCompleted) _gathered.complete();
    // Native camera/audio creation cannot be disposed underneath its pending
    // future. The controller prevents a new call until this teardown ends.
    try {
      await _opening;
    } catch (_) {/* Cancelled setup still needs cleanup. */}
    try {
      await _qualityWork;
      await _peer?.close();
      await _peer?.dispose();
    } finally {
      try {
        for (final track in _local?.getTracks() ?? <MediaStreamTrack>[]) {
          await track.stop();
        }
        await _local?.dispose();
      } finally {
        _peer = null;
        _local = null;
        await _events.close();
      }
    }
  }
}
