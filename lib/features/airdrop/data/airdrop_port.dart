import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/debug_log.dart';
import '../../files/data/file_transfer_controller.dart';
import '../domain/airdrop_transfer.dart';

/// Everything AirDrop needs from the transport, and nothing more — so the
/// controller can be driven in a test with no Bluetooth and no Hive.
abstract interface class AirDropPort {
  Stream<NearbyInbound> get inbound;

  bool hasDirectLinkTo(String peerHex);

  Future<bool> send(String peerHex, {NearbyOffer? offer, NearbyAnswer? answer});

  /// One file of an accepted offer, under its offered id. True when every
  /// chunk went.
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  });

  void cancelFile(String mediaIdHex);

  set sink(NearbyFileSink? value);
}

class MessagingAirDropPort implements AirDropPort {
  MessagingAirDropPort(this._ref);

  final Ref _ref;

  MessagingService get _messaging => _ref.read(messagingServiceProvider);

  @override
  Stream<NearbyInbound> get inbound => _messaging.nearbyInbound;

  @override
  bool hasDirectLinkTo(String peerHex) => _messaging.hasDirectLinkTo(peerHex);

  @override
  Future<bool> send(
    String peerHex, {
    NearbyOffer? offer,
    NearbyAnswer? answer,
  }) =>
      _messaging.sendNearbyFrame(peerHex, offer: offer, answer: answer);

  @override
  Future<bool> sendFile(
    String peerHex, {
    required File file,
    required AirDropFile meta,
    required String peerName,
  }) async {
    try {
      await _messaging.sendFile(
        peerHex,
        file: file,
        fileName: meta.name,
        mime: meta.mime,
        reuseMediaId: nearbyUnhex(meta.mediaIdHex),
        appendLocally: false,
        directOnly: true,
        source: FileTransferSource.airdrop,
        peerName: peerName,
      );
    } catch (e) {
      DebugLog.instance.log('AIRDROP', 'sending "${meta.name}" failed: $e');
      return false;
    }
    return _ref.read(fileTransferControllerProvider)[meta.mediaIdHex]?.status ==
        FileTransferStatus.completed;
  }

  @override
  void cancelFile(String mediaIdHex) =>
      _ref.read(fileTransferControllerProvider.notifier).cancel(mediaIdHex);

  /// The service the sink was handed to. Detaching goes back to this one
  /// rather than reading the provider again: on teardown the controller is
  /// disposed after the messaging service, and reading a disposed container
  /// throws — which every test that pumped the whole app did at its end.
  MessagingService? _attached;

  @override
  set sink(NearbyFileSink? value) {
    if (value == null) {
      _attached?.nearbyFileSink = null;
      _attached = null;
      return;
    }
    final service = _messaging;
    service.nearbyFileSink = value;
    _attached = service;
  }
}

final airdropPortProvider = Provider<AirDropPort>(MessagingAirDropPort.new);
