import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'app.locale';

class LocaleController extends Notifier<Locale> {
  @override
  Locale build() {
    _restore();
    return const Locale('en');
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefsKey);
    if (code != null && code.isNotEmpty) {
      state = Locale(code);
    }
  }

  Future<void> set(Locale locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, locale.languageCode);
  }
}

final localeControllerProvider =
    NotifierProvider<LocaleController, Locale>(LocaleController.new);
