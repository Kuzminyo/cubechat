import 'package:flutter/material.dart';

/// The sections of the profile, each with the icon its row carries.
///
/// The badges were fixed iOS-style colours at first — blue, green, red,
/// purple — and on the phone they read as stickers on the glass rather than
/// part of it. The owner asked for glass badges in the theme's colour, so the
/// colour now comes from `AppColors` at paint time (see `SettingsSectionRow`)
/// and a section carries only its icon.
enum SettingsSection {
  cubeId(Icons.alternate_email_rounded),
  privacy(Icons.shield_rounded),
  notifications(Icons.notifications_rounded),
  connection(Icons.radar_rounded),
  chats(Icons.chat_bubble_rounded),
  appearance(Icons.palette_rounded),
  data(Icons.folder_rounded),
  about(Icons.info_rounded),

  /// Not a section — the emergency wipe row under them, which acts in place.
  wipe(Icons.delete_forever_rounded);

  const SettingsSection(this.icon);
  final IconData icon;
}
