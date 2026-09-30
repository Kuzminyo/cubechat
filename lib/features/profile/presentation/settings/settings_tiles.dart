import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import 'settings_section_icons.dart';

/// One glass block holding a run of rows, with a hairline between them.
///
/// The hairline starts past the icon badge (62 px), as in iOS Settings, so a
/// group reads as one surface with rows in it rather than a stack of slabs —
/// the stack of slabs is what the profile looked like before, and "eyes run
/// all over" was the complaint that replaced it.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const SettingsGroupDivider());
      rows.add(children[i]);
    }
    final radius = BorderRadius.circular(22);
    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.glass(0.065),
          borderRadius: radius,
          border: Border.all(color: AppColors.glass(0.08)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }
}

/// The hairline between two rows of a [SettingsGroup]. A type of its own
/// rather than a shared key: one key on several siblings is a duplicate-key
/// error the moment a group holds three rows.
class SettingsGroupDivider extends StatelessWidget {
  const SettingsGroupDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 62),
      child: Container(height: 1, color: AppColors.glass(0.07)),
    );
  }
}

/// A row that opens a section: coloured badge, title, a short grey state on
/// the right, chevron.
class SettingsSectionRow extends StatelessWidget {
  const SettingsSectionRow({
    super.key,
    required this.section,
    required this.title,
    this.value,
    required this.onTap,
    this.danger = false,
  });

  final SettingsSection section;
  final String title;

  /// What the section is set to, in a word or two — "@kuzminyo", "Через
  /// запит". One line; a long one is cut, never allowed to push the chevron.
  final String? value;
  final VoidCallback onTap;

  /// Acts in place rather than opening a screen, so no chevron; red title.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: section.color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(section.icon, size: 20, color: Colors.white),
              ),
              const SizedBox(width: 13),
              // The title wins the width and may take a second line — the
              // Ukrainian "Конфіденційність і безпека" beside "Через запит"
              // does not fit one line of a 360 dp phone, and a cut section
              // name is worse than a taller row. The value is the one cut.
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.rowTitle.copyWith(
                    fontSize: 15.5,
                    color: danger ? AppColors.danger : AppColors.textOnGlass,
                  ),
                ),
              ),
              if (value != null && value.isNotEmpty) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: AppColors.textOnGlassDim,
                    ),
                  ),
                ),
              ],
              if (!danger) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: AppColors.glass(0.35),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The grey capitals above a group inside a section screen.
class SettingsSubheader extends StatelessWidget {
  const SettingsSubheader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
          color: AppColors.textOnGlassDim,
        ),
      ),
    );
  }
}

/// The frame of every section screen: the same transparent bar and list
/// padding as Customize, so each section opens the way Customize always has.
class SettingsSectionScaffold extends StatelessWidget {
  const SettingsSectionScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          title,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
          children: children,
        ),
      ),
    );
  }
}
