import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../l10n/app_localizations.dart';
import '../data/airdrop_source.dart';
import '../data/share_inbox.dart';
import 'airdrop_people_sheet.dart';
import 'airdrop_send_flow.dart';
import 'airdrop_text.dart';

/// "Share → CubeChat": the files are known, only the person is not.
class AirDropShareScreen extends ConsumerWidget {
  const AirDropShareScreen({super.key, required this.files});

  final List<SharedFile> files;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          t.airdropTab,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Text(
            airdropWhat(t, [for (final f in files) f.mime]),
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
          ),
          const SizedBox(height: 8),
          AirDropPeopleList(
            onPick: (peer) => unawaited(_send(context, ref, peer)),
          ),
        ],
      ),
    );
  }

  Future<void> _send(
    BuildContext context,
    WidgetRef ref,
    AirDropPeer peer,
  ) async {
    final sources = [
      for (final f in files.take(nearbyMaxFiles))
        await AirDropSource.fromFile(File(f.path), name: f.name),
    ];
    if (!context.mounted) return;
    await startAirDropSend(context, ref, to: peer, files: sources);
    if (!context.mounted) return;
    context.go('/peers');
  }
}
