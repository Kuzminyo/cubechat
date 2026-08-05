import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../l10n/app_localizations.dart';
import '../models/message.dart';

/// One view-once photo, full screen, and then gone.
///
/// Deliberately *not* [ChatMediaGalleryScreen]. That screen exists to browse a
/// conversation's pictures — it pages sideways through every other photo in
/// the chat and carries Share and Save-to-gallery buttons. Every one of those
/// affordances is the opposite of what this screen promises, so rather than
/// hiding three buttons and disabling paging on a screen built to offer them,
/// this is a separate, much smaller thing that never had them.
///
/// The photo is burned in [dispose] rather than on open: leaving is the moment
/// the viewing is unambiguously over, and it still counts if someone takes a
/// screenshot and immediately backs out — which is the case where firing on
/// open would have let them keep both the screenshot and the photo.
class ViewOnceMediaScreen extends ConsumerStatefulWidget {
  const ViewOnceMediaScreen({
    super.key,
    required this.chatId,
    required this.message,
  });

  final String chatId;
  final Message message;

  @override
  ConsumerState<ViewOnceMediaScreen> createState() =>
      _ViewOnceMediaScreenState();
}

class _ViewOnceMediaScreenState extends ConsumerState<ViewOnceMediaScreen> {
  /// Read once, in initState: by the time this screen closes the message row
  /// has been rewritten and its path blanked, so the widget's own copy is the
  /// only thing left pointing at the file.
  late final String? _path = widget.message.imagePath;

  @override
  void dispose() {
    final wireId = widget.message.wireId;
    if (wireId != null) {
      // Fire-and-forget through the service, not the controller: burning the
      // photo here is only half of it — the other half is telling the sender
      // so their copy goes too. Not awaited because dispose cannot be async,
      // and the burn must not depend on this screen still being alive.
      unawaited(
        ref.read(messagingServiceProvider).consumeViewOnce(
              widget.chatId,
              wireId,
            ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final path = _path;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          t.viewOnceTitle,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: path == null || !File(path).existsSync()
                  ? Text(
                      t.viewOnceUnavailable,
                      style: TextStyle(color: AppColors.textOnGlassDim),
                    )
                  : InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Image.file(File(path), fit: BoxFit.contain),
                    ),
            ),
          ),
          // Said plainly and up front, because the consequence is irreversible
          // and happens on the way out rather than on a button.
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              12,
              24,
              MediaQuery.paddingOf(context).bottom + 20,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_fire_department_outlined,
                    size: 16, color: AppColors.brandPrimary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    t.viewOnceWarning,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12.5,
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
