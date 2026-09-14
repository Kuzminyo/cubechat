import 'package:go_router/go_router.dart';

/// Whether a page the router pushed on the root navigator is covering the tab
/// shell - a conversation, a profile, settings.
///
/// **A tab screen cannot ask its own route.** The tabs live in a
/// `StatefulShellRoute`, and every branch has a navigator of its own; a
/// conversation opens on the root navigator, over the whole shell. From inside
/// the chats list, `ModalRoute.of(context)` is the branch's `/chats` page, and
/// that page stays on top of *its* navigator - `isCurrent` is true, and the
/// list is not even rebuilt when a chat covers it. Checked with a router in a
/// throwaway test on 2026-09-15: before the push, during it and after it,
/// `isCurrent=true`. So the list's "hand back the last tree while something is
/// on top" never ran, and the `RouteObserver` it subscribed to never called
/// `didPopNext` either (the observer is on the root navigator, the route it was
/// given is not). The frame meter had been saying so: `chat x2, chats x1`
/// beside a 28-34 ms build on every chat open.
///
/// The router's configuration does know: its last match is the shell while a
/// tab is showing, and something else once a page is pushed over it. A route
/// pushed with `Navigator.push` rather than the router is not in it and does
/// not count, which leaves those screens exactly as they were.
bool routeCoversShell(RouteMatchList configuration) {
  final matches = configuration.matches;
  return matches.isNotEmpty && matches.last is! ShellRouteMatch;
}
