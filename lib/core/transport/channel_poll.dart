import 'dart:convert';
import 'dart:typed_data';

enum ChannelPollOperation { create, vote }

/// Signed payload used inside a channel broadcast to create a poll or cast a
/// vote. The signing key outside this body is the voter identity, so the wire
/// never trusts a caller-supplied participant id.
class ChannelPollPayload {
  const ChannelPollPayload._({
    required this.operation,
    this.question,
    this.options = const <String>[],
    this.targetWireId,
    this.option,
  });

  factory ChannelPollPayload.create(String question, List<String> options) {
    final cleanQuestion = question.trim();
    final cleanOptions = options.map((value) => value.trim()).toList();
    if (cleanQuestion.isEmpty || cleanQuestion.length > 240) {
      throw const FormatException('poll question is empty or too long');
    }
    if (cleanOptions.length < 2 ||
        cleanOptions.length > 10 ||
        cleanOptions.any((value) => value.isEmpty || value.length > 100)) {
      throw const FormatException('poll needs 2-10 non-empty options');
    }
    return ChannelPollPayload._(
      operation: ChannelPollOperation.create,
      question: cleanQuestion,
      options: cleanOptions,
    );
  }

  factory ChannelPollPayload.vote(String targetWireId, int option) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(targetWireId) || option < 0) {
      throw const FormatException('invalid poll vote');
    }
    return ChannelPollPayload._(
      operation: ChannelPollOperation.vote,
      targetWireId: targetWireId,
      option: option,
    );
  }

  final ChannelPollOperation operation;
  final String? question;
  final List<String> options;
  final String? targetWireId;
  final int? option;

  Uint8List encode() {
    final value = switch (operation) {
      ChannelPollOperation.create => <String, dynamic>{
          'op': 'create',
          'question': question,
          'options': options,
        },
      ChannelPollOperation.vote => <String, dynamic>{
          'op': 'vote',
          'target': targetWireId,
          'option': option,
        },
    };
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 2048) throw const FormatException('poll too large');
    return Uint8List.fromList(bytes);
  }

  static ChannelPollPayload decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 2048) {
      throw const FormatException('invalid poll payload length');
    }
    final dynamic decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('poll payload is not an object');
    }
    switch (decoded['op']) {
      case 'create':
        final question = decoded['question'];
        final options = decoded['options'];
        if (question is! String || options is! List) {
          throw const FormatException('invalid poll create');
        }
        return ChannelPollPayload.create(
          question,
          options.whereType<String>().toList(growable: false),
        );
      case 'vote':
        final target = decoded['target'];
        final option = decoded['option'];
        if (target is! String || option is! int) {
          throw const FormatException('invalid poll vote');
        }
        return ChannelPollPayload.vote(target, option);
      default:
        throw const FormatException('unknown poll operation');
    }
  }
}
