import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../core/transport/own_device_notice.dart';
import '../../../core/util/debug_log.dart';
import 'device_identity.dart';

/// Another device of this account, as it last described itself.
@immutable
class OwnDevice {
  const OwnDevice({
    required this.idHex,
    required this.name,
    required this.platform,
    required this.lastSeen,
    this.leaving = false,
  });

  final String idHex;
  final String name;
  final DevicePlatform platform;

  /// The latest moment it said hello — from inside the notice, never from
  /// when a relay happened to hand it over.
  final DateTime lastSeen;

  /// Told to sign out; it goes from the list when its goodbye comes.
  final bool leaving;

  OwnDevice copyWith({
    String? name,
    DevicePlatform? platform,
    DateTime? lastSeen,
    bool? leaving,
  }) =>
      OwnDevice(
        idHex: idHex,
        name: name ?? this.name,
        platform: platform ?? this.platform,
        lastSeen: lastSeen ?? this.lastSeen,
        leaving: leaving ?? this.leaving,
      );

  Map<String, Object> toJson() => {
        'id': idHex,
        'name': name,
        'p': platform.tag,
        'seen': lastSeen.millisecondsSinceEpoch,
        if (leaving) 'leaving': true,
      };

  static OwnDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final seen = raw['seen'];
    if (id is! String || id.length != 32 || name is! String || seen is! int) {
      return null;
    }
    final p = raw['p'];
    return OwnDevice(
      idHex: id,
      name: name,
      platform: DevicePlatform.fromByte(p is int ? p : 0),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(seen, isUtc: true),
      leaving: raw['leaving'] == true,
    );
  }
}

/// The devices of this account, and signing one out — "как в gmail"
/// (2026-10-12, docs/superpowers/specs/2026-10-12-own-devices-design.md).
///
/// Everything it needs arrives through the constructor, so the whole of it
/// runs in a test with no relay, no Hive and no secure store.
class OwnDevicesService extends ChangeNotifier {
  OwnDevicesService({
    required this.send,
    required Stream<OwnDeviceNotice> inbound,
    required this.store,
    required this.load,
    required this.save,
    required this.platform,
    required this.defaultName,
    DateTime Function()? now,
  })  : _inbound = inbound,
        _now = now ?? DateTime.now;

  final Future<void> Function(OwnDeviceNotice notice) send;
  final Stream<OwnDeviceNotice> _inbound;
  final DeviceIdentityStore store;
  final Future<List<OwnDevice>> Function() load;
  final Future<void> Function(List<OwnDevice> devices) save;
  final DevicePlatform platform;
  final String defaultName;
  final DateTime Function() _now;

  /// How often a device says hello again while it is open.
  static const Duration helloEvery = Duration(hours: 6);

  /// A device silent this long is taken off the list: lost, wiped by hand, or
  /// on a build that never says goodbye.
  static const Duration forgetAfter = Duration(days: 60);

  Uint8List? _myId;
  String _myName = '';
  List<OwnDevice> _others = const [];
  StreamSubscription<OwnDeviceNotice>? _subscription;
  Timer? _helloTimer;
  bool _disposed = false;
  final _signedOutHere = StreamController<void>.broadcast();

  String get myIdHex => _myId == null ? '' : deviceIdHex(_myId!);
  String get myName => _myName;
  List<OwnDevice> get others => _others;

  /// Another device of this account told this one to sign out.
  Stream<void> get signedOutHere => _signedOutHere.stream;

  bool get started => _myId != null;

