import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../data/call_controller.dart';
import '../domain/call_state_machine.dart';

/// The call, drawn over whatever the router is showing.
///
/// Kept inside the app lock: incoming calls never bypass the lock screen.
///
/// **This lives above the router, and that constrains everything under it.**
/// It is mounted in `MaterialApp.router`'s `builder` so a call survives
/// navigation, which means there is no Router, no Navigator and no Overlay
/// above anything it draws. A widget that looks one of those up throws while
/// building, and a release build paints that as an empty rectangle — here the
/// size of the screen. That shipped once: `BackButtonListener` asks for the
/// Router, and tapping Call on a real phone turned the screen white and left it
/// there. So back is taken from the router's own dispatcher, handed in from
/// app.dart, and the controls carry no tooltips (a tooltip needs an Overlay).
/// `test/call_screen_mount_test.dart` mounts this exactly as the app does; it
/// is the check that anything added here can actually be built.
class CallHost extends ConsumerStatefulWidget {
  const CallHost({
    super.key,
    required this.child,
    required this.backButtonDispatcher,
  });
  final Widget child;

  /// The router's root dispatcher. While a call is on screen a child of it
  /// takes priority, so the back key answers the call screen instead of
  /// popping the page hidden underneath it.
  final BackButtonDispatcher backButtonDispatcher;

  @override
  ConsumerState<CallHost> createState() => _CallHostState();
}

class _CallHostState extends ConsumerState<CallHost> {
  ChildBackButtonDispatcher? _back;

  Future<bool> _onBack() async {
    final call = ref.read(callControllerProvider);
    // A finished call is dismissed by back; a live one is not ended by it —
    // hanging up is a button, not a gesture somebody makes by accident.
    if (!call.active) call.dismiss();
    return true;
  }

  void _holdBack(bool showing) {
    if (showing && _back == null) {
      _back = widget.backButtonDispatcher.createChildBackButtonDispatcher()
        ..addCallback(_onBack)
        ..takePriority();
    } else if (!showing && _back != null) {
      // Removing its last callback makes a child dispatcher step back from
      // its parent on its own, so the router has back again.
      _back!.removeCallback(_onBack);
      _back = null;
    }
  }

  @override
  void dispose() {
    _holdBack(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    final showing = call.peerId != null;
    _holdBack(showing);
    return Stack(children: [
      ExcludeFocus(excluding: showing, child: widget.child),
      if (showing) Positioned.fill(child: CallScreen(call: call)),
    ]);
  }
}

class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.call});
  final CallController call;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final talking = call.phase == CallPhase.talking;
    final incoming = call.phase == CallPhase.incoming && !call.preparing;
    final duration =
        '${call.elapsed.inMinutes.toString().padLeft(2, '0')}:${(call.elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final status = call.preparing
        ? t.callPreparing
        : switch (call.phase) {
            CallPhase.incoming => t.previewCallIncoming,
            CallPhase.dialing => t.callDialing,
            CallPhase.ringing => t.callRinging,
            CallPhase.connecting => t.callConnecting,
            CallPhase.talking => duration,
            _ => switch (call.error) {
                'microphone' => t.callMicrophoneRequired,
                'turn' => t.callRelayUnavailable,
                'busy' => t.callBusy,
                'noAnswer' => t.callNoAnswer,
                'unavailable' || 'media' || 'failed' => t.callFailed,
                'declined' => t.callDeclined,
                _ => t.callEnded,
              },
          };
    return Material(
        color: AppColors.bgDeep,
        child: SafeArea(
          child: LayoutBuilder(
              builder: (context, bounds) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: bounds.maxHeight),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 32),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(t.callVoice,
                                  style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 16)),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 36),
                                child: Column(children: [
                                  IdentityAvatar(
                                      seed: call.peerId ?? '',
                                      label: call.name,
                                      size: 112),
                                  const SizedBox(height: 24),
                                  Text(call.name,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 28,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 12),
                                  Semantics(
                                      liveRegion: !talking,
                                      child: Text(status,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: AppColors.textPrimary,
                                              fontSize: 16))),
                                ]),
                              ),
                              Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 20,
                                  runSpacing: 20,
                                  children: [
                                    if (talking) ...[
                                      _control(
                                          call.micMuted
                                              ? Icons.mic_off_rounded
                                              : Icons.mic_rounded,
                                          t.callMicrophone,
                                          () => unawaited(call.toggleMute()),
                                          selected: call.micMuted),
                                      _control(
                                          Icons.volume_up_rounded,
                                          t.callSpeaker,
                                          () => unawaited(call.toggleSpeaker()),
                                          selected: call.speakerOn),
                                    ],
                                    if (incoming)
                                      _control(Icons.call_rounded, t.callAnswer,
                                          () => unawaited(call.answer()),
                                          selected: true),
                                    if (call.active)
                                      _control(
                                          Icons.call_end_rounded,
                                          incoming ? t.callDecline : t.callEnd,
                                          incoming ? call.decline : call.hangUp)
                                    else
                                      _control(Icons.close_rounded, t.callClose,
                                          call.dismiss),
                                  ]),
                            ]),
                      ),
                    ),
                  )),
        ),
      );
  }

  // No tooltip: a tooltip needs an Overlay, and there is none above this
  // screen (see [CallHost]). The label is drawn under the button, and the
  // Semantics wrapper gives a screen reader the same word the tooltip did.
  Widget _control(IconData icon, String label, VoidCallback action,
          {bool selected = false}) =>
      SizedBox(
          width: 90,
          child: Column(children: [
            Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              child: IconButton.filledTonal(
              onPressed: action,
              isSelected: selected,
              style: IconButton.styleFrom(
                minimumSize: const Size(64, 64),
                backgroundColor: selected
                    ? AppColors.brandPrimary
                    : AppColors.glassFillStrong,
                foregroundColor:
                    selected ? AppColors.bgDeep : AppColors.textPrimary,
              ),
              icon: Icon(icon, size: 28),
            ),
            ),
            const SizedBox(height: 8),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textPrimary)),
          ]));
}
