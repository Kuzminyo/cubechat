import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the chosen language is stored.
///
/// Public because the push registration reads it directly instead of waiting
/// for this controller: registration runs at launch, [_restore] is
/// asynchronous, and whichever finishes first decides what the server is told.
/// A registration that wins that race would report `en` for a phone the user
/// set to Ukrainian, and the banner would arrive in the wrong language until
/// something re-registered.
const localePrefsKey = 'app.locale';

class LocaleController extends Notifier<Locale> {
  @override
  Locale build() {
    _restore();
    return const Locale('en');
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(localePrefsKey);
    if (code != null && code.isNotEmpty) {
      state = Locale(code);
    }
  }

  Future<void> set(Locale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(localePrefsKey, locale.languageCode);
  }
}

final localeControllerProvider =
    NotifierProvider<LocaleController, Locale>(LocaleController.new);
