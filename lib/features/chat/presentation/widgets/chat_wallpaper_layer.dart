import 'dart:async';
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

    // Decoded before the conversation needs it, not while it is arriving.
    //
    // "The first time I open a chat it freezes; I close it and open it again
    // and it is fine" is a cache being filled, and this is the biggest thing
    // in it: a wallpaper is a photograph from the camera roll, decoded to the
    // full width of the screen, and the first frame of the conversation cannot
    // lay out until it exists. Open the same chat again and it is already in
    // `PaintingBinding.imageCache`, which is exactly the asymmetry reported.
    //
    // `precacheImage` starts the decode and does not wait for it, so this
    // costs the opening frame nothing; what it buys is the decode beginning at
    // the top of the build rather than partway through layout. The image is
    // requested with the same provider and the same `cacheWidth` the paint
    // below uses, so the entry it fills is the entry the paint then finds —
    // a different width would decode the picture twice and help nothing.
    _warm(context, wallpaper);

    return Stack(
      children: [
        // Its own cached layer.
        //
        // A wallpaper is the single most expensive thing on the screen to draw
        // and the single least likely to change: a photograph scaled to fill,
        // with a dim laid over it, static from the moment the chat opens until
        // it closes. Without a boundary it is re-rastered whenever anything
        // above it repaints — which, in a conversation, is every arriving
        // message, every delivery mark, every keystroke in the composer.
        //
        // It matters most on the way out. Closing a chat measured raster
        // 44.6 ms against build 1.6 — no Dart work at all, a screenful of
        // drawing — and the screen being dragged off is the one carrying the
        // photograph. Cached, the compositor moves those pixels instead of
        // making them again.
        Positioned.fill(
          child: RepaintBoundary(
            child: ChatWallpaperPaint(wallpaper: wallpaper),
          ),
        ),
        child,
      ],
    );
  }
}

/// Start the wallpaper's decode without waiting for it — see [build].
void _warm(BuildContext context, ChatWallpaper wallpaper) {
  final path = wallpaper.imagePath;
  if (path == null || !MediaPaths.exists(path)) return;
  final width = (MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context))
      .round();
  unawaited(
    precacheImage(
      ResizeImage(FileImage(File(path)), width: width),
      context,
      onError: (_, __) {},
    ),
  );
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
