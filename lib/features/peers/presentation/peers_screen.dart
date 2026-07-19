import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../data/peer_discovery_controller.dart';
import '../data/peripheral_controller.dart';
import '../models/discovered_peer.dart';
import 'widgets/signal_bars.dart';

class PeersScreen extends ConsumerStatefulWidget {
  const PeersScreen({super.key});

  @override
  ConsumerState<PeersScreen> createState() => _PeersScreenState();
}

class _PeersScreenState extends ConsumerState<PeersScreen> {
  @override
  void initState() {
    super.initState();
    // Defer past the build pass so providers are stable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(peerDiscoveryControllerProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final state = ref.watch(peerDiscoveryControllerProvider);
    final peripheral = ref.watch(peripheralControllerProvider);
    final controller = ref.read(peerDiscoveryControllerProvider.notifier);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
        children: [
          _Header(
            title: t.peersTitle,
            subtitle: t.peersSubtitle,
            state: state,
            peripheral: peripheral,
          ),
          const SizedBox(height: 12),
          ..._buildBody(context, t, state, controller),
        ],
      ),
    );
  }

  List<Widget> _buildBody(
    BuildContext context,
    AppLocalizations t,
    PeerDiscoveryState state,
    PeerDiscoveryController controller,
  ) {
    switch (state.status) {
      case PeerDiscoveryStatus.unsupported:
        return [
          _StatusCard(
            icon: Icons.bluetooth_disabled,
            tone: _StatusTone.warning,
            title: t.bleUnsupportedTitle,
            hint: t.bleUnsupportedHint,
          ),
        ];

      case PeerDiscoveryStatus.permissionsUnknown:
      case PeerDiscoveryStatus.permissionsDenied:
        return [
          _StatusCard(
            icon: Icons.shield_outlined,
            tone: _StatusTone.brand,
            title: t.blePermissionTitle,
            hint: state.status == PeerDiscoveryStatus.permissionsDenied
                ? t.blePermissionDeniedHint
                : t.blePermissionHint,
            actionLabel: t.blePermissionGrant,
            onAction: controller.requestPermissions,
          ),
        ];

      case PeerDiscoveryStatus.permissionsPermanentlyDenied:
        return [
          _StatusCard(
            icon: Icons.shield_outlined,
            tone: _StatusTone.danger,
            title: t.blePermissionTitle,
            hint: t.blePermissionDeniedHint,
            actionLabel: t.blePermissionOpenSettings,
            onAction: controller.openSettings,
          ),
        ];

      case PeerDiscoveryStatus.adapterOff:
        return [
          _StatusCard(
            icon: Icons.bluetooth_disabled,
            tone: _StatusTone.warning,
            title: t.bleAdapterOffTitle,
            hint: t.bleAdapterOffHint,
            actionLabel: t.bleRetry,
            onAction: controller.start,
          ),
        ];

      case PeerDiscoveryStatus.idle:
      case PeerDiscoveryStatus.scanning:
        if (state.peers.isEmpty) {
          return [_EmptyScanning(label: t.peersEmpty)];
        }
        return [
          for (var i = 0; i < state.peers.length; i++)
            AppearAnimation(
              delay: AppearAnimation.stagger(i),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Consumer(
                  builder: (context, ref, _) => _PeerCard(
                    peer: state.peers[i],
                    onTap: () =>
                        _connectAndOpen(context, ref, state.peers[i], t),
                  ),
                ),
              ),
            ),
        ];
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.state,
    required this.peripheral,
  });

  final String title;
  final String subtitle;
  final PeerDiscoveryState state;
  final PeripheralState peripheral;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scanning = state.status == PeerDiscoveryStatus.scanning;
    final broadcasting = peripheral.status == PeripheralStatus.broadcasting;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const CubeLogo(size: 32),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: AppTypography.display())),
              if (scanning) _ScanningPulse(label: t.bleScanning),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SizeTransition(sizeFactor: anim, child: child),
            ),
            child: broadcasting
                ? Padding(
                    key: const ValueKey('broadcast-on'),
                    padding: const EdgeInsets.only(top: 10),
                    child: _BroadcastChip(
                      label: t.bleBroadcasting,
                      detail: t.bleConnectedCount(peripheral.connectedCount),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('broadcast-off')),
          ),
        ],
      ),
    );
  }
}

