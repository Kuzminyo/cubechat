/// BLE protocol constants for the Cubechat mesh transport.
///
/// UUIDs were generated once with `dart:math.Random.secure` + RFC 4122 v4
/// and are deliberately fixed — they identify the cubechat GATT service
/// and let peers filter scan results to "things that speak cubechat".
abstract final class BleConstants {
  /// Primary GATT service. Every cubechat node advertises this UUID.
  static const String serviceUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c20';

  /// Characteristic for sending an outbound frame to a peer (write w/o response).
  static const String outboundCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c21';

  /// Characteristic for receiving inbound frames from a peer (notify).
  static const String inboundCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c22';

  /// Read-only characteristic exposing this peer's static metadata
  /// (pubkey fingerprint, protocol version, capability flags).
  static const String peerInfoCharUuid = '6ad2f1c4-9b08-4c4b-9b3a-2a4d7f6e1c23';

  /// Protocol version we currently speak.
  static const int protocolVersion = 1;

  /// Manufacturer data ID we tag scan-response packets with.
  /// (Picked deliberately in the unassigned range; not a real CIC.)
  static const int manufacturerId = 0xC0BE; // "CuBE"

  /// MTU we request when connecting. 247 is the practical Android max
  /// minus overhead; iOS will cap to its own ceiling automatically.
  static const int preferredMtu = 247;

  /// How long a single scan window runs before we restart it.
  static const Duration scanWindow = Duration(seconds: 10);

  /// Quiet period between scan windows (battery friendliness).
  static const Duration scanGap = Duration(seconds: 4);

  /// Peer is considered stale if we haven't seen it for this long.
  static const Duration peerStaleAfter = Duration(seconds: 30);
}
