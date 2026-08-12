import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../l10n/app_localizations.dart';
import '../data/map_layer_controller.dart';

/// Pick what the map is drawn on.
Future<void> showMapLayerSheet(BuildContext context) => showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _MapLayerSheet(),
    );

class _MapLayerSheet extends ConsumerWidget {
  const _MapLayerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final current = ref.watch(mapLayerControllerProvider);

    (IconData, String, String) describe(MapLayer layer) => switch (layer) {
          MapLayer.dark => (
              Icons.dark_mode_rounded,
              t.mapLayerDark,
              t.mapLayerDarkHint,
            ),
          MapLayer.satellite => (
              Icons.satellite_alt_rounded,
              t.mapLayerSatellite,
              t.mapLayerSatelliteHint,
            ),
          MapLayer.terrain => (
              Icons.terrain_rounded,
              t.mapLayerTerrain,
              t.mapLayerTerrainHint,
            ),
        };

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.glass(0.24),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPrimary.withValues(alpha: 0.14),
                  ),
                  child: Icon(Icons.layers_rounded,
                      color: AppColors.brandPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.mapLayerTitle,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.mapLayerHint,
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final layer in MapLayer.values)
            Builder(
              builder: (context) {
                final (icon, title, hint) = describe(layer);
                final selected = layer == current;
                return ListTile(
                  leading: Icon(
                    icon,
                    color: selected
                        ? AppColors.brandPrimary
                        : AppColors.textOnGlassDim,
                  ),
                  title: Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    hint,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                    ),
                  ),
                  trailing: selected
                      ? Icon(Icons.check_rounded, color: AppColors.brandPrimary)
                      : null,
                  onTap: () {
                    ref.read(mapLayerControllerProvider.notifier).select(layer);
                    Navigator.of(context).pop();
                  },
                );
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