class _BroadcastChip extends StatelessWidget {
  const _BroadcastChip({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.brandPrimary.withValues(alpha: 0.12),
        border:
            Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.podcasts, color: AppColors.brandPrimary, size: 14),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '  ·  ',
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          Text(
            detail,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ScanningPulse extends StatefulWidget {
  const _ScanningPulse({required this.label});

  final String label;

  @override
  State<_ScanningPulse> createState() => _ScanningPulseState();
}

class _ScanningPulseState extends State<_ScanningPulse>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final glow = 0.35 + 0.35 * _c.value;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.brandPrimary.withValues(alpha: 0.12),
            border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandPrimary.withValues(alpha: glow * 0.4),
                blurRadius: 10 + 6 * _c.value,
                spreadRadius: -1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.brandPrimary.withValues(alpha: glow),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _StatusTone { brand, warning, danger }

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.tone,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final _StatusTone tone;
  final String title;
  final String hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  Color get _toneColor => switch (tone) {
        _StatusTone.brand => AppColors.brandPrimary,
        _StatusTone.warning => AppColors.warning,
        _StatusTone.danger => AppColors.danger,
      };

  @override
  Widget build(BuildContext context) {
    return AppearAnimation(
      child: GlassCard(
        strong: true,
        padding: const EdgeInsets.all(20),
        borderRadius: 22,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _toneColor.withValues(alpha: 0.18),
                border: Border.all(color: _toneColor.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, color: _toneColor, size: 20),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              style: TextStyle(
                  color: AppColors.textOnGlassDim, fontSize: 13, height: 1.4),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              PillButton(label: actionLabel!, active: true, onTap: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyScanning extends StatelessWidget {
  const _EmptyScanning({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return AppearAnimation(
      child: GlassCard(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Column(
            children: [
              const _RadarSpinner(),
              const SizedBox(height: 14),
              Text(
                label,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadarSpinner extends StatefulWidget {
  const _RadarSpinner();

  @override
  State<_RadarSpinner> createState() => _RadarSpinnerState();
}

class _RadarSpinnerState extends State<_RadarSpinner>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return CustomPaint(
            painter: _RadarPainter(progress: _c.value),
          );
        },
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;

    // Outer ring
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = AppColors.brandPrimary.withValues(alpha: 0.25);
    canvas.drawCircle(c, maxR - 1, ring);
    canvas.drawCircle(c, maxR * 0.6,
        ring..color = AppColors.brandPrimary.withValues(alpha: 0.18));

    // Expanding pulse
    final pulseR = maxR * progress;
    final pulse = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.brandPrimary.withValues(alpha: (1 - progress) * 0.8);
    canvas.drawCircle(c, pulseR, pulse);

    // Center dot
    final dot = Paint()..color = AppColors.brandPrimary;
    canvas.drawCircle(c, 3, dot);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) => old.progress != progress;
}

Future<void> _connectAndOpen(
  BuildContext context,
  WidgetRef ref,
  DiscoveredPeer peer,
  AppLocalizations t,
) async {
  final label =
      peer.advertisedName.isNotEmpty ? peer.advertisedName : t.bleUnknownPeer;

  // Navigate immediately so the user sees the "handshaking..." UI; the
  // connect/handshake happens in the background and Riverpod will repaint
  // the chat screen as the session progresses.
  context.push(
      '/chat/${Uri.encodeComponent(peer.id)}?name=${Uri.encodeQueryComponent(label)}');

  await _connectWithFeedback(context, ref, peer, label, t);
}

/// Runs the retrying connect and, if it still fails, surfaces a readable
/// message with a Retry action. Kept separate from [_connectAndOpen] so the
/// action re-runs only the connect — pushing the chat route a second time
/// would stack another screen.
Future<void> _connectWithFeedback(
  BuildContext context,
  WidgetRef ref,
  DiscoveredPeer peer,
  String label,
  AppLocalizations t,
) async {
  final messaging = ref.read(messagingServiceProvider);
  final scanner = ref.read(bleScannerProvider);
  try {
    await messaging.connectAsInitiatorWithRetry(
      deviceId: peer.id,
      displayName: label,
      refreshId: () => scanner.refreshPeerId(peer.advertisedName),
    );
  } catch (_) {
    // The per-attempt cause is already in the debug log; the user gets the
    // actionable version.
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger.withValues(alpha: 0.9),
          duration: const Duration(seconds: 6),
          content: Text(
            t.bleConnectFailed,
            style: const TextStyle(color: Colors.white),
          ),
          action: SnackBarAction(
            label: t.bleRetry,
            textColor: Colors.white,
            onPressed: () {
              _connectWithFeedback(context, ref, peer, label, t);
            },
          ),
        ),
      );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({required this.peer, required this.onTap});

  final DiscoveredPeer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final displayName =
        peer.advertisedName.isNotEmpty ? peer.advertisedName : t.bleUnknownPeer;
    return GlassCard(
      onTap: onTap,
      child: Row(
        children: [
          IdentityAvatar(
            seed: peer.id,
            label: displayName,
            size: 44,
            online: true,
            heroTag: 'avatar-${peer.id}',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${peer.rssi} dBm · ${peer.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SignalBars(strength: peer.signalStrength),
        ],
      ),
    );
  }
}
