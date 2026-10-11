import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../onboarding/data/onboarding_controller.dart';
import '../../qr/presentation/qr_display.dart';
import '../data/desktop_link_service.dart';
import '../data/windows_firewall.dart';

/// The computer's half of "sign in with my phone's account": a one-time code
/// for the phone to scan, and the wait for its copy to arrive. See
/// [DesktopLinkService].
class DesktopLinkScreen extends ConsumerStatefulWidget {
  const DesktopLinkScreen({super.key});

  @override
  ConsumerState<DesktopLinkScreen> createState() => _DesktopLinkScreenState();
}

class _DesktopLinkScreenState extends ConsumerState<DesktopLinkScreen> {
  DesktopLinkSession? _session;
  bool _failed = false;

  /// Null until checked, and on anything but Windows. See [WindowsFirewall].
  bool? _firewallOpen;
  bool _askingFirewall = false;
  bool _firewallDeclined = false;
  static const _firewall = WindowsFirewall();

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    if (Platform.isWindows) unawaited(_checkFirewall());
  }

  Future<void> _checkFirewall() async {
    try {
      final open = await _firewall.allowsInbound();
      if (mounted) setState(() => _firewallOpen = open);
    } catch (e) {
      // No PowerShell, or a policy that forbids it: say nothing rather than
      // offer a button that cannot work.
      DebugLog.instance.log('LINK', 'firewall check failed: ${e.runtimeType}');
    }
  }

  Future<void> _allowFirewall() async {
    setState(() {
      _askingFirewall = true;
      _firewallDeclined = false;
    });
    var open = false;
    try {
      open = await _firewall.allow();
    } catch (e) {
      DebugLog.instance.log('LINK', 'firewall allow failed: ${e.runtimeType}');
    }
    DebugLog.instance.log('LINK', 'firewall rule ${open ? 'added' : 'declined'}');
    if (!mounted) return;
    setState(() {
      _askingFirewall = false;
      _firewallOpen = open;
      _firewallDeclined = !open;
    });
  }

  Future<void> _start() async {
    setState(() {
      _failed = false;
      _session = null;
    });
    try {
      final session =
          await ref.read(desktopLinkServiceProvider).startReceiving();
      if (!mounted) {
        unawaited(session.cancel());
        return;
      }
      setState(() => _session = session);
      await session.done;
      if (!mounted) return;
      // The copy is this computer's account now; the intro is behind it.
      await ref.read(onboardingControllerProvider.notifier).markSeen();
      if (!mounted) return;
      context.go('/chats');
    } catch (e) {
      // The error's type only: nothing about whose account it was.
      DebugLog.instance.log('LINK', 'computer link failed: ${e.runtimeType}');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(session.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final session = _session;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.desktopLinkTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_failed) ...[
                  Text(
                    t.desktopLinkFailed,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.danger, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => unawaited(_start()),
                    child: Text(t.desktopLinkRetry),
                  ),
                ] else if (session == null)
                  const CircularProgressIndicator()
                else ...[
                  GlassCard(child: QrDisplay(data: session.qr, size: 260)),
                  const SizedBox(height: 18),
                  Text(
                    t.desktopLinkSteps,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.brandPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        t.desktopLinkWaiting,
                        style: TextStyle(color: AppColors.textOnGlassDim),
                      ),
                    ],
                  ),
                  if (_firewallOpen == false) ...[
                    const SizedBox(height: 18),
                    _FirewallCard(
                      asking: _askingFirewall,
                      declined: _firewallDeclined,
                      onAllow: () => unawaited(_allowFirewall()),
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                Text(
                  t.desktopLinkLimits,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textOnGlassFaint,
                    fontSize: 12.5,
                    height: 1.4,
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

class _FirewallCard extends StatelessWidget {
  const _FirewallCard({
    required this.asking,
    required this.declined,
    required this.onAllow,
  });

  final bool asking;
  final bool declined;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, color: AppColors.warning, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    declined
                        ? t.desktopLinkFirewallDeclined
                        : t.desktopLinkFirewallHint,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: asking ? null : onAllow,
              icon: asking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.admin_panel_settings_outlined, size: 18),
              label: Text(t.desktopLinkFirewallAllow),
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone's way in: a row in Data that opens the scanner, which knows an
/// `l1` code when it sees one.
class ConnectComputerRow extends StatelessWidget {
  const ConnectComputerRow({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _LinkRow(
      icon: Icons.computer_rounded,
      title: t.desktopLinkConnectTitle,
      hint: t.desktopLinkConnectHint,
      onTap: () => context.push('/qr/scan'),
    );
  }
}

/// The computer's way in once it already has an account: the same code as in
/// onboarding, from Data. Onboarding was the only door, so a computer that
/// had started with an account of its own could never take the phone's.
///
/// Asked first — the restore replaces this computer's keys, contacts and
/// chats, and an account made here exists nowhere else.
class ImportFromPhoneRow extends StatelessWidget {
  const ImportFromPhoneRow({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _LinkRow(
      icon: Icons.phonelink_rounded,
      title: t.desktopLinkImportTitle,
      hint: t.desktopLinkImportHint,
      onTap: () async {
        final confirmed = await confirmAction(
          context,
          title: t.desktopLinkImportConfirmTitle,
          message: t.desktopLinkImportConfirmMessage,
          confirmLabel: t.desktopLinkImportConfirmAction,
        );
        if (confirmed && context.mounted) {
          await context.push('/desktop-link');
        }
      },
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary.withValues(alpha: .16),
                border: Border.all(
                  color: AppColors.brandPrimary.withValues(alpha: .38),
                ),
              ),
              child: Icon(
                icon,
                color: AppColors.brandPrimary,
                size: 19,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColors.textOnGlassFaint),
          ],
        ),
      ),
    );
  }
}
