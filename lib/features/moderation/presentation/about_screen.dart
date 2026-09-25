import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/app_build.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/report.dart';
import 'legal_links.dart';
import 'report_sheet.dart';

/// Where people reach the developer — the same address as the terms and the
/// privacy policy give.
const supportEmail = 'cubechatble@gmail.com';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textOnGlass,
        title: Text(t.aboutTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Center(child: CubeLogo(size: 68)),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'cubechat',
                style: AppTypography.heading(
                  size: 23,
                  color: AppColors.textOnGlass,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Center(
              child: Text(
                // The version only. The build stamp is for testers and lives
                // in Diagnostics and the log header; the owner asked for a
                // plain "Версія 1.0.0" here.
                t.profileVersion(appVersion),
                style: TextStyle(color: AppColors.textOnGlassDim),
              ),
            ),
            const SizedBox(height: 28),
            // The address is written out, not only behind mailto: a phone
            // with no mail app configured opens nothing, and App Review asks
            // that the contact be findable.
            _AboutAction(
              icon: Icons.mail_outline_rounded,
              label: t.aboutContact,
              subtitle: supportEmail,
              onTap: () => unawaited(launchUrl(
                Uri.parse('mailto:$supportEmail'),
              )),
            ),
            _AboutAction(
              icon: Icons.flag_outlined,
              label: t.aboutReport,
              onTap: () => unawaited(showReportSheet(
                context,
                reportContext: ReportContext.general,
              )),
            ),
            _AboutAction(
              icon: Icons.description_outlined,
              label: t.aboutTerms,
              onTap: () => unawaited(launchUrl(
                termsDocumentUrl(context),
                mode: LaunchMode.externalApplication,
              )),
            ),
            _AboutAction(
              icon: Icons.privacy_tip_outlined,
              label: t.aboutPrivacy,
              onTap: () => unawaited(launchUrl(
                privacyDocumentUrl(context),
                mode: LaunchMode.externalApplication,
              )),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutAction extends StatelessWidget {
  const _AboutAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
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
            subtitle: subtitle == null
                ? null
                : Text(
                    subtitle!,
                    style: TextStyle(color: AppColors.textOnGlassDim),
                  ),
            trailing:
                Icon(Icons.chevron_right, color: AppColors.textOnGlassDim),
            onTap: onTap,
          ),
        ),
      );
}
