import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/debug_log.dart';
import '../../../l10n/app_localizations.dart';

/// In-app diagnostic log viewer. Reads the [DebugLog] singleton and rebuilds
/// whenever a new line is added.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  @override
  void initState() {
    super.initState();
    DebugLog.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    DebugLog.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final entries = DebugLog.instance.entries;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text('Diagnostics',
            style: AppTypography.heading(size: 18, color: AppColors.textOnGlass)),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: Icon(Icons.copy, color: AppColors.textOnGlass),
            onPressed: () async {
              final text = entries
                  .map((e) =>
                      '${e.at.toIso8601String().substring(11, 23)}  ${e.line}')
                  .join('\n');
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  content: Text(t.copied,
                      style: TextStyle(color: AppColors.textOnGlass)),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: Icon(Icons.delete_outline, color: AppColors.textOnGlass),
            onPressed: () => DebugLog.instance.clear(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: entries.isEmpty
            ? Center(
                child: Text(
                  'No log entries yet.\nTrigger a connection and come back.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final e = entries[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${e.at.toIso8601String().substring(11, 23)}  ${e.line}',
                      style: AppTypography.mono(
                          size: 11.5, color: AppColors.textOnGlass),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
