import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/chats/models/chat.dart';
import '../../features/chats/presentation/chats_list_screen.dart';
import '../../features/peers/presentation/peers_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../widgets/aurora_background.dart';
import 'app_shell.dart';
import 'page_transitions.dart';

final _rootNavKey = GlobalKey<NavigatorState>();
final _shellNavKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: _rootNavKey,
    initialLocation: '/chats',
    routes: [
      ShellRoute(
        navigatorKey: _shellNavKey,
        builder: (context, state, child) {
          final location = state.uri.toString();
          final index = switch (location) {
            (final s) when s.startsWith('/peers') => 1,
            (final s) when s.startsWith('/profile') => 2,
            _ => 0,
          };
          return AppShell(
            currentIndex: index,
            onTabChanged: (i) {
              switch (i) {
                case 0:
                  context.go('/chats');
                case 1:
                  context.go('/peers');
                case 2:
                  context.go('/profile');
              }
            },
            body: child,
          );
        },
        routes: [
          GoRoute(
            path: '/chats',
            pageBuilder: (context, state) =>
                crossFadePage(child: const ChatsListScreen(), state: state),
          ),
          GoRoute(
            path: '/peers',
            pageBuilder: (context, state) =>
                crossFadePage(child: const PeersScreen(), state: state),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder: (context, state) =>
                crossFadePage(child: const ProfileScreen(), state: state),
          ),
        ],
      ),
      GoRoute(
        path: '/chat/:id',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final chat = state.extra as Chat?;
          final screen = chat == null
              ? const AuroraBackground(child: Scaffold(backgroundColor: Colors.transparent))
              : AuroraBackground(child: ChatScreen(chat: chat));
          return fadeSlidePage(child: screen, state: state);
        },
      ),
    ],
  );
}
