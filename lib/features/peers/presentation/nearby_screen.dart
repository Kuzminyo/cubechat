import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/branch_pager.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/section_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../../airdrop/presentation/airdrop_navigation.dart';
import '../../airdrop/presentation/airdrop_page.dart';
import '../../files/presentation/file_transfer_center_screen.dart';
import 'peers_screen.dart';

/// The Nearby tab: people in Bluetooth range, AirDrop, and every file the app
/// has moved — one island to pick between them, and the tab swipe turning the
/// pages before it changes tab (see [BranchPager]).
///
/// All three stay mounted: the first holds the scanner, and remounting it is a
/// radio restart. The hidden two have their tickers off.
class NearbyScreen extends ConsumerStatefulWidget {
  const NearbyScreen({super.key, @visibleForTesting this.pages});

  /// Stand-ins for the three pages, in a test that is about the shell.
  final List<Widget>? pages;

  static const int pageCount = 3;

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _page = 0;
  double _from = 1;
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );

  /// Whether this tab is on screen, as of the last build — tickers are off
  /// for a tab the strip has moved away from and for a route covered by
  /// another. Read in build, where depending on [TickerMode] is allowed.
  bool _visible = true;

  /// Whether the app itself is resumed, not merely on screen. The AirDrop
  /// page being the visible tab is not enough on its own: Home or the lock
  /// screen while it's showing must not leave the proximity scan and the
  /// stranger-visibility window (`MessagingService._discoverableNow`)
  /// running in a pocket indefinitely.
  ///
  /// Deliberately paused/hidden → false and resumed → true only, never
  /// `inactive`. Android fires `inactive` for anything that merely covers the
  /// app for a moment — the notification shade, a permission dialog, the
  /// recents switcher — and lib/app.dart's own lifecycle handler already
  /// learned the cost of treating that as "left": every glance at the shade
  /// restarted the radio (see the comment above `_applyBackgroundRadioPolicy`
  /// there). Starts true: this screen never builds before the app's first
  /// resume, and [WidgetsBinding.lifecycleState] can read null that early.
  bool _resumed = true;

  /// Captured up front so [dispose] can say the page is gone without reading
  /// `ref` — which it may not do once the element is being torn down.
  late final StateController<bool> _pageOnScreen;

  @override
  void initState() {
    super.initState();
    _pageOnScreen = ref.read(airdropPageOnScreenProvider.notifier);
    _live++;
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final asked = ref.read(nearbyPageRequestProvider);
      if (asked != null) {
        _take(asked);
      } else {
        _publish();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The tab leaving the screen, or a route covering it, turns tickers off —
    // which is also exactly when the AirDrop page stops being seen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // See [_resumed] for why only these two outcomes react, and `inactive`
    // never does.
    if (state == AppLifecycleState.resumed) {
      if (_resumed) return;
      _resumed = true;
      _publish();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_resumed) return;
      _resumed = false;
      _publish();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slide.dispose();
    // Nothing else would ever turn it off once this screen is gone, and the
    // proximity scan and the stranger-visibility window follow it. Riverpod
    // refuses a provider write from inside dispose, so it goes just after —
    // unless another NearbyScreen has taken over by then, which publishes
    // for itself.
    _live--;
    final pageOnScreen = _pageOnScreen;
    scheduleMicrotask(() {
      if (_live == 0 && pageOnScreen.mounted && pageOnScreen.state) {
        pageOnScreen.state = false;
      }
    });
    super.dispose();
  }

  /// NearbyScreens mounted right now — see [dispose].
  static int _live = 0;

  void _publish() {
    if (!mounted) return;
    registerBranchPager(
      ref.read(branchPagersProvider.notifier),
      BranchPager(
        branch: kNearbyBranch,
        index: _page,
        count: NearbyScreen.pageCount,
        step: (delta) => _select(_page + delta),
      ),
    );
    _pageOnScreen.state = _page == kAirDropPage && _visible && _resumed;
  }

  void _take(int page) {
    ref.read(nearbyPageRequestProvider.notifier).state = null;
    _select(page);
    _publish();
  }

  void _select(int page) {
    if (page == _page || page < 0 || page >= NearbyScreen.pageCount) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _from = page > _page ? 1 : -1;
      _page = page;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = 1;
    } else {
      unawaited(_slide.forward(from: 0));
    }
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final subtitle = switch (_page) {
      1 => t.nearbyAirDropSubtitle,
      2 => t.nearbyFilesSubtitle,
      _ => t.peersSubtitle,
    };
    ref.listen<int?>(nearbyPageRequestProvider, (_, next) {
      if (next != null) _take(next);
    });
    final pages =
        widget.pages ?? const [PeersScreen(), AirDropPage(), _FilesPage()];
    final visible = TickerMode.valuesOf(context).enabled;
    _visible = visible;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // One section header owned by the shell — Contacts' title-then-switch
          // arrangement, so the name isn't drawn twice (the pages used to draw
          // their own display titles too; see peers_screen.dart's _Header and
          // airdrop_page.dart).
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const CubeLogo(size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t.peersTitle,
                        key: const Key('nearby-section-title'),
                        style: AppTypography.display(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  key: const Key('nearby-section-subtitle'),
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
                ),
                const SizedBox(height: 14),
                SectionSwitch(
                  labels: [t.peersTitle, t.airdropTab, t.nearbyTabFiles],
                  selected: _page,
                  onSelect: _select,
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                for (var i = 0; i < pages.length; i++)
                  Offstage(
                    offstage: i != _page,
                    child: TickerMode(
                      enabled: visible && i == _page,
                      child: _PageSlide(
                        animation:
                            i == _page ? _slide : kAlwaysCompleteAnimation,
                        from: _from,
                        child: pages[i],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The incoming page eases in from the side it came from — the same motion
/// the Contacts | Calls switch uses.
class _PageSlide extends StatelessWidget {
  const _PageSlide({
    required this.animation,
    required this.from,
    required this.child,
  });

  final Animation<double> animation;
  final double from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final travel = MediaQuery.sizeOf(context).width * 0.22;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, inner) {
        final t =
            reduced ? 1.0 : Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * from * travel, 0),
            child: inner,
          ),
        );
      },
    );
  }
}

class _FilesPage extends StatelessWidget {
  const _FilesPage();

  @override
  Widget build(BuildContext context) => const FileTransferList(
        bottomPadding: 140,
        topPadding: 0,
        showClearHistory: true,
      );
}
