import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/share_anchor.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../profile/data/relay_settings_controller.dart';
import '../data/known_peers_controller.dart';

/// Our own contact card, rebuilt whenever the identity or nickname behind it
/// changes. Async because signing it touches the identity key and the prekey
/// store.
final myContactCardProvider = FutureProvider<String>((ref) async {
  // The card embeds the nickname, so a rename has to re-mint it — otherwise a
  // card copied after renaming would introduce you under the old name.
  ref.watch(nicknameControllerProvider);
  return ref.read(messagingServiceProvider).myContactCard();
});

/// Exchange identities with someone who is **not** in Bluetooth range.
///
/// The mesh bootstraps trust by proximity: two phones meet, swap signed
/// announcements, and from then on each can address the other. Two people in
/// different cities never get that moment, which is why a chat between them
/// could not be started at all — the internet fallback could carry the message,
/// but neither side knew the other's keys to encrypt it to.
///
/// A contact card is that missing handshake, moved off the radio: the same
/// signed bundle, as text you can send through whatever app you already share.
class ContactCardScreen extends ConsumerWidget {
  const ContactCardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final card = ref.watch(myContactCardProvider);
    final relayOn = ref.watch(relaySettingsProvider).isActive;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.contactTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (!relayOn) ...[
            const _RelayOffBanner(),
            const SizedBox(height: 14),
          ],
          _Label(text: t.contactMineLabel),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.contactMineExplainer,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    card.valueOrNull ?? '…',
                    maxLines: 4,
                    style: AppTypography.mono(
                      size: 10.5,
                      color: AppColors.textOnGlassDim,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.copy,
                        label: t.contactCopy,
                        onTap: card.hasValue
                            ? (_) async {
                                await Clipboard.setData(
                                  ClipboardData(text: card.value!),
                                );
                                if (!context.mounted) return;
                                showCopiedToast(context, t.contactCopied);
                              }
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.ios_share,
                        label: t.contactShare,
                        primary: true,
                        onTap: card.hasValue
                            ? (buttonContext) => Share.share(
                                  card.value!,
                                  subject: t.contactShareSubject,
                                  sharePositionOrigin:
                                      shareAnchorFor(buttonContext),
                                )
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _Label(text: t.contactAddLabel),
          const _AddContactField(),
          const SizedBox(height: 12),
          GlassCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.textOnGlassFaint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.contactUnverified,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
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

/// A card is only useful once there is a transport that can carry frames to
/// someone out of radio range, and that transport is off by default.
class _RelayOffBanner extends ConsumerWidget {
  const _RelayOffBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Row(
        children: [
          const Icon(Icons.public_off, size: 18, color: Colors.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t.contactRelayOff,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () =>
                ref.read(relaySettingsProvider.notifier).setEnabled(true),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              t.contactRelayEnable,
              style: const TextStyle(
                color: AppColors.brandPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddContactField extends ConsumerStatefulWidget {
  const _AddContactField();

  @override
  ConsumerState<_AddContactField> createState() => _AddContactFieldState();
}

class _AddContactFieldState extends ConsumerState<_AddContactField> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _controller.text = text;
    await _submit();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final raw = _controller.text.trim();
    if (raw.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final pubkeyHex =
          await ref.read(messagingServiceProvider).addContactFromCard(raw);
      if (!mounted) return;
      final name =
          ref.read(knownPeersControllerProvider)[pubkeyHex]?.displayName ?? '';
      _controller.clear();
      showGlassToast(context, t.contactAdded(name), tone: ToastTone.success);
      // Straight into the conversation — adding someone is only ever a prelude
      // to writing to them.
      context.pushReplacement(
        '/chat/$pubkeyHex?name=${Uri.encodeComponent(name)}',
      );
    } on StateError {
      if (!mounted) return;
      showGlassToast(context, t.contactOwnCard, tone: ToastTone.danger);
    } on FormatException {
      if (!mounted) return;
      showGlassToast(context, t.contactInvalid, tone: ToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              enableSuggestions: false,
              maxLines: 2,
              minLines: 1,
              style: TextStyle(color: AppColors.textOnGlass, fontSize: 12.5),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: t.contactAddHint,
                hintStyle: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 12.5,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          IconButton(
            tooltip: t.contactPaste,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.content_paste,
              size: 18,
              color: AppColors.textOnGlassDim,
            ),
            onPressed: _busy ? null : _pasteFromClipboard,
          ),
          TextButton(
            onPressed: _busy ? null : _submit,
            child: Text(
              t.contactAddAction,
              style: TextStyle(
                color: _busy
                    ? AppColors.textOnGlassFaint
                    : AppColors.brandPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;

  /// Handed this button's own [BuildContext] so an action that presents
  /// platform UI can anchor it to the button (see [_anchorOf]).
  final void Function(BuildContext buttonContext)? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: enabled ? () => onTap!(context) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: primary && enabled ? AppColors.brandGradient : null,
          color: primary && enabled
              ? null
              : Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color:
                  enabled ? AppColors.textOnGlass : AppColors.textOnGlassFaint,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: enabled
                    ? AppColors.textOnGlass
                    : AppColors.textOnGlassFaint,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
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
