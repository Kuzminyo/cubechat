import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/debug_log.dart';
import '../../../l10n/app_localizations.dart';
import '../models/message.dart';

/// Burn one view-once photo: delete it here, and tell the sender so their copy
/// goes too.
///
/// A provider rather than a direct call on [MessagingService] because of where
/// it is invoked from. The viewer burns on the way out, and by then its own
/// `ref` is dead — so the screen captures this function while it is alive and
/// calls it later. The closure reads the service through the *provider's* ref,
/// which outlives any one screen, so the deferred call lands somewhere that is
/// still there. It is also the seam the widget test drives, which is how the
/// burn is pinned without standing up the whole transport.
///
/// [notifyPeer] is what keeps the promise pointed the right way. "I have seen
/// it" is only true of a photo somebody sent *us*; sending it for our own
/// outgoing copy told the other person their picture had been viewed when they
/// had not opened it yet, and their app dutifully destroyed it. Glancing at
/// what you just sent should cost you your copy, not theirs.
typedef ViewOnceBurn = Future<void> Function(
  String chatId,
  String wireId, {
  bool notifyPeer,
});

final viewOnceBurnProvider = Provider<ViewOnceBurn>(
  (ref) => (chatId, wireId, {bool notifyPeer = true}) => ref
      .read(messagingServiceProvider)
      .consumeViewOnce(chatId, wireId, notifyPeer: notifyPeer),
);

/// One view-once photo, full screen, and then gone.
///
/// Deliberately *not* [ChatMediaGalleryScreen]. That screen exists to browse a
/// conversation's pictures — it pages sideways through every other photo in
/// the chat and carries Share and Save-to-gallery buttons. Every one of those
/// affordances is the opposite of what this screen promises, so rather than
/// hiding three buttons and disabling paging on a screen built to offer them,
/// this is a separate, much smaller thing that never had them.
///
/// The photo is burned when the viewer is left rather than when it opens:
/// leaving is the moment the viewing is unambiguously over, and it still
/// counts if someone takes a screenshot and immediately backs out — which is
/// the case where firing on open would have let them keep both the screenshot
/// and the photo. Leaving the *app* counts as leaving too, or a photo held
/// open while the process is killed would survive.
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

class _ViewOnceMediaScreenState extends ConsumerState<ViewOnceMediaScreen>
    with WidgetsBindingObserver {
  /// Read once, in [initState]: by the time this screen closes the message row
  /// has been rewritten and its path blanked, so the widget's own copy is the
  /// only thing left pointing at the file.
  String? _path;

  /// The burn, captured while the widget is alive — assigned in [initState],
  /// never as `late final … = ref.read(…)`.
  ///
  /// That distinction is the whole bug this screen has had twice. A `late`
  /// field with an initialiser is evaluated at its *first read*, and the only
  /// read is inside [_burn], which runs from [dispose]. Flutter clears an
  /// element before calling `dispose` on its state, so `ref` considers itself
  /// disposed by then and throws `Cannot use "ref" after the widget was
  /// disposed` — synchronously, before the future the `unawaited` was wrapping
  /// ever existed. The exception went out through dispose, the framework
  /// swallowed it, and nothing was burned: the photo reopened as good as new
  /// every time, which is the one thing this feature must not do. Capturing it
  /// eagerly is what actually moves the read to a point where `ref` is alive.
  late final ViewOnceBurn _burnPhoto;

  /// Burning is idempotent downstream, but the screen can be torn down more
  /// than one way (pop, back gesture, route replacement, the app being sent to
  /// the background) and there is no need to ask twice.
  bool _burned = false;

  @override
  void initState() {
    super.initState();
    _path = widget.message.imagePath;
    _burnPhoto = ref.read(viewOnceBurnProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  void _burn() {
    if (_burned) return;
    _burned = true;
    final wireId = widget.message.wireId;
    if (wireId == null) return;
    // Fire-and-forget: dispose cannot be async, and the burn must not depend
    // on this screen still being alive. Deleting the file here is only half of
    // it — the other half is telling the sender so their copy goes too, which
    // is why this goes through the transport rather than the message store.
    //
    // Our own photo tells nobody. The notice means "I have seen what you sent
    // me", and sending it for a picture we sent ourselves destroyed it on the
    // recipient's phone before they had opened it — checking what you sent
    // took the one viewing they were owed.
    try {
      unawaited(
        _burnPhoto(widget.chatId, wireId, notifyPeer: !widget.message.isMine),
      );
    } catch (e) {
      // Nothing to show — the screen is on its way out — but a burn that threw
      // is exactly the failure that hid here for two releases, so it is not
      // going to be silent again.
      DebugLog.instance.log('VIEWONCE', 'burn of $wireId failed: $e');
    }
  }

  /// Leaving the app is leaving the photo.
  ///
  /// Without this, opening a view-once picture and then swiping the app away
  /// kept it: a killed process never runs [dispose], so the file stayed on
  /// disk and the row stayed unspent, and it opened again on next launch.
  /// Only on a real backgrounding — `inactive` also fires for a notification
  /// shade pulled halfway down, which is not somebody leaving.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _burn();
      // The picture is gone from disk now; say so rather than keep showing a
      // frame whose bytes no longer exist when they come back.
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _burn();
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
