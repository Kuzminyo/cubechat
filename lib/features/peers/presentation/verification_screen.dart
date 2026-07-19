import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/identity_keys.dart';
import '../../../core/crypto/identity_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/known_peers_controller.dart';

/// Out-of-band fingerprint verification.
///
/// Shows the local user's fingerprint and the remote peer's fingerprint
/// side-by-side. The user reads them aloud to the peer (over a voice call,
/// in person, etc.) and confirms they match — that's the only way to detect
/// a MITM that swapped the X25519 static keys during the Noise handshake.
///
/// "Mark as verified" stamps `verifiedAt` on the peer's KnownPeer entry, so
/// the chat list can show a shield badge from then on.
class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({
    super.key,
    required this.peerPubkeyHex,
    required this.peerLabel,
  });

  final String peerPubkeyHex;
  final String peerLabel;

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  String? _peerFingerprint;

  @override
  void initState() {
    super.initState();
    _computePeerFingerprint();
  }

  Future<void> _computePeerFingerprint() async {
    final pubkeyBytes = _hexToBytes(widget.peerPubkeyHex);
    if (pubkeyBytes == null) return;
    final digest = await Blake2s().hash(pubkeyBytes);
    final fp = IdentityKeys.formatFingerprint(Uint8List.fromList(digest.bytes));
    if (mounted) setState(() => _peerFingerprint = fp);
  }

  static Uint8List? _hexToBytes(String hex) {
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final myFp = ref.watch(identityFingerprintProvider);
    final knownPeers = ref.watch(knownPeersControllerProvider);
    final entry = knownPeers[widget.peerPubkeyHex];
    final alreadyVerified = entry?.isVerified ?? false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.verifyTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
          children: [
            _IntroCard(text: t.verifyIntro),
            const SizedBox(height: 12),
            _FingerprintCard(
              title: t.verifyMine,
              accent: AppColors.brandPrimary,
              fingerprint: myFp.maybeWhen(
                data: (v) => v,
                orElse: () => '…',
              ),
              ready: myFp.hasValue,
            ),
            const SizedBox(height: 12),
            _FingerprintCard(
              title: t.verifyTheirs(widget.peerLabel),
              accent: AppColors.aurora4,
              fingerprint: _peerFingerprint ?? '…',
              ready: _peerFingerprint != null,
            ),
            const SizedBox(height: 20),
            if (alreadyVerified)
              GlassCard(
                strong: true,
                child: Row(
                  children: [
                    const Icon(Icons.verified,
                        color: AppColors.brandPrimary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t.verifyAlreadyDone,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref
                          .read(knownPeersControllerProvider.notifier)
                          .revokeVerification(widget.peerPubkeyHex),
                      child: Text(
                        t.verifyRevoke,
                        style: const TextStyle(color: AppColors.danger),
                      ),
                    ),
                  ],
                ),
              )
            else
              _MarkVerifiedButton(
                label: t.verifyMarkAsVerified,
                onTap: () async {
                  await ref
                      .read(knownPeersControllerProvider.notifier)
                      .markVerified(widget.peerPubkeyHex);
                  if (!context.mounted) return;
                  // Surface the result so the user gets confirmation.
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: AppColors.brandPrimary.withValues(alpha: 0.85),
                      content: Text(
                        t.verifyDoneSnack(widget.peerLabel),
                        style: const TextStyle(color: Colors.white),
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            const SizedBox(height: 12),
            GlassCard(
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => ref
                        .read(knownPeersControllerProvider.notifier)
                        .setMuted(
                          widget.peerPubkeyHex,
                          !(entry?.isMuted ?? false),
                        ),
                    icon: Icon(
                      (entry?.isMuted ?? false)
                          ? Icons.notifications_off
                          : Icons.notifications_outlined,
                      size: 18,
                      color: AppColors.textOnGlass,
                    ),
                    label: Text(
                      (entry?.isMuted ?? false) ? t.peerUnmute : t.peerMute,
                      style: TextStyle(color: AppColors.textOnGlass),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => ref
                        .read(knownPeersControllerProvider.notifier)
                        .setBlocked(
                          widget.peerPubkeyHex,
                          !(entry?.isBlocked ?? false),
                        ),
                    icon: const Icon(Icons.block,
                        size: 18, color: AppColors.danger),
                    label: Text(
                      (entry?.isBlocked ?? false) ? t.peerUnblock : t.peerBlock,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ),
                ],
              ),
            ),
            if (entry?.isBlocked ?? false) ...[
              const SizedBox(height: 8),
              Text(
                t.peerBlockedNote,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              color: AppColors.brandPrimary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FingerprintCard extends StatelessWidget {
  const _FingerprintCard({
    required this.title,
    required this.accent,
    required this.fingerprint,
    required this.ready,
  });

  final String title;
  final Color accent;
  final String fingerprint;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      strong: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            fingerprint,
            style: AppTypography.mono(
              size: 14,
              color: ready ? AppColors.textOnGlass : AppColors.textOnGlassFaint,
              weight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: t.copy,
              icon: Icon(Icons.copy, color: AppColors.textOnGlassDim, size: 18),
              onPressed: !ready
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: fingerprint));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                          content: Text(
                            t.copied,
                            style: TextStyle(color: AppColors.textOnGlass),
                          ),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkVerifiedButton extends StatelessWidget {
  const _MarkVerifiedButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: AppColors.brandGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: AppColors.brandPrimary.withValues(alpha: 0.35),
              blurRadius: 14,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.verified, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
