package com.cubechat.cubechat

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.util.UUID

/**
 * Peripheral-role BLE plugin: advertises the cubechat GATT service and hosts
 * three characteristics so other devices acting as centrals can discover and
 * exchange frames with us.
 *
 * Channel: cubechat/ble_peripheral (method) + cubechat/ble_peripheral/events.
 *
 * The plugin keeps its own state machine so the Dart side can issue idempotent
 * start()/stop() calls without worrying about races.
 */
class CubechatBlePeripheralPlugin(
    private val context: Context,
    methodChannel: MethodChannel,
    eventChannel: EventChannel,
) : MethodCallHandler, EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var serviceUuid: UUID? = null
    private var inboundCharUuid: UUID? = null
    private var outboundCharUuid: UUID? = null
    private var peerInfoCharUuid: UUID? = null
    private var peerName: String = ""
    private var pubkeyFingerprint: String? = null
    private var protocolVersion: Int = 1

    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null
    private var inboundChar: BluetoothGattCharacteristic? = null

    // Centrals subscribed to inbound notifications.
    private val subscribers = mutableSetOf<BluetoothDevice>()
    private var running = false

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    // ---------------- MethodChannel ----------------

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "start" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("ARG", "missing arguments", null); return
                }
                try {
                    serviceUuid = UUID.fromString(args["serviceUuid"] as String)
                    inboundCharUuid = UUID.fromString(args["inboundCharUuid"] as String)
                    outboundCharUuid = UUID.fromString(args["outboundCharUuid"] as String)
                    peerInfoCharUuid = UUID.fromString(args["peerInfoCharUuid"] as String)
                    peerName = args["peerName"] as? String ?: ""
                    pubkeyFingerprint = args["pubkeyFingerprint"] as? String
                    protocolVersion = (args["protocolVersion"] as? Int) ?: 1
                } catch (e: Exception) {
                    result.error("ARG", "bad uuid args: ${e.message}", null)
                    return
                }
                result.success(startPeripheral())
            }
            "stop" -> {
                stopPeripheral()
                result.success(null)
            }
            "notifyInbound" -> {
                val data = call.argument<ByteArray>("data")
                if (data == null) {
                    result.error("ARG", "missing data", null); return
                }
                result.success(notifyInbound(data))
            }
            else -> result.notImplemented()
        }
    }

    // ---------------- EventChannel ----------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ---------------- Core logic ----------------

    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return false
        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        val adapter = mgr.adapter ?: return false
        // NOTE: do NOT gate on isMultipleAdvertisementSupported(). That asks
        // whether the chipset can run SEVERAL concurrent advertisements;
        // cubechat runs exactly one, and plenty of phones that advertise fine
        // answer false. Gating on it switched the peripheral off on capable
        // hardware, so the device never became discoverable.
        //
        // bluetoothLeAdvertiser is null while Bluetooth is off, so a false here
        // can also just mean "adapter down" - the Dart side checks the adapter
        // first and retries when it comes back on.
        return try {
            adapter.bluetoothLeAdvertiser != null
        } catch (e: SecurityException) {
            android.util.Log.w("CubechatBlePeripheral", "isSupported: denied", e)
            false
        }
    }

    private fun ensurePermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val need = listOf(
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
            return need.all {
                ActivityCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
        }
        return true
    }

    private fun startPeripheral(): Boolean {
        if (running) {
            emitLog("startPeripheral: already running")
            return true
        }
        if (!isSupported()) {
            emitLog("startPeripheral: not supported (no BT LE / advertiser / multi-advertisement)")
            return false
        }
        if (!ensurePermissions()) {
            emitLog("startPeripheral: missing permissions BLUETOOTH_ADVERTISE/CONNECT")
            return false
        }

        val mgr = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = mgr.adapter
        if (adapter == null) {
            emitLog("startPeripheral: no BT adapter")
            return false
        }
        if (!adapter.isEnabled) {
            emitLog("startPeripheral: BT adapter is OFF")
            return false
        }

        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            emitLog("startPeripheral: bluetoothLeAdvertiser is null")
            return false
        }

        // 1. GATT server with our service.
        val server = mgr.openGattServer(context, gattCallback)
        if (server == null) {
            emitLog("startPeripheral: openGattServer returned null")
            return false
        }
        emitLog("startPeripheral: gatt server opened")
        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        )

        val inbound = BluetoothGattCharacteristic(
            inboundCharUuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        ).also {
            // CCCD descriptor so centrals can subscribe to notifications.
            it.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                )
            )
        }
        val outbound = BluetoothGattCharacteristic(
            outboundCharUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val peerInfo = BluetoothGattCharacteristic(
            peerInfoCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        ).apply { value = encodePeerInfo() }

        service.addCharacteristic(inbound)
        service.addCharacteristic(outbound)
        service.addCharacteristic(peerInfo)
        if (!server.addService(service)) {
            emitLog("addService returned false synchronously")
            server.close()
            return false
        }
        emitLog("addService queued, awaiting onServiceAdded…")

        gattServer = server
        inboundChar = inbound

        // 2. Advertise.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val advertiseData = AdvertiseData.Builder()
            .setIncludeTxPowerLevel(false)
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()

        // Device name goes in scan response to save room in the primary packet.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

        return try {
            advertiser?.startAdvertising(settings, advertiseData, scanResponse, advertiseCallback)
            emitLog("advertiser.startAdvertising called")
            running = true
            true
        } catch (e: SecurityException) {
            emitLog("advertise denied (SecurityException): ${e.message}")
            stopPeripheral()
            false
        }
    }

    private fun stopPeripheral() {
        running = false
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: SecurityException) {
            // ignore
        }
        advertiser = null
        try {
            gattServer?.close()
        } catch (_: SecurityException) {
            // ignore
        }
        gattServer = null
        inboundChar = null
        subscribers.clear()
    }

    private fun notifyInbound(data: ByteArray): Boolean {
        val server = gattServer ?: run {
            Log.w(TAG, "notifyInbound: no gattServer")
            return false
        }
        val ch = inboundChar ?: run {
            Log.w(TAG, "notifyInbound: no inboundChar")
            return false
        }
        if (subscribers.isEmpty()) {
            Log.w(TAG, "notifyInbound: no subscribers (central did not enable CCCD)")
            return false
        }
        var anySuccess = false
        for (dev in subscribers.toList()) {
            try {
                val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    // Atomic value+notify required on Android 13+; the deprecated
                    // ch.value=... + notifyCharacteristicChanged(dev, ch, false)
                    // pair stopped being atomic and would race or send stale bytes.
                    val res = server.notifyCharacteristicChanged(dev, ch, false, data)
                    if (res != BluetoothStatusCodes.SUCCESS) {
                        Log.w(TAG, "notifyCharacteristicChanged returned status=$res for ${dev.address}")
                    }
                    res == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    val ok = run {
                        ch.value = data
                        server.notifyCharacteristicChanged(dev, ch, false)
                    }
                    if (!ok) {
                        Log.w(TAG, "notifyCharacteristicChanged returned false for ${dev.address}")
                    }
                    ok
                }
                if (ok) anySuccess = true
            } catch (e: SecurityException) {
                Log.w(TAG, "notifyInbound permission denied for ${dev.address}", e)
                return false
            }
        }
        return anySuccess
    }

    private fun encodePeerInfo(): ByteArray {
        // Tiny self-describing payload: version(1) | flags(1) | name | " " | fingerprint
        val name = peerName.encodeToByteArray()
        val fp = pubkeyFingerprint?.encodeToByteArray() ?: ByteArray(0)
        return ByteArray(2 + name.size + 1 + fp.size).also { buf ->
            buf[0] = protocolVersion.toByte()
            buf[1] = if (fp.isNotEmpty()) 0x01 else 0x00
            System.arraycopy(name, 0, buf, 2, name.size)
            buf[2 + name.size] = 0
            System.arraycopy(fp, 0, buf, 2 + name.size + 1, fp.size)
        }
    }

    // ---------------- BLE callbacks ----------------

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            emitLog("advertise onStartSuccess: $settingsInEffect")
            emit(mapOf("type" to "advertising", "ok" to true))
        }

        override fun onStartFailure(errorCode: Int) {
            running = false
            emitLog("advertise onStartFailure code=$errorCode " +
                "(1=DATA_TOO_LARGE 2=TOO_MANY_ADVERTISERS 3=ALREADY_STARTED " +
                "4=INTERNAL_ERROR 5=FEATURE_UNSUPPORTED)")
            emit(mapOf("type" to "advertising", "ok" to false, "errorCode" to errorCode))
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            emitLog("onServiceAdded status=$status service=${service.uuid} " +
                "(0=SUCCESS, other = registration FAILED)")
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            emitLog("connection state change ${device.address}: status=$status newState=$newState")
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    emit(mapOf("type" to "connected", "centralId" to device.address))
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    subscribers.remove(device)
                    emit(mapOf("type" to "disconnected", "centralId" to device.address))
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val server = gattServer ?: return
            val payload = if (characteristic.uuid == peerInfoCharUuid) encodePeerInfo() else ByteArray(0)
            val sliced = if (offset >= payload.size) ByteArray(0)
            else payload.copyOfRange(offset, payload.size)
            try {
                server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, sliced)
            } catch (_: SecurityException) {
                // ignore
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            Log.d(TAG, "write from ${device.address} on ${characteristic.uuid} (${value.size}B)")
            if (characteristic.uuid == outboundCharUuid) {
                emit(
                    mapOf(
                        "type" to "write",
                        "centralId" to device.address,
                        "charUuid" to characteristic.uuid.toString(),
                        "data" to value,
                    )
                )
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (_: SecurityException) {
                    // ignore
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            // CCCD subscribe/unsubscribe.
            if (descriptor.uuid == CCCD_UUID) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                    value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                ) {
                    subscribers.add(device)
                    Log.d(TAG, "central ${device.address} subscribed (subscribers=${subscribers.size})")
                } else {
                    subscribers.remove(device)
                    Log.d(TAG, "central ${device.address} unsubscribed")
                }
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (_: SecurityException) {
                    // ignore
                }
            }
        }
    }

    private fun emit(map: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(map) }
    }

    /// Emit a free-form log line that the Dart side prints into DebugLog with
    /// the [PERIPH-NATIVE] tag — much more useful than Log.d() which only lives
    /// in adb logcat.
    private fun emitLog(message: String) {
        Log.d(TAG, message)
        mainHandler.post {
            eventSink?.success(mapOf("type" to "log", "message" to message))
        }
    }

    companion object {
        private const val TAG = "CubechatBlePeripheral"
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
