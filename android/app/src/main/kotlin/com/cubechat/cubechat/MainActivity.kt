package com.cubechat.cubechat

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Attaches to the long-lived cached engine created in [MainApplication]
 * instead of creating its own. Because the engine is owned by the
 * Application, FlutterActivity won't destroy it when the Activity is
 * finished/swiped — so the Dart isolate (and BLE) keeps running in the
 * background. Channels + plugins are registered once on that engine in
 * MainApplication, so there's nothing to configure here.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(MainApplication.ENGINE_ID)
            ?: super.provideFlutterEngine(context)
    }
}
