import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/util/haptics.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../stickers/data/sticker_pack.dart';

/// What an empty conversation shows: a panel with Kubi waving, the way
/// Telegram greets an empty chat with a sticker — and, like there, a tap on
/// him sends that wave as the first message.
///
/// Before the channel is ready there is nothing to send with, so he sits
/// still (the pack's own still) and the line says what is being waited for.
///
/// He waves for as long as the chat stays empty. A sticker bubble plays its
/// loop the same way; this is one small animation on a screen with nothing
/// else moving, and it stops the moment the first message replaces it.
class EmptyChatGreeting extends StatelessWidget {
  const EmptyChatGreeting({super.key, this.onGreet, this.waiting = false});

  /// Sends the wave. Null where a wave is not the thing to send — a channel,
  /// Saved Messages — or while nothing can be sent at all.
  final VoidCallback? onGreet;

  /// The handshake is not finished: nothing can be sent yet.
  final bool waiting;

  static const String sticker = 'cat-wave';
  static const kubiKey = ValueKey('empty-chat-kubi');
  static const double _kubi = 132;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final canSend = onGreet != null && !waiting;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final kubi = Image(
      key: kubiKey,
      image: ResizeImage(
        AssetImage(
          waiting ? StickerPack.still(sticker) : StickerPack.animation(sticker),
        ),
        // Decoded at the size drawn.
        width: (_kubi * dpr).round(),
      ),
      width: _kubi,
      height: _kubi,
      gaplessPlayback: true,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: FloatingGlass(
        blur: false,
        borderRadius: 24,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t.chatEmptyTitle,
                textAlign: TextAlign.center,
                style: AppTypography.heading(
                  size: 16,
                  color: AppColors.textOnGlass,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                waiting
                    ? t.chatEmptyHandshaking
                    : canSend
                        ? t.chatEmptyGreetHint
                        : t.chatEmptyEstablished,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                button: canSend,
                label: canSend ? t.chatEmptyGreetHint : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canSend
                      ? () {
                          Haptics.tap();
                          onGreet!();
                        }
                      : null,
                  child: kubi,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
