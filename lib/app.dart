import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ble/background_mode_controller.dart';
import 'core/locale/locale_controller.dart';
import 'core/routing/app_router.dart';
import 'core/util/app_lifecycle.dart';
import 'core/theme/app_theme.dart';
import 'l10n/app_localizations.dart';

class CubechatApp extends ConsumerStatefulWidget {
  const CubechatApp({super.key});

  @override
  ConsumerState<CubechatApp> createState() => _CubechatAppState();
}

class _CubechatAppState extends ConsumerState<CubechatApp>
    with WidgetsBindingObserver {
  late final _router = buildRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track foreground state so the messaging layer only raises a system
    // notification for messages that arrive while the user isn't looking.
    AppLifecycle.instance.isForeground = state == AppLifecycleState.resumed;
    // The engine is pre-warmed in MainApplication, so main() (and this
    // widget) can build while the app is still headless — and Android 12+
    // forbids starting a foreground service from the background. Re-apply
    // background mode whenever we come to the foreground so the service
    // actually starts (or restarts) from an allowed state.
    if (state == AppLifecycleState.resumed) {
      ref.read(backgroundModeProvider.notifier).apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeControllerProvider);
    // Touch the background-mode controller so it builds at startup and applies
    // the persisted preference. (Foreground-service start is (re)triggered on
    // resume above, since a headless start would be blocked.)
    ref.watch(backgroundModeProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      routerConfig: _router,
    );
  }
}
