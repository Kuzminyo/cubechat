import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../qr/data/channel_qr_payload.dart';
import '../../qr/presentation/qr_display.dart';
import '../data/channel_controller.dart';

/// Open the "add people" picker for [channelName].
///
/// Its own entry point because two places open it now — the channel header and
/// the channel profile — and the profile is where people look for it.
Future<void> showChannelInviteSheet(
  BuildContext context,
  String channelName,
) =>
    showGlassSheet<void>(
      context: context,
      builder: (_) => ChannelInviteSheet(channelName: channelName),
    );

/// Peer picker for channel invitations. Each selected peer is handed the
/// channel key over their own 1:1 encrypted link, so there is no group
/// membership list to maintain — holding the key *is* membership.
class ChannelInviteSheet extends ConsumerStatefulWidget {
  const ChannelInviteSheet({super.key, required this.channelName});

  final String channelName;

  @override
  ConsumerState<ChannelInviteSheet> createState() => _ChannelInviteSheetState();
}

class _ChannelInviteSheetState extends ConsumerState<ChannelInviteSheet> {
  final _selected = <String>{};
  bool _sending = false;

  Future<void> _invite() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);

    // Grab everything context-bound before the first await — the sheet is
    // popped below, which invalidates its own context.
    final t = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final messaging = ref.read(messagingServiceProvider);

    var delivered = 0;
    for (final pubkeyHex in _selected) {
      try {
        final fanout = await messaging.sendChannelInvite(
          channelName: widget.channelName,
          peerCanonicalId: pubkeyHex,
        );
        if (fanout > 0) delivered++;
      } catch (_) {
        // Per-peer failure is already logged; the summary below is what the
        // user acts on.
      }
    }

    if (!mounted) return;
    // Shown before the pop, but into the root overlay, so it outlives this
    // sheet rather than being disposed along with it.
    showGlassToast(
      context,
      delivered > 0 ? t.channelInviteSent : t.channelInviteNoneSent,
      icon: delivered > 0 ? Icons.send_rounded : null,
      tone: delivered > 0 ? ToastTone.success : ToastTone.danger,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final peers = ref.watch(knownPeersControllerProvider).values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final channel = ref.watch(channelControllerProvider)[widget.channelName];
    final qrData = channel == null ? null : ChannelQrPayload.encode(channel);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          Text(
            t.channelInviteTitle,
            style:
                AppTypography.heading(size: 16, color: AppColors.textOnGlass),
          ),
          const SizedBox(height: 2),
          Text(
            widget.channelName,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          if (qrData != null)
            TextButton.icon(
              onPressed: () => showQrDialog(
                context,
                title: t.qrChannelTitle(widget.channelName),
                data: qrData,
              ),
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(t.qrShow),
            ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                t.channelInviteEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: peers.length,
                itemBuilder: (_, i) {
                  final p = peers[i];
                  final name = p.displayName.isNotEmpty
                      ? p.displayName
                      : 'Peer ${p.pubkeyHex.substring(0, 6)}';
                  return CheckboxListTile(
                    value: _selected.contains(p.pubkeyHex),
                    activeColor: AppColors.brandPrimary,
                    controlAffinity: ListTileControlAffinity.trailing,
                    onChanged: _sending
                        ? null
                        : (v) => setState(() {
                              if (v ?? false) {
                                _selected.add(p.pubkeyHex);
                              } else {
                                _selected.remove(p.pubkeyHex);
                              }
                            }),
                    secondary: IdentityAvatar(
                      seed: p.pubkeyHex,
                      label: name,
                      size: 36,
                    ),
                    title: Text(
                      name,
                      style:
                          TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                    ),
                    subtitle: p.isVerified
                        ? Text(
                            t.bleVerified,
                            style: TextStyle(
                              color: AppColors.brandPrimary,
                              fontSize: 11,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: _selected.isEmpty || _sending ? null : _invite,
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : Text(t.channelInviteAction),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
