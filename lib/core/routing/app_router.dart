import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/backup/presentation/backup_screen.dart';
import '../../features/backup/presentation/phone_transfer_screen.dart';
import '../../features/channels/presentation/channel_info_screen.dart';
import '../../features/chat/presentation/chat_wallpaper_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/chats/presentation/chat_folders_screen.dart';
import '../../features/chats/presentation/chat_search_screen.dart';
import '../../features/chats/data/saved_messages.dart';
import '../../l10n/app_localizations.dart';
import '../../features/chats/presentation/chats_list_screen.dart';
import '../../features/contacts/presentation/contacts_screen.dart';
import '../../features/files/presentation/file_transfer_center_screen.dart';
import '../../features/map/presentation/people_map_screen.dart';
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

/// Put the keyboard away when the screen that raised it goes.
///
/// A field keeps focus while its route is torn down, and on iOS that leaves the
/// keyboard standing over whatever comes next — the chat list, Contacts,
/// Nearby — with nothing on screen to dismiss it. The only way out a tester
/// found was to open a chat and tap the composer, which moves focus somewhere
/// that can give it up. Focus is released as the pop begins instead, which is
/// where it should have been let go.
class _DismissKeyboardOnPop extends NavigatorObserver {
  void _release() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _release();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _release();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _release();
}

/// [seenOnboarding] is read from disk before the first frame (see
/// `readSeenOnboardingFlag`) so a first run opens straight onto the intro
/// rather than rendering the chats list and redirecting away from it.
GoRouter buildRouter({bool seenOnboarding = true}) {
  return GoRouter(
    navigatorKey: _rootNavKey,
    observers: [_DismissKeyboardOnPop()],
    initialLocation: seenOnboarding ? '/chats' : '/onboarding',
    // Two directions, both narrow. A deep link cannot land somebody inside the
    // app before they have seen the intro, and revisiting /onboarding after
    // the fact bounces back out rather than showing it again.
    redirect: (context, state) {
      final atIntro = state.matchedLocation == '/onboarding';
      if (seenOnboarding && atIntro) return '/chats';
      return null;
    },
    routes: [
      GoRoute(
        path: '/onboarding',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const OnboardingScreen(),
          state: state,
        ),
      ),
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
          onSwitch: navigationShell.goBranch,
        ),
        // Preloaded, all but one. The tabs are a strip you drag between, so the
        // neighbour has to exist before the finger asks for it — a branch
        // go_router has not built yet is a blank screen sliding in, once, on
        // the first swipe of its life.
        //
        // Nearby is the exception: mounting it starts the BLE scanner, and
        // paying for the radio at launch for a tab nobody has opened is a worse
        // trade than one blank first swipe. It stays lazy, and the scan-gating
        // tests still hold it to the idle cadence once it is mounted.
        branches: [
          StatefulShellBranch(
            preload: true,
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
            preload: true,
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
          // The map stays lazy: opening it is the only time we ask for a
          // location fix or paint map tiles.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (context, state) => const PeopleMapScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
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
      // What the Saved header opens: the same shared-content screen a contact
      // has, over the notebook. Its own route for the same reason /saved is —
      // the content route's path parameter is a peer pubkey.
      GoRoute(
        path: '/saved/content',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: AuroraBackground(
            child: ContactContentScreen(
              chatId: savedChatId,
              contactName: AppLocalizations.of(context).savedTitle,
            ),
          ),
          state: state,
        ),
      ),
      GoRoute(
        path: '/folders',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: const ChatFoldersScreen(),
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
        path: '/wallpaper/:chatId',
        parentNavigatorKey: _rootNavKey,
        pageBuilder: (context, state) => fadeSlidePage(
          child: ChatWallpaperScreen(
            chatId: state.pathParameters['chatId']!,
          ),
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
