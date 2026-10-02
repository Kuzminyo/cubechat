import 'package:flutter/foundation.dart';

import '../../airdrop/data/share_inbox.dart';

/// One thing to send into one chat, out of what another app shared.
@immutable
sealed class ShareStep {
  const ShareStep();
}

/// A link or a line of text, sent as an ordinary message.
class ShareTextStep extends ShareStep {
  const ShareTextStep(this.text);
  final String text;

  @override
  bool operator ==(Object other) =>
      other is ShareTextStep && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A picture, sent the way the gallery sends one.
class SharePictureStep extends ShareStep {
  const SharePictureStep(this.file);
  final SharedFile file;

  @override
  bool operator ==(Object other) =>
      other is SharePictureStep && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;
}

/// Anything else, sent as a file.
class ShareFileStep extends ShareStep {
  const ShareFileStep(this.file);
  final SharedFile file;

  @override
  bool operator ==(Object other) =>
      other is ShareFileStep && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;
}

/// What [bundle] becomes in one chat: the text first — it is usually what
/// the files are about — then each file, a picture as a photo and anything
/// else as a file. A room carries no files, so for one the files that are not
/// pictures are left out; the picker only offers rooms when nothing would be.
List<ShareStep> planShare(SharedBundle bundle, {required bool toChannel}) => [
      if (bundle.text case final text?) ShareTextStep(text),
      for (final file in bundle.files)
        if (isPicture(file))
          SharePictureStep(file)
        else if (!toChannel)
          ShareFileStep(file),
    ];
