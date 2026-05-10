import '../models/message.dart';

List<Message> mockMessages(String chatId) {
  final now = DateTime.now();
  return [
    Message(
      id: 'm1',
      chatId: chatId,
      text: 'Hey! Are we still meeting tonight?',
      sentAt: now.subtract(const Duration(minutes: 18)),
      isMine: false,
    ),
    Message(
      id: 'm2',
      chatId: chatId,
      text: 'Yeah — same place, 8pm. Bring the backpack.',
      sentAt: now.subtract(const Duration(minutes: 17)),
      isMine: true,
      status: MessageStatus.read,
    ),
    Message(
      id: 'm3',
      chatId: chatId,
      text: 'Got it. Mesh signal is solid here, 4 hops to the relay.',
      sentAt: now.subtract(const Duration(minutes: 12)),
      isMine: false,
    ),
    Message(
      id: 'm4',
      chatId: chatId,
      text: 'Nice. Switching to low-power mode for now.',
      sentAt: now.subtract(const Duration(minutes: 11)),
      isMine: true,
      status: MessageStatus.read,
    ),
    Message(
      id: 'm5',
      chatId: chatId,
      text: 'See you at the rendezvous point.',
      sentAt: now.subtract(const Duration(minutes: 4)),
      isMine: false,
    ),
  ];
}
