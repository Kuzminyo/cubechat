import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/cube_id_client.dart';
import '../data/cube_id_controller.dart';
import '../domain/cube_name.dart';

/// Profile → Cube ID: take, change, share or release a short @name.
///
/// Rules are checked on the phone first (the same table the server uses), so
/// "ab" or "admin" never costs a request; availability is asked once the
/// typing stops, not per keystroke.
class CubeIdScreen extends ConsumerStatefulWidget {
  const CubeIdScreen({super.key});

  @override
  ConsumerState<CubeIdScreen> createState() => _CubeIdScreenState();
}

enum _Status { idle, invalid, reserved, checking, available, taken, offline }

class _CubeIdScreenState extends ConsumerState<CubeIdScreen> {
  final _field = TextEditingController();
  Timer? _debounce;
  _Status _status = _Status.idle;
  bool _editing = false;
  bool _busy = false;

  /// Answers for a name typed earlier must not land on the one typed now.
  String _asked = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    final name = normalizeCubeName(raw);
    final problem = cubeNameProblem(name);
    if (name.isEmpty) {
      setState(() => _status = _Status.idle);
      return;
    }
    if (problem != null) {
      setState(
        () => _status = problem == CubeNameProblem.invalid
            ? _Status.invalid
            : _Status.reserved,
      );
      return;
    }
    setState(() => _status = _Status.checking);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      _asked = name;
      final answer = await ref.read(cubeIdClientProvider).available(name);
      if (!mounted || _asked != normalizeCubeName(_field.text)) return;
      setState(() {
        if (answer == null) {
          _status = _Status.offline;
        } else if (answer.available) {
          _status = _Status.available;
        } else {
          _status = answer.reason == 'taken'
              ? _Status.taken
              : answer.reason == 'invalid'
                  ? _Status.invalid
                  : _Status.reserved;
        }
      });
    });
  }

  Future<void> _claim() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result =
        await ref.read(cubeIdControllerProvider.notifier).claim(_field.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case CubeIdOk():
          _editing = false;
          _status = _Status.idle;
          _field.clear();
        case CubeIdRefused(:final code):
          _status = switch (code) {
            'taken' || 'has-name' => _Status.taken,
            'invalid' => _Status.invalid,
            'reserved' => _Status.reserved,
            _ => _Status.idle,
          };
          if (_status == _Status.idle) {
            showGlassToast(
              context,
              AppLocalizations.of(context).cubeIdFailed,
              tone: ToastTone.danger,
            );
          }
        case CubeIdOffline():
          _status = _Status.offline;
      }
    });
  }

  Future<void> _release(String name) async {
    final t = AppLocalizations.of(context);
    final ok = await confirmAction(
      context,
      title: t.cubeIdRelease,
      message: t.cubeIdReleaseConfirm(name),
      confirmLabel: t.cubeIdRelease,
    );
    if (!ok || !mounted) return;
    await ref.read(cubeIdControllerProvider.notifier).release();
  }

  String? _statusText(AppLocalizations t) => switch (_status) {
        _Status.idle || _Status.checking => null,
        _Status.invalid => t.cubeIdInvalid,
        _Status.reserved => t.cubeIdReserved,
        _Status.available => t.cubeIdAvailable,
        _Status.taken => t.cubeIdTaken,
        _Status.offline => t.cubeIdOffline,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = ref.watch(cubeIdControllerProvider).name;
    final showField = name == null || _editing;
    final statusText = _statusText(t);
    final good = _status == _Status.available;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textOnGlass,
        title: Text(t.cubeIdTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              t.cubeIdExplainer,
              style: TextStyle(
                color: AppColors.textOnGlassDim,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            if (name != null)
              Center(
                child: Text(
                  '@$name',
                  style: AppTypography.heading(
                    size: 26,
                    color: AppColors.textOnGlass,
                  ),
                ),
              ),
            if (name != null) const SizedBox(height: 20),
            if (showField) ...[
              TextField(
                controller: _field,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 17),
                decoration: InputDecoration(
                  prefixText: '@',
                  hintText: t.cubeIdFieldHint,
                ),
                onChanged: _onChanged,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 20,
                child: _status == _Status.checking
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : statusText == null
                        ? null
                        : Text(
                            statusText,
                            style: TextStyle(
                              color: good
                                  ? AppColors.brandPrimary
                                  : AppColors.danger,
                              fontSize: 13,
                            ),
                          ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: good && !_busy ? () => unawaited(_claim()) : null,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.alternate_email_rounded),
                label: Text(_busy ? t.cubeIdWorking : t.cubeIdClaim),
              ),
            ],
            if (name != null && !_editing) ...[
              _Action(
                icon: Icons.edit_rounded,
                label: t.cubeIdChange,
                onTap: () => setState(() => _editing = true),
              ),
              _Action(
                icon: Icons.ios_share_rounded,
                label: t.cubeIdShare,
                onTap: () => unawaited(Share.share(t.cubeIdShareText(name))),
              ),
              _Action(
                icon: Icons.delete_outline_rounded,
                label: t.cubeIdRelease,
                onTap: () => unawaited(_release(name)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: AppColors.glass(0.11),
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(icon, color: AppColors.brandPrimary),
            title: Text(label, style: TextStyle(color: AppColors.textOnGlass)),
            trailing:
                Icon(Icons.chevron_right, color: AppColors.textOnGlassDim),
            onTap: onTap,
          ),
        ),
      );
}
