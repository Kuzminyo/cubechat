import 'package:cubechat/core/transport/control_delivery.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Not sent", "sent and not confirmed" and "confirmed" are three facts.
///
/// They were one number. A call on mobile internet (callId 9ba4922a) wrote its
/// invite to seven relays, heard nothing within the two-second deadline, and
/// the zero that came back was read as nothing having left the phone — while
/// the other phone was already ringing.
void main() {
  group('a relay receipt', () {
    RelayPublishOutcome read(int sentTo, int ok, int no) =>
        RelayPublishOutcome.fromReceipt(
          PublishReceipt(sentTo: sentTo, accepted: ok, rejected: no),
        );

    test('one yes is accepted', () {
      expect(read(7, 1, 0), RelayPublishOutcome.accepted);
    });

    test('seven written and nobody answering in time is unconfirmed, the '
        'receipt from the log', () {
      expect(read(7, 0, 0), RelayPublishOutcome.unconfirmed);
    });

    test('one no while the rest are silent is still unconfirmed', () {
      expect(read(7, 0, 1), RelayPublishOutcome.unconfirmed,
          reason: 'a silent relay may have stored and delivered it');
    });

    test('a no from every relay written to is a refusal', () {
      expect(read(3, 0, 3), RelayPublishOutcome.refused);
    });

    test('written nowhere is unavailable', () {
      expect(read(0, 0, 0), RelayPublishOutcome.unavailable);
    });
  });

  group('mesh and relay together', () {
    test('the recipient\'s own link is confirmed', () {
      expect(
        combineControlDelivery(
          meshLinks: 1,
          direct: true,
          relay: RelayPublishOutcome.unavailable,
        ).certainty,
        DeliveryCertainty.confirmed,
      );
    });

    test('someone else\'s link is only a hope', () {
      final d = combineControlDelivery(
        meshLinks: 2,
        direct: false,
        relay: RelayPublishOutcome.unavailable,
      );
      expect(d.certainty, DeliveryCertainty.unconfirmed);
      expect(d.links, 2, reason: 'the count every other sender reads is kept');
    });

    test('a relay yes is one link and confirmed', () {
      expect(
        combineControlDelivery(
          meshLinks: 0,
          direct: false,
          relay: RelayPublishOutcome.accepted,
        ),
        const ControlDelivery(
          links: 1,
          certainty: DeliveryCertainty.confirmed,
        ),
      );
    });

    test('a silent relay is zero links but not nothing', () {
      expect(
        combineControlDelivery(
          meshLinks: 0,
          direct: false,
          relay: RelayPublishOutcome.unconfirmed,
        ),
        const ControlDelivery(
          links: 0,
          certainty: DeliveryCertainty.unconfirmed,
        ),
      );
    });

    test('refused everywhere and no mesh is not sent', () {
      expect(
        combineControlDelivery(
          meshLinks: 0,
          direct: false,
          relay: RelayPublishOutcome.refused,
        ),
        ControlDelivery.notSent,
      );
    });
  });
}
