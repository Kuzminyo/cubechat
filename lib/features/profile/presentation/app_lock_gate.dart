import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../data/app_lock_controller.dart';
import 'widgets/code_pad.dart';

/// Stands in front of the app while the lock is asking.
///
/// A gate rather than a route: the app underneath is built and running — it
/// has to be, since messages keep arriving and the mesh keeps its links — and
/// what this does is cover it. Pushing a route instead would leave the covered
/// screen one back-press away.
class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockControllerProvider);
    if (!lock.enabled || !lock.locked) return child;
    return Stack(
      children: [
        // Kept in the tree, not thrown away: the conversation behind this is
        // still receiving, and rebuilding it on every unlock would cost a
        // reload of every chat for a screen nobody was reading anyway.
        ExcludeSemantics(child: child),
        const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();

  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _wrong = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // The keyboard comes up on its own: there is exactly one thing to do here.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The wait as m:ss, which is how a countdown is read.
  static String _mmss(Duration left) {
    final total = left.inSeconds;
    final m = total ~/ 60;
    final ss = (total % 60).toString().padLeft(2, '0');
    return m > 0 ? '$m:$ss' : '${total}s';
  }

  Future<void> _submit(String code) async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await ref.read(appLockControllerProvider.notifier).unlock(code);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _wrong = !ok;
    });
    if (!ok) {
      // The only feedback a wrong code gets. Deliberately quiet: a count of
      // attempts tells whoever is holding the phone how much room they have.
      HapticFeedback.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final penalty = ref.watch(appLockControllerProvider).penaltyLeft;
    // Ticked here rather than by a timer of its own: the countdown only needs
    // to move while somebody is looking at it, and this widget is only on
    // screen while somebody is.
    if (penalty > Duration.zero) {
      Future<void>.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() {});
      });
    }
    return Material(
      // Opaque on purpose: the point is that what is behind cannot be read,
      // and a blur is a picture of the thing it is hiding.
      color: AppColors.bgDeep,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CubeLogo(size: 64),
                const SizedBox(height: 20),
                Text(
                  t.appLockPrompt,
                  textAlign: TextAlign.center,
                  style: AppTypography.heading(
                    size: 18,
                    color: AppColors.textOnGlass,
                  ),
                ),
                const SizedBox(height: 8),
                // The same keypad the code was set on, for the same reasons: a
                // PIN is not text, and a system keyboard on this screen can
                // autocorrect it, suggest it, or offer to remember it.
                CodePad(
                  title: '',
                  hint: '',
                  actionLabel: t.appLockUnlock,
                  enabled: !_checking && penalty == Duration.zero,
                  errorText: penalty > Duration.zero
                      ? t.appLockWait(_mmss(penalty))
                      : (_wrong ? t.appLockWrong : null),
                  onSubmit: (code) => unawaited(_submit(code)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
