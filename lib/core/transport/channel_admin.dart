import 'dart:typed_data';

/// Administrator role change inside a signed channel frame.
class ChannelAdminChange {
  const ChannelAdminChange({required this.memberId, required this.isAdmin});

  final String memberId;
  final bool isAdmin;

  Uint8List encode() {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(memberId)) {
      throw const FormatException('invalid channel member fingerprint');
    }
    final out = Uint8List(9)..[0] = isAdmin ? 1 : 0;
    for (var index = 0; index < 8; index++) {
      out[index + 1] = int.parse(
        memberId.substring(index * 2, index * 2 + 2),
        radix: 16,
      );
    }
    return out;
  }

  static ChannelAdminChange decode(Uint8List bytes) {
    if (bytes.length != 9 || bytes[0] > 1) {
      throw const FormatException('invalid channel administrator change');
    }
    final id = bytes
        .sublist(1)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return ChannelAdminChange(memberId: id, isAdmin: bytes[0] == 1);
  }
}
