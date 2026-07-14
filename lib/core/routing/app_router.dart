import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/chats/presentation/chats_list_screen.dart';
import '../../features/peers/presentation/peers_screen.dart';
import '../../features/peers/presentation/verification_screen.dart';
import '../../features/profile/presentation/diagnostics_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/relays_screen.dart';
import '../widgets/aurora_background.dart';
import 'app_shell.dart';
import 'branch_container.dart';
import 'page_transitions.dart';

final _rootNavKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: _rootNavKey,
    initialLocation: '/chats',
    routes: [
      // A stateful shell keeps one Navigator per tab alive for the whole
      // session. Tapping a tab swaps which branch is visible — it does not
      // rebuild the screen — so switching is instant and scroll positions and
      // in-flight animations are preserved.
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            AppShell(shell: navigationShell),
        navigatorContainerBuilder: (context, navigationShell, children) =>
            BranchContainer(
          currentIndex: navigationShell.currentIndex,
          branches: children,
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/chats',
                builder: (context, state) => const ChatsListScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/peers',
                builder: (context, state) => const PeersScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/chat/:peerId',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final peerId = state.pathParameters['peerId']!;
          final peerLabel = state.uri.queryParameters['name'] ?? 'Peer';
          return fadeSlidePage(
            child: AuroraBackground(
              child: ChatScreen(peerId: peerId, peerLabel: peerLabel),
            ),
            state: state,
          );
        },
      ),
      // Channels get their own route rather than riding /chat/:peerId. Their
      // chat id starts with '#', and a literal '#' in a URL path is the
      // fragment delimiter — percent-encoded it does not survive the browser's
      // round-trip, so the push silently matched nothing on web. The '#' stays
      // in the chat id; the URL carries the bare name.
      GoRoute(
        path: '/channel/:name',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final channel = '#${state.pathParameters['name']!}';
          return fadeSlidePage(
            child: AuroraBackground(
              child: ChatScreen(peerId: channel, peerLabel: channel),
            ),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/diagnostics',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: DiagnosticsScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/relays',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: RelaysScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/verify/:pubkey',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final pubkey = state.pathParameters['pubkey']!;
          final name = state.uri.queryParameters['name'] ?? 'Peer';
          return fadeSlidePage(
            child: AuroraBackground(
              child: VerificationScreen(
                peerPubkeyHex: pubkey,
                peerLabel: name,
              ),
            ),
            state: state,
          );
        },
      ),
    ],
  );
}
