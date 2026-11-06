package sg.nushhack.mesh

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var ble: BleEngine
    private var sink: EventChannel.EventSink? = null
    private var pendingPerm: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // No foreground service yet, so keep the screen on to stop the OS throttling scans.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ble = BleEngine(applicationContext) { event -> sink?.success(event) }

        EventChannel(messenger, "mesh/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null }
        })

        MethodChannel(messenger, "mesh/methods").setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: SecurityException) {
                result.error("PERMISSION", e.message, null)
            } catch (e: Exception) {
                result.error("ERROR", e.toString(), null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestBlePermissions(result)
            "info" -> result.success(ble.capabilities())
            "startNode" -> ble.startNode(
                call.argument<Int>("nodeId") ?: 0,
                call.argument<Int>("stateHash") ?: 0,
            ) { err -> if (err == null) result.success(null) else result.error("START", err, null) }
            "stopNode" -> { ble.stopNode(); result.success(null) }
            "updateBeacon" -> ble.startBeacon(call.argument<Int>("stateHash") ?: 0) { err ->
                if (err == null) result.success(null) else result.error("BEACON", err, null)
            }
            "sendBlob" -> ble.sendBlob(
                address = call.argument<String>("address")!!,
                data = call.argument<ByteArray>("bytes")!!,
                blobId = call.argument<Number>("blobId")!!.toLong(),
                origin = call.argument<Int>("origin")!!,
                noResponse = call.argument<Boolean>("noResponse") ?: false,
            ) { result.success(it) }
            else -> result.notImplemented()
        }
    }

    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
        ) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun requestBlePermissions(result: MethodChannel.Result) {
        val missing = neededPermissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return result.success(true)
        pendingPerm?.success(false)
        pendingPerm = result
        requestPermissions(missing.toTypedArray(), 42)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 42) return
        pendingPerm?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pendingPerm = null
    }

    override fun onDestroy() {
        if (::ble.isInitialized) ble.stopNode()
        super.onDestroy()
    }
}
