import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nostr/nostr_identity_provider.dart';
import '../../../core/transport/nostr/websocket_relay_client.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/relay_settings_controller.dart';
import '../../../core/widgets/glass_toast.dart';

/// Settings for the Nostr internet fallback (M6): switch it on, see the address
/// peers reach you at, and manage the relay list with live connection state.
class RelaysScreen extends ConsumerWidget {
  const RelaysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final settings = ref.watch(relaySettingsProvider);
    final controller = ref.read(relaySettingsProvider.notifier);
    final statuses = ref.watch(relayStatusProvider);
    final npub = ref.watch(myNpubProvider);

    // Reading the service keeps it alive so flipping the switch actually stands
    // the relay pool up — the screen is otherwise the only thing watching.
    ref.watch(messagingServiceProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.relaysTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.brandPrimary.withValues(alpha: 0.18),
                        border: Border.all(
                          color: AppColors.brandPrimary.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Icon(
                        Icons.public,
                        color: AppColors.brandPrimary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.relaysCardTitle,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.relaysCardSubtitle,
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: settings.enabled,
                      activeThumbColor: AppColors.brandPrimary,
                      onChanged: controller.setEnabled,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  t.relaysExplainer,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Label(text: t.relaysMyAddress),
          GlassCard(
            onTap: () async {
              final value = npub.valueOrNull;
              if (value == null) return;
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              showCopiedToast(context, t.relaysCopied);
            },
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    npub.valueOrNull ?? '…',
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.copy, size: 16, color: AppColors.textOnGlassFaint),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Label(text: t.relaysListLabel),
          if (settings.urls.isEmpty)
            GlassCard(
              child: Text(
                t.relaysEmpty,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12.5,
                ),
              ),
            ),
          for (final url in settings.urls)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RelayRow(
                url: url,
                state: settings.enabled
                    ? (statuses[url] ?? RelayState.connecting)
                    : RelayState.idle,
                onRemove: () => controller.removeRelay(url),
              ),
            ),
          const SizedBox(height: 6),
          _AddRelayField(
            onSubmit: (url) async {
              final ok = await controller.addRelay(url);
              if (!ok && context.mounted) {
                showGlassToast(context, t.relaysInvalidUrl,
                    tone: ToastTone.danger);
              }
              return ok;
            },
          ),
        ],
      ),
    );
  }
}

class _RelayRow extends StatelessWidget {
  const _RelayRow({
    required this.url,
    required this.state,
    required this.onRemove,
  });

  final String url;
  final RelayState state;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (color, label) = switch (state) {
      RelayState.connected => (AppColors.online, t.relaysStateConnected),
      RelayState.connecting => (Colors.amber, t.relaysStateConnecting),
      RelayState.failed => (Colors.redAccent, t.relaysStateFailed),
      RelayState.idle => (AppColors.textOnGlassFaint, t.relaysStateIdle),
    };

    return GlassCard(
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  url,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: t.relaysRemove,
            icon: Icon(
              Icons.close,
              size: 18,
              color: AppColors.textOnGlassFaint,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _AddRelayField extends StatefulWidget {
  const _AddRelayField({required this.onSubmit});

  /// Returns true when the relay was accepted, so the field can clear itself.
  final Future<bool> Function(String url) onSubmit;

  @override
  State<_AddRelayField> createState() => _AddRelayFieldState();
}

class _AddRelayFieldState extends State<_AddRelayField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    if (await widget.onSubmit(value)) _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: TextStyle(color: AppColors.textOnGlass, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: t.relaysAddHint,
                hintStyle: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 13,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          TextButton(
            onPressed: _submit,
            child: Text(
              t.relaysAdd,
              style: const TextStyle(
                color: AppColors.brandPrimary,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: AppColors.textOnGlassFaint,
          fontSize: 11,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
