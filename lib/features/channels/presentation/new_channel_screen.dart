import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routing/page_transitions.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chats/presentation/chats_list_screen.dart' show channelRoute;
import '../data/channel_controller.dart';

/// Make or join a room, on a screen of its own.
///
/// This was an `AlertDialog`: a title, two fields and two text buttons, in a
/// box with the chat list showing round it. A dialog is the right shape for a
/// question with a yes and a no, and the wrong one for a thing you are making
/// — there is nowhere to say what the password actually does, so the field sat
/// unexplained next to a name field and people left it empty without knowing
/// that was a decision.
///
/// A screen has the room to say it. Same two fields, same join, plus the two
/// sentences that were missing.
Future<void> openNewChannelScreen(BuildContext context) async {
  final joined = await Navigator.of(context, rootNavigator: true).push<String>(
    mediaRoute<String>((_) => const NewChannelScreen()),
  );
  if (joined != null && context.mounted) {
    context.push(channelRoute(joined));
  }
}

class NewChannelScreen extends ConsumerStatefulWidget {
  const NewChannelScreen({super.key});

  @override
  ConsumerState<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends ConsumerState<NewChannelScreen> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // The name is the only thing that must be typed, so it takes the keyboard.
    _name.addListener(_onNameChanged);
  }

  void _onNameChanged() => setState(() {});

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final name = _name.text.trim();
    if (name.isEmpty || _joining) return;
    setState(() => _joining = true);
    try {
      final channel = await ref
          .read(channelControllerProvider.notifier)
          .join(name, password: _password.text);
      if (!mounted) return;
      Navigator.of(context).pop(channel.name);
    } catch (_) {
      // The only reachable failure is a name too long to fit in an invite;
      // an empty one is guarded above.
      if (!mounted) return;
      setState(() => _joining = false);
      showGlassToast(
        context,
        AppLocalizations.of(context).channelNameTooLong,
        tone: ToastTone.danger,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ready = _name.text.trim().isNotEmpty && !_joining;

    InputDecoration deco(String label, {String? prefix}) => InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: AppColors.textOnGlassDim, fontSize: 14),
          prefixText: prefix,
          prefixStyle: TextStyle(color: AppColors.textOnGlassDim),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.glassBorder),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.brandPrimary),
          ),
        );

    Widget hint(String text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        );

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(
            t.channelsNewTitle,
            style: AppTypography.heading(
              size: AppMenu.title,
              color: AppColors.textOnGlass,
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                cursorColor: AppColors.brandPrimary,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: deco(t.channelNameLabel, prefix: '#'),
              ),
              hint(t.channelNameHint),
              const SizedBox(height: 24),
              TextField(
                controller: _password,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                cursorColor: AppColors.brandPrimary,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: deco(t.channelPasswordLabel),
              ),
              hint(t.channelPasswordHint),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: ready ? _join : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: AppColors.glass(0.12),
                  disabledForegroundColor: AppColors.textOnGlassFaint,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _joining
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : Text(
                        t.channelJoinAction,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Enter on the password field does what the button does.
  void _submit() {
    if (_name.text.trim().isNotEmpty) unawaited(_join());
  }
}
