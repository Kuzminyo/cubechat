import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/file_bubble.dart' show formatBytes;
import '../domain/airdrop_transfer.dart';

/// "3 photos", "2 videos", "5 files" from the files' types — the first two
/// only when every file is one, as the spec's "Жека хоче надіслати 3 фото ·
/// 12 МБ". Takes types rather than files so a history line can use it too.
String airdropWhat(AppLocalizations t, List<String> mimes) {
  final n = mimes.length;
  if (mimes.every((m) => m.startsWith('image/'))) return t.airdropWhatPhotos(n);
  if (mimes.every((m) => m.startsWith('video/'))) return t.airdropWhatVideos(n);
  return t.airdropWhatFiles(n);
}

String airdropRequestBody(AppLocalizations t, AirDropTransfer transfer) =>
    t.airdropRequestBody(
      airdropWhat(t, [for (final f in transfer.files) f.mime]),
      formatBytes(transfer.totalBytes),
    );
