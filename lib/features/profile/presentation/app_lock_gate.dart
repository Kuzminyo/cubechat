import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../data/app_lock_controller.dart';

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

  Future<void> _submit() async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok =
        await ref.read(appLockControllerProvider.notifier).unlock(_controller.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _wrong = !ok;
    });
    if (ok) {
      _controller.clear();
    } else {
      // The only feedback a wrong code gets. Deliberately quiet: a count of
      // attempts tells whoever is holding the phone how much room they have.
      HapticFeedback.mediumImpact();
      _controller.clear();
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
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
                const SizedBox(height: 18),
                TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => unawaited(_submit()),
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 22,
                    letterSpacing: 8,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.glassFill,
                    errorText: _wrong ? t.appLockWrong : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
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
                    onPressed: _checking ? null : () => unawaited(_submit()),
                    child: Text(t.appLockUnlock),
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
