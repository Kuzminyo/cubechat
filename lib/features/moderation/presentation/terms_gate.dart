import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../data/terms_controller.dart';

/// Stands in front of the whole app until the current rules are accepted.
///
/// Mounted beside [AppLockGate] in `app.dart`, same technique: the app
/// underneath is built and running, not routed away from, and this covers it
/// with an opaque screen so nothing behind is reachable — no tap, and (via the
/// `PopScope`) no hardware back either.
///
/// Unlike the lock gate, this one has a third state to draw: while the
/// accepted-version read from disk is still in flight there is nothing
/// truthful to show — not the app (nobody has agreed to anything yet) and not
/// the gate (it might be about to discover they already did) — so it shows
/// neither, on purpose, rather than flash one and then possibly replace it
/// with the other a frame later.
class TermsGate extends ConsumerStatefulWidget {
  const TermsGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TermsGate> createState() => _TermsGateState();
}

class _TermsGateState extends ConsumerState<TermsGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _awaitLoad();
  }

  void _awaitLoad() {
    ref.read(termsControllerProvider.notifier).loaded.then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      // Blank rather than either final answer — see the class doc.
      return ColoredBox(color: AppColors.bgDeep);
    }
    final accepted = ref.watch(termsControllerProvider) >= currentTermsVersion;
    if (accepted) return widget.child;
    return Stack(
      children: [
        // Kept in the tree rather than thrown away, the same reasoning as
        // [AppLockGate]: the mesh underneath is still receiving, and a gate
        // that had to be agreed to on every rebuild would be a gate agreed to
        // once and then rebuilt away.
        ExcludeSemantics(child: widget.child),
        Positioned.fill(
          child: PopScope<void>(
            // Nobody gets to the app behind this by pressing back — there is
            // nowhere for back to send them, since they have not agreed to
            // anything yet.
            canPop: false,
            child: const _TermsScreen(),
          ),
        ),
      ],
    );
  }
}

class _TermsScreen extends ConsumerWidget {
  const _TermsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return Material(
      // Opaque, same reasoning as the lock screen: what is behind must not be
      // readable, and a blur is a picture of the thing it hides.
      color: AppColors.bgDeep,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CubeLogo(size: 56),
                const SizedBox(height: 20),
                Text(
                  t.termsTitle,
                  textAlign: TextAlign.center,
                  style: AppTypography.heading(
                    size: 20,
                    color: AppColors.textOnGlass,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  t.termsBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: AppColors.textOnGlassDim,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => unawaited(
                    launchUrl(
                      Uri.parse('https://cubechat.tech/terms'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  child: Text(t.termsReadFull),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brandPrimary,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () =>
                        unawaited(ref.read(termsControllerProvider.notifier).accept()),
                    child: Text(t.termsAccept),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
