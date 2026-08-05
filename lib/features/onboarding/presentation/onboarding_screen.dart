import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../data/onboarding_controller.dart';

/// What this app is, before the first chat.
///
/// Three things, because three things are what make it behave unlike the
/// messengers people are arriving from: it works with no internet, it falls
/// back to one when there is, and nothing in the middle can read anything.
/// Someone who does not know the first will think it is broken when it works
/// offline; someone who does not know the third has no reason to prefer it.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await ref.read(onboardingControllerProvider.notifier).markSeen();
    if (!mounted) return;
    // Straight into the app rather than into profile setup: a nickname can be
    // set at any time from the profile tab, and a form is a poor first screen
    // when nothing has been seen working yet.
    context.go('/chats');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final slides = <({IconData icon, String title, String body})>[
      (
        icon: Icons.bluetooth_searching_rounded,
        title: t.onboardingMeshTitle,
        body: t.onboardingMeshBody,
      ),
      (
        icon: Icons.public_rounded,
        title: t.onboardingRelayTitle,
        body: t.onboardingRelayBody,
      ),
      (
        icon: Icons.lock_outline_rounded,
        title: t.onboardingPrivacyTitle,
        body: t.onboardingPrivacyBody,
      ),
    ];
    final last = _index == slides.length - 1;

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _page,
                  itemCount: slides.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) {
                    final slide = slides[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (i == 0) ...[
                            const CubeLogo(size: 84),
                            const SizedBox(height: 28),
                          ] else ...[
                            Icon(
                              slide.icon,
                              size: 64,
                              color: AppColors.brandPrimary,
                            ),
                            const SizedBox(height: 28),
                          ],
                          Text(
                            slide.title,
                            textAlign: TextAlign.center,
                            style: AppTypography.heading(size: 24),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            slide.body,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 14.5,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < slides.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: i == _index
                            ? AppColors.brandPrimary
                            : AppColors.glass(0.25),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Row(
                  children: [
                    // Always skippable. Somebody who wants to get on with it is
                    // not going to read three screens because they have to.
                    TextButton(
                      onPressed: _finish,
                      child: Text(
                        t.onboardingSkip,
                        style: TextStyle(color: AppColors.textOnGlassDim),
                      ),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brandPrimary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 14,
                        ),
                      ),
                      onPressed: last
                          ? _finish
                          : () => _page.nextPage(
                                duration: const Duration(milliseconds: 260),
                                curve: Curves.easeOutCubic,
                              ),
                      child: Text(last ? t.onboardingStart : t.onboardingNext),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
