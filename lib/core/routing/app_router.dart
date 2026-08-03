import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/backup/presentation/backup_screen.dart';
import '../../features/backup/presentation/phone_transfer_screen.dart';
import '../../features/channels/presentation/channel_info_screen.dart';
import '../../features/chats/presentation/chat_search_screen.dart';
import '../../features/chats/data/saved_messages.dart';
import '../../l10n/app_localizations.dart';
import '../../features/chats/presentation/chats_list_screen.dart';
import '../../features/contacts/presentation/contacts_screen.dart';
import '../../features/files/presentation/file_transfer_center_screen.dart';
import '../../features/qr/presentation/qr_scanner_screen.dart';
import '../../features/peers/presentation/contact_card_screen.dart';
import '../../features/peers/presentation/contact_content_screen.dart';
import '../../features/peers/presentation/contact_profile_screen.dart';
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
          // Branch order is the tab order — StatefulShellRoute matches them by
          // index, so this list and the one in AppShell have to move together
          // or a tap lands on someone else's screen.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/contacts',
                builder: (context, state) => const ContactsScreen(),
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
          final initialMessageId = state.uri.queryParameters['message'];
          final returnToChats = state.uri.queryParameters['from'] == 'search';
          return fadeSlidePage(
            child: AuroraBackground(
              child: ChatScreen(
                peerId: peerId,
                peerLabel: peerLabel,
                initialMessageId: initialMessageId,
                returnToChats: returnToChats,
              ),
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
          final initialMessageId = state.uri.queryParameters['message'];
          final returnToChats = state.uri.queryParameters['from'] == 'search';
          return fadeSlidePage(
            child: AuroraBackground(
              child: ChatScreen(
                peerId: channel,
                peerLabel: channel,
                initialMessageId: initialMessageId,
                returnToChats: returnToChats,
              ),
            ),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/channel-info/:name',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final channel = '#${state.pathParameters['name']!}';
          return fadeSlidePage(
            child: ChannelInfoScreen(channelName: channel),
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
        path: '/transfers',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: FileTransferCenterScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/backup',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: BackupScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/phone-transfer',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: PhoneTransferScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/qr/scan',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const QrScannerScreen(),
          state: state,
        ),
      ),
      // A root route, not a branch one: the search screen owns the whole
      // screen including where the nav bar would be, and pushing it inside the
      // shell would leave the bar floating over its results.
      // Its own route rather than /chat/@saved: the chat route's path
      // parameter is a peer pubkey, and this conversation has no peer.
      GoRoute(
        path: '/saved',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: AuroraBackground(
            child: ChatScreen(
              peerId: savedChatId,
              peerLabel: AppLocalizations.of(context).savedTitle,
            ),
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/search',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: ChatSearchScreen()),
          state: state,
        ),
      ),
      GoRoute(
        path: '/contact',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const AuroraBackground(child: ContactCardScreen()),
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
        path: '/person/:pubkey',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final pubkey = state.pathParameters['pubkey']!;
          final name = state.uri.queryParameters['name'] ?? 'Peer';
          return fadeSlidePage(
            child: AuroraBackground(
              child: ContactProfileScreen(
                peerPubkeyHex: pubkey,
                peerLabel: name,
              ),
            ),
            state: state,
          );
        },
      ),
      GoRoute(
        path: '/person/:pubkey/content',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) {
          final pubkey = state.pathParameters['pubkey']!;
          final name = state.uri.queryParameters['name'] ?? 'Peer';
          final tab = int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0;
          return fadeSlidePage(
            child: AuroraBackground(
              child: ContactContentScreen(
                chatId: pubkey,
                contactName: name,
                initialTab: tab,
              ),
            ),
            state: state,
          );
        },
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
