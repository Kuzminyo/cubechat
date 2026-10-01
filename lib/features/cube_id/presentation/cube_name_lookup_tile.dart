import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/util/haptics.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/cube_id_controller.dart';

/// "Find @name" under a search that was given a Cube ID nobody here has.
///
/// The server is asked only on the tap, never while typing: a search box that
/// sent every keystroke to Cube ID would tell it who this phone is looking
/// for, letter by letter. The tap takes the same verified path as "@dima"
/// typed into Add contact (`CubeIdController.lookupAndAdd`) and lands in the
/// conversation, the way adding someone does everywhere else.
class CubeNameLookupTile extends ConsumerStatefulWidget {
  const CubeNameLookupTile({super.key, required this.name});

  /// Normalised, without the "@".
  final String name;

  @override
  ConsumerState<CubeNameLookupTile> createState() => _CubeNameLookupTileState();
}

class _CubeNameLookupTileState extends ConsumerState<CubeNameLookupTile> {
  bool _busy = false;

  Future<void> _lookUp() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    Haptics.tap();
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(cubeIdControllerProvider.notifier)
          .lookupAndAdd(widget.name);
      if (!mounted) return;
      switch (result) {
        case LookupFound(:final pubkeyHex):
          final label =
              ref.read(knownPeersControllerProvider)[pubkeyHex]?.displayName ??
                  '@${widget.name}';
          FocusManager.instance.primaryFocus?.unfocus();
          showGlassToast(context, t.contactAdded(label), tone: ToastTone.success);
          await context.push(
            '/chat/$pubkeyHex?name=${Uri.encodeComponent(label)}',
          );
        case LookupNotFound():
          showGlassToast(context, t.lookupNotFound, tone: ToastTone.danger);
        case LookupOffline():
          showGlassToast(context, t.cubeIdOffline, tone: ToastTone.danger);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return FloatingGlass(
      blur: false,
      borderRadius: 18,
      onTap: _lookUp,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary.withValues(alpha: 0.16),
                border: Border.all(
                  color: AppColors.brandPrimary.withValues(alpha: 0.38),
                ),
              ),
              alignment: Alignment.center,
              child: _busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.brandPrimary,
                      ),
                    )
                  : Icon(
                      Icons.alternate_email_rounded,
                      color: AppColors.brandPrimary,
                      size: 22,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.searchFindCubeName(widget.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.searchFindCubeNameHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textOnGlassFaint,
            ),
          ],
        ),
      ),
    );
  }
}
