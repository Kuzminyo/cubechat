import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../data/call_controller.dart';
import '../domain/call_state_machine.dart';

/// Kept inside the app lock: incoming calls never bypass the lock screen.
class CallHost extends ConsumerWidget {
  const CallHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callControllerProvider);
    return Stack(children: [
      ExcludeFocus(excluding: call.peerId != null, child: child),
      if (call.peerId != null) Positioned.fill(child: CallScreen(call: call)),
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
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (!call.active) call.dismiss();
        return true;
      },
      child: Material(
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
      ),
    );
  }

  Widget _control(IconData icon, String label, VoidCallback action,
          {bool selected = false}) =>
      SizedBox(
          width: 90,
          child: Column(children: [
            IconButton.filledTonal(
              onPressed: action,
              tooltip: label,
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
            const SizedBox(height: 8),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textPrimary)),
          ]));
}
