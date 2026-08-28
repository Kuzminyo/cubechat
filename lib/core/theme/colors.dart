import 'package:flutter/material.dart';

/// Palette extracted from the Cubegram glass mockup.
///
/// Every field here is mutable and rewritten by `ThemeController` when a
/// palette is chosen — see that class for why the colours are pushed into
/// statics instead of down through a `Theme`.
abstract final class AppColors {
  // Base background
  static Color bgDeep = Color(0xFF06140D);
  static Color bgTop = Color(0xFF0D2818);
  static Color bgBottom = Color(0xFF0A3D28);

  // Aurora accents
  static Color aurora1 = Color(0xFF2EDB8F);
  static Color aurora2 = Color(0xFF7FD9A6);
  static Color aurora3 = Color(0xFF34D399);
  static Color aurora4 = Color(0xFFA3E635);

  // Primary brand
  static Color brandPrimary = Color(0xFF2EDB8F);
  static Color brandSecondary = Color(0xFF7FD9A6);
  static LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandPrimary, brandSecondary],
  );

  /// The wash behind letters a search has found, and the ink to write them in.
  ///
  /// Deliberately not the brand colour and deliberately **not** rewritten by
  /// `ThemeController`. A found word has one job — to be seen from across the
  /// screen — and a green mark on this green interface disappeared into it,
  /// which was the report. Amber is the one hue nothing else here uses, so it
  /// reads as "this is what you were looking for" rather than as decoration,
  /// and it stays legible whatever palette the user has chosen.
  ///
  /// Opaque, with dark ink on top: a translucent mark takes the colour of
  /// whatever bubble it lands on, so the same highlight was strong on one
  /// message and invisible on the next.
  static const Color searchHighlight = Color(0xFFFFC53D);
  static const Color searchHighlightInk = Color(0xFF10231A);

  /// What "white" means for a pane of glass under the current palette.
  ///
  /// Every surface in the app is white at some low opacity over the aurora, and
  /// for a long time that was literally `Colors.white` — which is why changing
  /// the palette moved the accents and left the interface itself the same grey
  /// it always was. This is white pulled some way toward the palette's tint, so
  /// a rose theme is genuinely a rose interface rather than a grey one with
  /// pink buttons. Rewritten by `ThemeController`; call it through [glass].
  static Color glassBase = Colors.white;

  /// The same idea for text and icons, tinted far more lightly — legibility is
  /// the point of a label, and a saturated one reads as a link.
  static Color inkBase = Colors.white;

  /// A glass surface at [alpha]: fills, borders, dividers, scrims.
  static Color glass(double alpha) => glassBase.withValues(alpha: alpha);

  /// Text or an icon at [alpha], over glass.
  static Color ink(double alpha) => inkBase.withValues(alpha: alpha);

  /// The *dark* end of a pane of glass, and of any scrim laid over a photo.
  ///
  /// [glassBase] is the light end — the whisper of white at the top of a pane —
  /// and it has followed the palette for a while. The dark end had not: it was
  /// literally `Colors.black`, chosen so a pane would "contribute no colour of
  /// its own". Under the emerald palette that reads as intended, because a
  /// black pane over a green aurora goes green. Under rose or fuchsia the same
  /// pane is a black bar sitting on a pink screen — the nav bar, the composer,
  /// the strip of actions on a profile, each one a slab of a different app.
  ///
  /// So the dark end is the palette's own near-black, tinted a little further
  /// toward its hue. Same depth, same contrast, and the blur behind it comes
  /// out the colour of the theme rather than of nothing.
  static Color paneBase = Color(0xFF06140D);

  /// The pane's dark at [alpha] — see [paneBase].
  static Color pane(double alpha) => paneBase.withValues(alpha: alpha);

  // Glass surface tints (the palette's white at varying opacity)
  static Color glassFill = Colors.white.withValues(alpha: 0.08);
  static Color glassFillStrong = Colors.white.withValues(alpha: 0.12);
  static Color glassBorder = Colors.white.withValues(alpha: 0.18);
  static Color glassBorderStrong = Colors.white.withValues(alpha: 0.22);
  static Color glassHover = Colors.white.withValues(alpha: 0.06);

  // Text
  static Color textPrimary = Color(0xFFE8E8F0);
  static Color textOnGlass = Colors.white.withValues(alpha: 0.95);
  static Color textOnGlassDim = Colors.white.withValues(alpha: 0.6);

  /// The third tier of text: timestamps, hints, the line under a row.
  ///
  /// 0.52, not the 0.4 it was for a long time, because 0.4 did not pass.
  ///
  /// > **Design guideline — Accessibility > Vision**: text up to 17 pt needs a
  /// > contrast ratio of at least 4.5:1 against its background.
  ///
  /// Composited over a pane at the emerald palette's own dark (about #0E1F16,
  /// which is the *most* favourable case — a glass pane is darker than the
  /// aurora behind it), white at 0.4 lands on #6E7874 and measures **3.75:1**.
  /// Every one of the 99 places this colour is read was therefore below the
  /// floor, and this tier is where the smallest type in the app lives, which
  /// is the combination the guideline is specifically about.
  ///
  /// 0.52 measures **5.4:1** on the same background, so it keeps its margin on
  /// the lighter palettes and over a photo. Still visibly the quiet tier —
  /// [textOnGlassDim] at 0.6 is 6.8:1 and reads as ordinary secondary text, so
  /// there is room for a third level between that and the floor.
  static Color textOnGlassFaint = Colors.white.withValues(alpha: 0.52);

  // Semantic
  static const Color danger = Color(0xFFFF5A6B);
  static const Color warning = Color(0xFFF5C26B);
  static Color online = Color(0xFF2EDB8F);

  /// The two-colour gradient a stable seed maps to, for an identity with no
  /// photo of its own.
  ///
  /// Derived from the live palette rather than hand-picked. The five variants
  /// used to be a `const` list of emerald greens copied into three files, so
  /// somebody on the indigo theme had a blue app full of green faces, and
  /// switching themes changed everything except the one thing standing in for
  /// a person. Same seed still lands on the same variant, so an identity's
  /// colour is as stable as it ever was — it just belongs to the theme now.
  /// The colour one person's name is written in inside a room.
  ///
  /// A room mixes senders, and a single accent for all of them answers "this
  /// is not you" without answering "this is who". Telegram gives each person a
  /// hue; so does this, with the restraint the palette is built on — the hue
  /// turns, and saturation and lightness stay where the brand colour holds
  /// them, so six people are six colours of the same weight rather than a
  /// rainbow dropped onto the interface.
  ///
  /// Deterministic from the author's id, so the same person is the same colour
  /// on every phone and across restarts.
  static Color authorTint(String seed) {
    final base = HSLColor.fromColor(brandPrimary);
    const steps = 6;
    final turn = (seed.hashCode.abs() % steps) * (300 / steps);
    return base.withHue((base.hue + turn) % 360).toColor();
  }

  static List<Color> identityGradient(String seed) {
    final a = brandPrimary;
    final b = brandSecondary;
    final variants = <List<Color>>[
      [a, b],
      [b, a],
      [a, Color.lerp(a, b, 0.55)!],
      [Color.lerp(b, a, 0.55)!, b],
      [Color.lerp(a, b, 0.25)!, Color.lerp(a, b, 0.9)!],
    ];
    return variants[seed.hashCode.abs() % variants.length];
  }
}
