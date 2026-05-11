package com.cubechat.cubechat

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        CubechatBlePeripheralPlugin(
            context = applicationContext,
            methodChannel = MethodChannel(messenger, "cubechat/ble_peripheral"),
            eventChannel = EventChannel(messenger, "cubechat/ble_peripheral/events"),
        )
    }
}
