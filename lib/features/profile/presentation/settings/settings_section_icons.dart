import 'package:flutter/material.dart';

/// The sections of the profile, each with the icon and colour its row carries.
///
/// Fixed colours on purpose — the one exception to "colours come from
/// AppColors": a section's badge is a label to recognise at a glance, the way
/// iOS Settings does it, not a surface that should take the theme's tint. A
/// rose theme that turned every badge rose would leave eight identical squares.
enum SettingsSection {
  cubeId(Icons.alternate_email_rounded, Color(0xFF2E8CFF)),
  privacy(Icons.shield_rounded, Color(0xFF12A86B)),
  notifications(Icons.notifications_rounded, Color(0xFFFF4F64)),
  connection(Icons.radar_rounded, Color(0xFF8A5CF6)),
  chats(Icons.chat_bubble_rounded, Color(0xFFF5A524)),
  appearance(Icons.palette_rounded, Color(0xFFE14EA8)),
  data(Icons.folder_rounded, Color(0xFF3BA7C9)),
  about(Icons.info_rounded, Color(0xFF6B7A73)),

  /// Not a section — the emergency wipe row under them, which acts in place.
  wipe(Icons.delete_forever_rounded, Color(0xFFE5384D));

  const SettingsSection(this.icon, this.color);
  final IconData icon;
  final Color color;
}
