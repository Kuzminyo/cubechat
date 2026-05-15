import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/message.dart';

/// In-memory store of messages, keyed by peerId.
///
/// Lives for the app's lifetime — no disk persistence yet (lands with M4).
/// Each chat is opened with the BLE-level peerId; once a Noise handshake
/// completes we *could* re-key the chat under the peer's pubkey fingerprint
/// instead, but for v0 we keep it simple and use the transport id.
class MessagesController extends Notifier<Map<String, List<Message>>> {
  @override
  Map<String, List<Message>> build() => <String, List<Message>>{};

  List<Message> forPeer(String peerId) => state[peerId] ?? const <Message>[];

  void append(String peerId, Message msg) {
    final current = state[peerId] ?? const <Message>[];
    state = {...state, peerId: [...current, msg]};
  }

  void updateStatus(String peerId, String msgId, MessageStatus status) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final updated = Message(
      id: current[idx].id,
      chatId: current[idx].chatId,
      text: current[idx].text,
      sentAt: current[idx].sentAt,
      isMine: current[idx].isMine,
      status: status,
    );
    final list = [...current]..[idx] = updated;
    state = {...state, peerId: list};
  }

  void clearAll() {
    state = <String, List<Message>>{};
  }
}

final messagesControllerProvider =
    NotifierProvider<MessagesController, Map<String, List<Message>>>(MessagesController.new);
