import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';

class QrDisplay extends StatelessWidget {
  const QrDisplay({
    required this.data,
    this.size = 220,
    super.key,
  });

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: AppColors.brandPrimary.withValues(alpha: 0.18),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: QrImageView(
          data: data,
          version: QrVersions.auto,
          size: size,
          padding: EdgeInsets.zero,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      );
}

Future<void> showQrDialog(
  BuildContext context, {
  required String title,
  required String data,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppColors.bgTop,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTypography.heading(
                  size: 18,
                  color: AppColors.textOnGlass,
                ),
              ),
              const SizedBox(height: 18),
              FittedBox(child: QrDisplay(data: data)),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
