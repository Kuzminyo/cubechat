import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/locale/locale_controller.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'l10n/app_localizations.dart';

class CubechatApp extends ConsumerStatefulWidget {
  const CubechatApp({super.key});

  @override
  ConsumerState<CubechatApp> createState() => _CubechatAppState();
}

class _CubechatAppState extends ConsumerState<CubechatApp> {
  late final _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeControllerProvider);
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
