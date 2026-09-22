import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/image_encode.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/media_picker_sheet.dart';
import '../../profile/data/media_quality_controller.dart';
import '../data/airdrop_controller.dart';
import '../data/airdrop_source.dart';
import '../domain/airdrop_rules.dart';
import 'airdrop_navigation.dart';
import 'airdrop_people_sheet.dart';

/// Everything between "send files" and the offer leaving: what, to whom,
/// the checks, and the AirDrop page brought to the front to show it.
/// [to] and [files] are filled in by entry points that already know them.
Future<void> startAirDropSend(
  BuildContext context,
  WidgetRef ref, {
  AirDropPeer? to,
  List<AirDropSource>? files,
}) async {
  final t = AppLocalizations.of(context);
  final chosen = files ?? await pickAirDropFiles(context, ref);
  if (chosen == null || chosen.isEmpty || !context.mounted) return;
  final peer = to ?? await showAirDropPeopleSheet(context);
  if (peer == null || !context.mounted) return;

  const cap = MessagingService.maxFileBytesMesh;
  for (final f in chosen) {
    if (f.size > cap) {
      showGlassToast(
        context,
        t.airdropTooLarge(f.name, cap ~/ (1024 * 1024)),
        tone: ToastTone.danger,
      );
      return;
    }
  }
  final capped = chosen.take(nearbyMaxFiles).toList();
  final total = capped.fold<int>(0, (sum, f) => sum + f.size);
  if (total > AirDropRules.longOverBluetoothBytes) {
    showGlassToast(
      context,
      t.airdropSlowWarning,
      icon: Icons.bluetooth_rounded,
      duration: const Duration(seconds: 3),
    );
  }
  final sent = await ref.read(airdropControllerProvider.notifier).offer(
        peerHex: peer.hex,
        peerName: peer.name,
        files: capped,
      );
  if (!context.mounted) return;
  if (sent == null) {
    showGlassToast(context, t.airdropNoDirect, tone: ToastTone.danger);
    return;
  }
  ref.read(nearbyPageRequestProvider.notifier).state = kAirDropPage;
}

/// Photos and videos from the gallery grid, or documents from the system
/// picker — the same sheet the chat attaches with.
Future<List<AirDropSource>?> pickAirDropFiles(
  BuildContext context,
  WidgetRef ref,
) async {
  final result = await showGlassSheet<MediaPickerResult>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const MediaPickerSheet(allowCaption: false),
  );
  if (result is MediaPickerFile) {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null) return null;
    return [
      for (final f in picked.files)
        if (f.path != null)
          await AirDropSource.fromFile(File(f.path!), name: f.name),
    ];
  }
  if (result is! MediaPickerAssets) return null;
  final quality = await ref.read(mediaQualityProvider.notifier).resolved();
  final out = <AirDropSource>[];
  for (final asset in result.assets.take(nearbyMaxFiles)) {
    final origin = await asset.originFile;
    if (origin == null) continue;
    final title = await asset.titleAsync;
    out.add(
      asset.type == AssetType.image
          ? await _photoForBluetooth(origin, title, quality)
          : await AirDropSource.fromFile(origin, name: title),
    );
  }
  return out;
}

/// Part one moves files over Bluetooth only, so a photo is squeezed the way
/// the chat squeezes one, by "Photo quality". Part two (Wi-Fi) sends
/// originals. A photo the encoder cannot read goes as it is.
Future<AirDropSource> _photoForBluetooth(
  File origin,
  String title,
  MediaQuality quality,
) async {
  final wire = await encodeBytesForMesh(
    await origin.readAsBytes(),
    quality: quality,
  );
  if (wire == null) return AirDropSource.fromFile(origin, name: title);
  final sep = Platform.pathSeparator;
  final dir =
      Directory('${(await getTemporaryDirectory()).path}${sep}airdrop-out');
  if (!await dir.exists()) await dir.create(recursive: true);
  final dot = title.lastIndexOf('.');
  final stem = safeFileName(dot > 0 ? title.substring(0, dot) : title);
  final out = File(
    '${dir.path}$sep${DateTime.now().microsecondsSinceEpoch}-$stem.jpg',
  );
  await out.writeAsBytes(wire, flush: true);
  return AirDropSource(
    file: out,
    name: '$stem.jpg',
    size: wire.length,
    mime: 'image/jpeg',
  );
}
