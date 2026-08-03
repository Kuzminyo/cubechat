import 'dart:convert';
import 'dart:typed_data';

import '../../../core/transport/inner_payload.dart';
import '../../channels/models/channel.dart';

/// A compact channel invitation for QR exchange.
///
/// Possession of a channel key already is membership, so the QR carries the
/// same bounded [ChannelInvite] bytes used by the encrypted peer-to-peer invite
/// path. The versioned prefix prevents a random QR from being interpreted as a
/// channel credential.
class ChannelQrPayload {
  ChannelQrPayload._();

  static const prefix = 'cubechat:q1:channel:';

  static String encode(Channel channel) {
    final bytes = ChannelInvite(name: channel.name, key: channel.key).encode();
    return '$prefix${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  static ChannelInvite? tryDecode(String raw) {
    final compact = raw.trim().replaceAll(RegExp(r'\s+'), '');
    if (!compact.startsWith(prefix)) return null;
    final token = compact.substring(prefix.length);
    if (token.isEmpty) {
      throw const FormatException('empty channel QR payload');
    }
    try {
      final bytes = Uint8List.fromList(
        base64Url.decode(base64.normalize(token)),
      );
      return ChannelInvite.decode(bytes);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('invalid channel QR payload');
    }
  }
}