  Future<void> start() async {
    if (started || _disposed) return;
    _myId = await store.id();
    _myName = (await store.name()) ?? defaultName;
    _others = _forgetQuiet(await load());
    if (_disposed) return;
    _subscription = _inbound.listen(_receive);
    _changed(persist: false);
    await _hello(answerRequested: true);
    _helloTimer = Timer.periodic(helloEvery, (_) => _hello());
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _myName) return;
    _myName = trimmed;
    await store.setName(trimmed);
    _changed(persist: false);
    await _hello();
  }

  Future<void> signOut(String idHex) async {
    final id = _myId;
    if (id == null || idHex == myIdHex) return;
    _others = [
      for (final d in _others) d.idHex == idHex ? d.copyWith(leaving: true) : d,
    ];
    _changed();
    DebugLog.instance.log('DEVICES', 'signing out ${idHex.substring(0, 8)}');
    await send(
      OwnDeviceNotice.signOut(
        deviceId: id,
        sentAtMs: _now().millisecondsSinceEpoch,
        targetId: _fromHex(idHex),
      ),
    );
  }

  Future<void> signOutOthers() async {
    for (final d in List<OwnDevice>.of(_others)) {
      await signOut(d.idHex);
    }
  }

  void _receive(OwnDeviceNotice notice) {
    final from = deviceIdHex(notice.deviceId);
    if (from == myIdHex) return; // our own, back from a relay
    final at = DateTime.fromMillisecondsSinceEpoch(
      notice.sentAtMs,
      isUtc: true,
    );
    switch (notice.kind) {
      case OwnDeviceKind.hello:
        final known = _others.where((d) => d.idHex == from).firstOrNull;
        if (known == null) {
          _others = [
            ..._others,
            OwnDevice(
              idHex: from,
              name: notice.name ?? '',
              platform: notice.platform,
              lastSeen: at,
            ),
          ];
        } else if (at.isAfter(known.lastSeen)) {
          _others = [
            for (final d in _others)
              d.idHex == from
                  ? d.copyWith(
                      name: notice.name,
                      platform: notice.platform,
                      lastSeen: at,
                    )
                  : d,
          ];
        }
        _changed();
        if (notice.answerRequested) unawaited(_hello());
      case OwnDeviceKind.signOut:
        final target = deviceIdHex(notice.targetId!);
        if (target == myIdHex) {
          DebugLog.instance.log(
            'DEVICES',
            'signed out from another device (${from.substring(0, 8)})',
          );
          unawaited(_leave());
          return;
        }
        _others = [
          for (final d in _others)
            d.idHex == target ? d.copyWith(leaving: true) : d,
        ];
        _changed();
      case OwnDeviceKind.goodbye:
        _others = [
          for (final d in _others)
            if (d.idHex != from) d,
        ];
        _changed();
    }
  }

  /// Say goodbye first — the wipe that follows takes the key it is sealed
  /// with — then let the app sign this device out.
  Future<void> _leave() async {
    final id = _myId;
    if (id != null) {
      try {
        await send(
          OwnDeviceNotice.goodbye(
            deviceId: id,
            sentAtMs: _now().millisecondsSinceEpoch,
          ),
        );
      } catch (e) {
        DebugLog.instance.log('DEVICES', 'goodbye failed: $e');
      }
    }
    if (!_signedOutHere.isClosed) _signedOutHere.add(null);
  }

  Future<void> _hello({bool answerRequested = false}) async {
    final id = _myId;
    if (id == null || _disposed) return;
    try {
      await send(
        OwnDeviceNotice.hello(
          deviceId: id,
          sentAtMs: _now().millisecondsSinceEpoch,
          name: _myName,
          platform: platform,
          answerRequested: answerRequested,
        ),
      );
    } catch (e) {
      DebugLog.instance.log('DEVICES', 'hello failed: $e');
    }
  }

  List<OwnDevice> _forgetQuiet(List<OwnDevice> devices) {
    final cutoff = _now().subtract(forgetAfter);
    return [
      for (final d in devices)
        if (d.lastSeen.isAfter(cutoff)) d,
    ];
  }

  void _changed({bool persist = true}) {
    if (_disposed) return;
    if (persist) unawaited(save(_others));
    notifyListeners();
  }

  static Uint8List _fromHex(String hex) => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);

  @override
  void dispose() {
    _disposed = true;
    _helloTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_signedOutHere.close());
    super.dispose();
  }
}
