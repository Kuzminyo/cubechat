import 'dart:convert';

/// A lightweight contact reference that can travel as an ordinary encrypted
/// text message. New clients render it as a contact card; older clients keep a
/// harmless opaque token instead of failing to decode the conversation.
class SharedContact {
  const SharedContact({required this.pubkeyHex, required this.displayName});

  static const _prefix = 'cubechat:contact:v1:';

  final String pubkeyHex;
  final String displayName;

  String encode() {
    final payload = jsonEncode({
      'id': pubkeyHex,
      'name': displayName,
    });
    return '$_prefix${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  static SharedContact? tryParse(String raw) {
    final value = raw.trim();
    if (!value.startsWith(_prefix)) return null;
    try {
      final token = value.substring(_prefix.length);
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      );
      if (decoded is! Map) return null;
      final id = decoded['id'];
      final name = decoded['name'];
      if (id is! String ||
          name is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(id) ||
          name.trim().isEmpty) {
        return null;
      }
      return SharedContact(
        pubkeyHex: id.toLowerCase(),
        displayName: name.trim(),
      );
    } on Object {
      return null;
    }
  }
}
