import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/pro_controller.dart';
import '../models/pro_state.dart';

/// The one screen in cubechat that does not follow the palette.
///
/// Everywhere else a hardcoded colour is a bug — `AppColors` is rewritten by
/// `ThemeController` so the whole interface retints, and a literal is a surface
/// that will not follow. This screen is the deliberate exception, chosen
/// explicitly: a paywall that looks like the rest of the app does not read as
/// an offer, and every messenger that sells a tier breaks out of its own
/// chrome to say "this part is different".
///
/// The gradient is therefore fixed, and it is the only thing here that is.
/// Text still reads through [AppColors.textOnGlass] so contrast follows the
/// same rules as everywhere else.
const _proGradient = <Color>[
  Color(0xFF3B1E8C),
  Color(0xFF7B2FD4),
  Color(0xFFD4429C),
];

/// Per-row accents for the feature list. Fixed for the same reason as the
/// gradient: they are part of the Pro look rather than of the theme.
const _iconAmber = Color(0xFFF5A623);
const _iconBlue = Color(0xFF4A9EF5);
const _iconPink = Color(0xFFEF5DA8);

/// What Pro is, and the three ways to buy it.
class ProScreen extends ConsumerStatefulWidget {
  const ProScreen({super.key});

  @override
  ConsumerState<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends ConsumerState<ProScreen> {
  /// Yearly first and selected, because it is the one worth taking.
  ProProduct _selected = ProProduct.yearly;

  Future<void> _buy() async {
    final t = AppLocalizations.of(context);
    final started = await ref.read(proProvider.notifier).buy(_selected);
    if (!mounted || started) return;
    // The product is not registered in the store yet. That is a thing to say
    // to the person, not a fault to log.
    showGlassToast(context, t.proUnavailable);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pro = ref.watch(proProvider);
    final prices = ref.watch(proPricesProvider).valueOrNull ?? const {};

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: BackButton(color: AppColors.textOnGlass),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _proGradient,
          ),
        ),
        child: SafeArea(child: _content(t, pro, prices)),
      ),
    );
  }

  Widget _content(
    AppLocalizations t,
    ProState pro,
    Map<ProProduct, String> prices,
  ) {
    // Not known yet is not the same as no. Drawing the pitch here would show
    // it for a frame on every cold start to somebody who already paid.
    if (!pro.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (pro.isActive) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CubeLogo(size: 96, glow: true),
              const SizedBox(height: 24),
              Text(
                t.proActive,
                textAlign: TextAlign.center,
                style: AppTypography.display(
                  size: 22,
                  color: AppColors.textOnGlass,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              _hero(t),
              const SizedBox(height: 24),
              for (final product in const [
                ProProduct.yearly,
                ProProduct.monthly,
                ProProduct.lifetime,
              ])
                _PlanCard(
                  label: _label(t, product),
                  period: _period(t, product),
                  // A dash, not an invented number: the store has no price
                  // until the product is registered there.
                  price: prices[product] ?? '—',
                  selected: _selected == product,
                  onTap: () => setState(() => _selected = product),
                ),
              const SizedBox(height: 20),
              _FeatureRow(
                colour: _iconAmber,
                icon: Icons.apps_rounded,
                title: t.proFeatureIconTitle,
                body: t.proFeatureIconBody,
              ),
              _FeatureRow(
                colour: _iconBlue,
                icon: Icons.emoji_emotions_rounded,
                title: t.proFeatureStickersTitle,
                body: t.proFeatureStickersBody,
              ),
              _FeatureRow(
                colour: _iconPink,
                icon: Icons.backup_rounded,
                title: t.proFeatureBackupTitle,
                body: t.proFeatureBackupBody,
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => ref.read(proProvider.notifier).restore(),
                  child: Text(
                    t.proRestore,
                    style: TextStyle(color: AppColors.textOnGlassDim),
                  ),
                ),
              ),
            ],
          ),
        ),
        _cta(t),
      ],
    );
  }

  Widget _hero(AppLocalizations t) => Column(
        children: [
          const SizedBox(height: 8),
          const CubeLogo(size: 104, glow: true),
          const SizedBox(height: 20),
          Text(
            t.proTitle,
            textAlign: TextAlign.center,
            style: AppTypography.display(
              size: 30,
              color: AppColors.textOnGlass,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            t.proBlurb,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              height: 1.35,
            ),
          ),
        ],
      );

  Widget _cta(AppLocalizations t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            onPressed: _buy,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.textOnGlass,
              foregroundColor: _proGradient[1],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(27),
              ),
            ),
            child: Text(
              _selected == ProProduct.lifetime
                  ? t.proBuyOnce
                  : t.proSubscribe,
              style: AppTypography.heading(size: 16, color: _proGradient[1]),
            ),
          ),
        ),
      );

  String _label(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proMonthly,
        ProProduct.yearly => t.proYearly,
        ProProduct.lifetime => t.proLifetime,
      };

  String _period(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proPerMonth,
        ProProduct.yearly => t.proPerYear,
        ProProduct.lifetime => t.proOnce,
      };
}

/// One buyable plan, and whether it is the chosen one.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.label,
    required this.period,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String period;
  final String price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.ink(selected ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  color: selected
                      ? AppColors.textOnGlass
                      : AppColors.textOnGlassFaint,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: AppTypography.heading(
                      size: 16,
                      color: AppColors.textOnGlass,
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      price,
                      style: AppTypography.heading(
                        size: 15,
                        color: AppColors.textOnGlass,
                      ),
                    ),
                    Text(
                      period,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textOnGlassDim,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of what Pro includes.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.colour,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color colour;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: AppColors.textOnGlass),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.heading(
                    size: 16,
                    color: AppColors.textOnGlass,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    height: 1.35,
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
