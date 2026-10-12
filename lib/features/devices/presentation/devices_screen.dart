import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/own_device_notice.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../l10n/app_localizations.dart';
import '../../profile/presentation/settings/settings_tiles.dart';
import '../data/device_identity.dart';
import '../data/own_devices.dart';
import '../data/own_devices_controller.dart';

/// Where this account is open, and signing out there — "как в gmail"
/// (docs/superpowers/specs/2026-10-12-own-devices-design.md).
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key, this.now});

  /// The clock "online N min ago" is read against; a test fixes it.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final devices = ref.watch(ownDevicesProvider);
    final others = [...devices.others]
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final clock = now ?? DateTime.now;
    return SettingsSectionScaffold(
      title: t.devicesTitle,
      children: [
        SettingsGroup(
          children: [
            _DeviceRow(
              icon: _icon(currentDevicePlatform),
              name: devices.myName,
              detail: t.devicesThisDevice,
              // A pencil rather than the word: the word took the room a
              // computer's name needs ("Windows · DESKT…").
              trailing: IconButton(
                tooltip: t.devicesRename,
                onPressed: () => unawaited(_rename(context, devices)),
                icon: Icon(Icons.edit_rounded, color: AppColors.brandPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              t.devicesEmpty,
              style: TextStyle(color: AppColors.textOnGlassDim, height: 1.4),
            ),
          )
        else ...[
          SettingsGroup(
            children: [
              for (final d in others)
                _DeviceRow(
                  icon: _icon(d.platform),
                  name: d.name.isEmpty ? '—' : d.name,
                  detail: d.leaving
                      ? t.devicesLeaving
                      : _seen(t, clock().difference(d.lastSeen)),
                  dim: d.leaving,
                  trailing: d.leaving
                      ? null
                      : TextButton(
                          onPressed: () =>
                              unawaited(_signOut(context, devices, d)),
                          child: Text(
                            t.devicesSignOut,
                            style: const TextStyle(color: AppColors.danger),
                          ),
                        ),
                ),
            ],
          ),
          if (others.where((d) => !d.leaving).length > 1) ...[
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: () => unawaited(_signOutAll(context, devices)),
                child: Text(
                  t.devicesSignOutAll,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            t.devicesCaveat,
            style: TextStyle(
              color: AppColors.textOnGlassFaint,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  static IconData _icon(DevicePlatform p) => switch (p) {
        DevicePlatform.android || DevicePlatform.ios =>
          Icons.smartphone_rounded,
        DevicePlatform.windows ||
        DevicePlatform.macos ||
        DevicePlatform.linux =>
          Icons.computer_rounded,
        DevicePlatform.unknown => Icons.devices_other_rounded,
      };

  static String _seen(AppLocalizations t, Duration ago) {
    if (ago.inMinutes < 2) return t.devicesSeenNow;
    if (ago.inHours < 1) return t.devicesSeenMinutes(ago.inMinutes);
    if (ago.inDays < 1) return t.devicesSeenHours(ago.inHours);
    return t.devicesSeenDays(ago.inDays);
  }

  Future<void> _signOut(
    BuildContext context,
    OwnDevicesService devices,
    OwnDevice device,
  ) async {
    final t = AppLocalizations.of(context);
    final phone = device.platform == DevicePlatform.android ||
        device.platform == DevicePlatform.ios;
    final ok = await confirmAction(
      context,
      title: t.devicesSignOutTitle(device.name),
      message: phone ? t.devicesSignOutPhoneMessage : t.devicesSignOutMessage,
      confirmLabel: t.devicesSignOut,
    );
    if (ok) await devices.signOut(device.idHex);
  }

  Future<void> _signOutAll(
    BuildContext context,
    OwnDevicesService devices,
  ) async {
    final t = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: t.devicesSignOutAll,
      message: t.devicesSignOutAllMessage,
      confirmLabel: t.devicesSignOut,
    );
    if (ok) await devices.signOutOthers();
  }

  Future<void> _rename(BuildContext context, OwnDevicesService devices) async {
    final t = AppLocalizations.of(context);
    final controller = TextEditingController(text: devices.myName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        title: Text(
          t.devicesRenameTitle,
          style: TextStyle(color: AppColors.textOnGlass, fontSize: 17),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: TextStyle(color: AppColors.textOnGlass),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(t.devicesSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await devices.rename(name);
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.name,
    required this.detail,
    this.trailing,
    this.dim = false,
  });

  final IconData icon;
  final String name;
  final String detail;
  final Widget? trailing;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: .16),
            ),
            child: Icon(icon, color: AppColors.brandPrimary, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dim ? AppColors.textOnGlassDim : AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
