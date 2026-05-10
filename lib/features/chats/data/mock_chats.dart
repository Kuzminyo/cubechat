import '../models/chat.dart';

/// Throwaway data so the UI is alive before BLE/Noise layers exist.
List<Chat> mockChats() {
  final now = DateTime.now();
  return [
    Chat(
      id: 'c1',
      peerId: 'pk_orion',
      peerName: 'Orion',
      lastMessage: 'See you at the rendezvous point.',
      lastTime: now.subtract(const Duration(minutes: 4)),
      unreadCount: 2,
      isMesh: true,
      isOnline: true,
      isFavorite: true,
    ),
    Chat(
      id: 'c2',
      peerId: 'pk_lyra',
      peerName: 'Lyra',
      lastMessage: 'Sent you the new key fingerprint.',
      lastTime: now.subtract(const Duration(minutes: 23)),
      unreadCount: 0,
      isMesh: true,
      isOnline: true,
    ),
    Chat(
      id: 'c3',
      peerId: 'pk_atlas',
      peerName: 'Atlas',
      lastMessage: 'Relay is up — 3 hops from here.',
      lastTime: now.subtract(const Duration(hours: 1, minutes: 12)),
      unreadCount: 5,
      isMesh: true,
      isOnline: false,
    ),
    Chat(
      id: 'c4',
      peerId: 'pk_vega',
      peerName: 'Vega',
      lastMessage: 'Поговоримо за каву?',
      lastTime: now.subtract(const Duration(hours: 3)),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isFavorite: true,
    ),
    Chat(
      id: 'c5',
      peerId: 'pk_nova',
      peerName: 'Nova',
      lastMessage: 'gg, see you tomorrow ⚡',
      lastTime: now.subtract(const Duration(days: 1, hours: 2)),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
    ),
    Chat(
      id: 'c6',
      peerId: 'pk_sigma',
      peerName: 'Sigma',
      lastMessage: 'Battery low, going dark.',
      lastTime: now.subtract(const Duration(days: 2, hours: 6)),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
    ),
  ];
}

List<dynamic> mockMessagesPlaceholder() => const [];
