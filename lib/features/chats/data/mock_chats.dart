import '../models/chat.dart';

/// Legacy mock data — kept only because tests still import it. The real
/// chat list is now derived from [chatsProvider] which reads
/// `chatSessionManagerProvider` + `messagesControllerProvider`.
List<Chat> mockChats() => const [];
