import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/util/media_storage.dart';
import '../../data/conversation_settings_controller.dart';

/// Paints one conversation's own background behind it, when it has one.
///
/// Renders *nothing* when unset — not a transparent container, nothing — so
/// every chat that has never been customised behaves exactly as before and the
/// route-level aurora shows through the Scaffold untouched.
///
/// Lives here rather than at the router because the route only carries the raw
/// path parameter, while wallpapers are keyed by the canonical chat id, and
/// that resolution happens inside the screen.
class ChatWallpaperLayer extends ConsumerWidget {
  const ChatWallpaperLayer({
    super.key,
    required this.chatId,
    required this.child,
  });

  final String chatId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallpaper =
        ref.watch(conversationSettingsControllerProvider)[chatId]?.wallpaper ??
            ChatWallpaper.none;
    if (!wallpaper.isSet) return child;

    return Stack(
      children: [
        Positioned.fill(child: ChatWallpaperPaint(wallpaper: wallpaper)),
        child,
      ],
    );
  }
}

/// The wallpaper itself, without the conversation on top — also what the
/// picker previews, so what you choose is what you get.
class ChatWallpaperPaint extends StatelessWidget {
  const ChatWallpaperPaint({super.key, required this.wallpaper});

  final ChatWallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    final preset = wallpaper.presetIndex;
    final path = wallpaper.imagePath;

    Widget base;
    if (path != null && MediaPaths.exists(path)) {
      base = Image.file(
        File(path),
        fit: BoxFit.cover,
        // Capped to the screen: a wallpaper is chosen from the camera roll, so
        // it can be a twelve-megapixel photograph decoded to fill a phone
        // screen — and it sits behind every conversation, in memory, for as
        // long as the chat is open.
        cacheWidth: (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round(),
      );
    } else if (preset != null &&
        preset >= 0 &&
        preset < ChatWallpaper.presets.length) {
      final pair = ChatWallpaper.presets[preset];
      base = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(pair.first), Color(pair.last)],
          ),
        ),
      );
    } else {
      // A picture that has been deleted from under us, or a preset index from
      // a build with more of them. Draw nothing rather than a broken box.
      return const SizedBox.shrink();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        base,
        // Text over a photograph is unreadable at almost any brightness; this
        // is the layer that makes a wallpaper survive contact with a
        // conversation.
        if (wallpaper.dim > 0)
          ColoredBox(color: Colors.black.withValues(alpha: wallpaper.dim)),
      ],
    );
  }
}
