package sg.nushhack.ble_lab

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import java.nio.ByteBuffer
import java.util.UUID
import java.util.zip.CRC32
import kotlin.random.Random

/**
 * Phase 0 BLE feasibility engine.
 *
 * Every node runs at once:
 *  - a GATT server with one writable characteristic (DATA_IN) that reassembles blobs,
 *  - a legacy connectable beacon: service UUID in the advert, [nodeId, stateHash] in the scan response,
 *  - one scan, filtered on the service UUID.
 * A sender connects as a GATT client, negotiates the MTU and writes a framed, chunked blob.
 *
 * Wire frames (one per characteristic write):
 *   START: [0][blobId:8][total:4][origin:4][sender:4][crc32:4]
 *   DATA : [1][seq:2][payload...]
 *   END  : [2]                        (the server checks the length and CRC and fails the write if they're wrong)
 *
 * All callbacks are posted to the main thread, so state needs no locks.
 */
@SuppressLint("MissingPermission")
class BleLab(private val ctx: Context, private val emit: (Map<String, Any?>) -> Unit) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7e1a0001-6d65-7368-2d6c-61622d6e7573")
        val DATA_IN_UUID: UUID = UUID.fromString("7e1a0002-6d65-7368-2d6c-61622d6e7573")
        const val T_START: Byte = 0
        const val T_DATA: Byte = 1
        const val T_END: Byte = 2
        const val MAX_ATT_VALUE = 512
        const val MAX_BLOB = 2 * 1024 * 1024
        const val GATT_APP_ERROR = 0x80
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter get() = manager.adapter

    val nodeId: Int by lazy {
        val prefs = ctx.getSharedPreferences("ble_lab", Context.MODE_PRIVATE)
        var id = prefs.getInt("nodeId", 0)
        if (id == 0) {
            id = Random.nextInt().let { if (it == 0) 1 else it }
            prefs.edit().putInt("nodeId", id).apply()
        }
        id
    }

    private fun ev(type: String, data: Map<String, Any?> = emptyMap()) {
        val m = HashMap<String, Any?>(data)
        m["type"] = type
        m["t"] = System.currentTimeMillis()
        main.post { emit(m) }
    }

    private fun log(msg: String) = ev("log", mapOf("msg" to msg))

    // ---------------------------------------------------------------- capabilities

    fun capabilities(): Map<String, Any?> {
        val a = adapter
        val m = linkedMapOf<String, Any?>(
            "nodeId" to nodeId,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "androidSdk" to Build.VERSION.SDK_INT,
            "bluetoothEnabled" to (a?.isEnabled == true),
            "multipleAdvertisement" to a?.isMultipleAdvertisementSupported,
            "offloadedFiltering" to a?.isOffloadedFilteringSupported,
        )
        if (a != null && Build.VERSION.SDK_INT >= 26) {
            m["extendedAdvertising"] = a.isLeExtendedAdvertisingSupported
            m["periodicAdvertising"] = a.isLePeriodicAdvertisingSupported
            m["le2MPhy"] = a.isLe2MPhySupported
            m["leCodedPhy"] = a.isLeCodedPhySupported
            m["maxAdvDataLength"] = a.leMaximumAdvertisingDataLength
        }
        return m
    }

    // ---------------------------------------------------------------- node lifecycle

    fun startNode(stateHash: Int, done: (String?) -> Unit) {
        val a = adapter
        if (a == null || !a.isEnabled) return done("Bluetooth is off or missing")
        startServer()?.let { return done(it) }
        startScan()?.let { return done(it) }
        startBeacon(stateHash, done)
    }

    fun stopNode() {
        stopBeacon()
        stopScan()
        stopServer()
        log("node stopped")
    }

    // ---------------------------------------------------------------- beacon

    private var beaconCb: AdvertiseCallback? = null

    fun startBeacon(stateHash: Int, done: (String?) -> Unit) {
        stopBeacon()
        val adv = adapter?.bluetoothLeAdvertiser ?: return done("no BLE advertiser (peripheral mode unsupported?)")
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val payload = ByteBuffer.allocate(8).putInt(nodeId).putInt(stateHash).array()
        val scanResp = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceData(ParcelUuid(SERVICE_UUID), payload)
            .build()
        var answered = false
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                main.post {
                    log("beacon up: node=${hex(nodeId)} state=${hex(stateHash)}")
                    if (!answered) { answered = true; done(null) }
                }
            }

            override fun onStartFailure(errorCode: Int) {
                main.post {
                    log("beacon FAILED: ${advError(errorCode)}")
                    if (!answered) { answered = true; done("advertise failed: ${advError(errorCode)}") }
                }
            }
        }
        beaconCb = cb
        adv.startAdvertising(settings, data, scanResp, cb)
    }

    fun stopBeacon() {
        beaconCb?.let { runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(it) } }
        beaconCb = null
    }

    // ---------------------------------------------------------------- scanning

    private var scanCb: ScanCallback? = null
    private val lastPeerEmit = HashMap<String, Long>()

    private fun startScan(): String? {
        if (scanCb != null) return null
        val scanner = adapter?.bluetoothLeScanner ?: return "no BLE scanner"
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                main.post { onPeer(result) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                main.post { results.forEach { onPeer(it) } }
            }

            override fun onScanFailed(errorCode: Int) {
                log("scan FAILED: code=$errorCode")
                main.post { scanCb = null }
            }
        }
        scanCb = cb
        scanner.startScan(listOf(filter), settings, cb)
        log("scan started (filtered on service UUID)")
        return null
    }

    private fun onPeer(r: ScanResult) {
        val addr = r.device.address
        val now = SystemClock.elapsedRealtime()
        if (now - (lastPeerEmit[addr] ?: 0L) < 700) return
        lastPeerEmit[addr] = now
        val sd = r.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID))
        val m = hashMapOf<String, Any?>("address" to addr, "rssi" to r.rssi)
        if (sd != null && sd.size >= 8) {
            val bb = ByteBuffer.wrap(sd)
            m["nodeId"] = bb.int
            m["stateHash"] = bb.int
        }
        if (Build.VERSION.SDK_INT >= 26) m["connectable"] = r.isConnectable
        ev("peer", m)
    }

    private fun stopScan() {
        scanCb?.let { runCatching { adapter?.bluetoothLeScanner?.stopScan(it) } }
        scanCb = null
    }

    // ---------------------------------------------------------------- GATT server (receiver)

    private var server: BluetoothGattServer? = null
    private val serverConns = HashSet<String>()

    private class Inbound(
        val blobId: Long, val total: Int, val origin: Int, val sender: Int, val crc: Long,
    ) {
        val buf = ByteArray(total)
        var got = 0
        var nextSeq = 0
        val started = SystemClock.elapsedRealtime()
    }

    private val inbound = HashMap<String, Inbound>()

    /**
     * Simulated range limit for hop tests. When on, the server only accepts blobs whose
     * sender nodeId is in [allowedSenders]. Dart keeps that set to the peers whose
     * smoothed RSSI is above the threshold.
     */
    private var rangeFilter = false
    private var allowedSenders: Set<Int> = emptySet()

    fun setRangeFilter(enabled: Boolean, allowed: List<Int>) {
        rangeFilter = enabled
        allowedSenders = allowed.toSet()
    }

    private val serverCb = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                val addr = device.address
                if (newState == BluetoothProfile.STATE_CONNECTED) serverConns.add(addr)
                else { serverConns.remove(addr); inbound.remove(addr) }
                ev("serverConn", mapOf(
                    "address" to addr,
                    "connected" to (newState == BluetoothProfile.STATE_CONNECTED),
                    "status" to status,
                    "count" to serverConns.size,
                ))
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            log("server: ${device.address} MTU=$mtu")
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            main.post {
                val status = if (characteristic.uuid == DATA_IN_UUID && !preparedWrite && offset == 0 && value != null)
                    handleFrame(device.address, value) else GATT_APP_ERROR
                if (responseNeeded) server?.sendResponse(device, requestId, status, 0, null)
            }
        }
    }

    private fun startServer(): String? {
        if (server != null) return null
        val s = manager.openGattServer(ctx, serverCb) ?: return "openGattServer returned null"
        val svc = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(
            BluetoothGattCharacteristic(
                DATA_IN_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
        )
        if (!s.addService(svc)) { s.close(); return "addService failed" }
        server = s
        log("GATT server up")
        return null
    }

    private fun stopServer() {
        server?.let { s ->
            serverConns.toList().forEach { runCatching { s.cancelConnection(adapter.getRemoteDevice(it)) } }
            runCatching { s.close() }
        }
        server = null
        serverConns.clear()
        inbound.clear()
    }

    private fun handleFrame(addr: String, v: ByteArray): Int {
        if (v.isEmpty()) return GATT_APP_ERROR
        val bb = ByteBuffer.wrap(v)
        when (bb.get()) {
            T_START -> {
                if (v.size < 25) return GATT_APP_ERROR
                val blobId = bb.long
                val total = bb.int
                val origin = bb.int
                val sender = bb.int
                val crc = bb.int.toLong() and 0xffffffffL
                if (total < 0 || total > MAX_BLOB) return GATT_APP_ERROR
                if (rangeFilter && sender !in allowedSenders) {
                    log("server: rejected blob from ${hex(sender)}: outside simulated range")
                    return GATT_APP_ERROR
                }
                inbound[addr] = Inbound(blobId, total, origin, sender, crc)
            }
            T_DATA -> {
                val ib = inbound[addr] ?: return GATT_APP_ERROR
                if (v.size < 3) return GATT_APP_ERROR
                val seq = bb.short.toInt() and 0xffff
                if (seq != ib.nextSeq) {
                    log("server: seq gap from $addr: expected ${ib.nextSeq} got $seq")
                    inbound.remove(addr)
                    return GATT_APP_ERROR
                }
                val n = v.size - 3
                if (ib.got + n > ib.total) { inbound.remove(addr); return GATT_APP_ERROR }
                System.arraycopy(v, 3, ib.buf, ib.got, n)
                ib.got += n
                ib.nextSeq = (ib.nextSeq + 1) and 0xffff
            }
            T_END -> {
                val ib = inbound.remove(addr) ?: return GATT_APP_ERROR
                val crc = CRC32().apply { update(ib.buf) }.value
                val ok = ib.got == ib.total && crc == ib.crc
                ev("blob", mapOf(
                    "from" to addr,
                    "blobId" to ib.blobId,
                    "origin" to ib.origin,
                    "sender" to ib.sender,
                    "size" to ib.total,
                    "ok" to ok,
                    "ms" to (SystemClock.elapsedRealtime() - ib.started),
                    "bytes" to if (ok) ib.buf else null,
                ))
                return if (ok) BluetoothGatt.GATT_SUCCESS else GATT_APP_ERROR
            }
            else -> return GATT_APP_ERROR
        }
        return BluetoothGatt.GATT_SUCCESS
    }

    // ---------------------------------------------------------------- GATT client (sender)

    fun sendBlob(
        address: String, data: ByteArray, blobId: Long, origin: Int, noResponse: Boolean,
        done: (Map<String, Any?>) -> Unit,
    ) {
        Transfer(address, data, blobId, origin, noResponse, done).start()
    }

    private inner class Transfer(
        val address: String, val data: ByteArray, val blobId: Long, val origin: Int,
        val noResponse: Boolean, val done: (Map<String, Any?>) -> Unit,
    ) {
        var gatt: BluetoothGatt? = null
        var ch: BluetoothGattCharacteristic? = null
        var mtu = 23
        var frames: List<ByteArray> = emptyList()
        var idx = 0
        var busyRetries = 0
        var stage = "connect"
        var finished = false
        val t0 = SystemClock.elapsedRealtime()
        var tReady = 0L
        val timeout = Runnable { fail("timeout during $stage") }

        fun arm(ms: Long) { main.removeCallbacks(timeout); main.postDelayed(timeout, ms) }

        fun start() {
            val dev = try { adapter.getRemoteDevice(address) } catch (e: Exception) { return fail("bad address") }
            arm(12_000)
            log("tx → $address: connecting (${data.size} B, ${if (noResponse) "no-rsp" else "with-rsp"})")
            gatt = if (Build.VERSION.SDK_INT >= 26)
                dev.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK)
            else dev.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) fail("connectGatt returned null")
        }

        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                main.post {
                    if (finished) return@post
                    if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                        stage = "mtu"
                        arm(6_000)
                        if (!g.requestMtu(517)) { stage = "discover"; g.discoverServices() }
                    } else {
                        fail("link lost (status=$status) during $stage")
                    }
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
                main.post {
                    if (finished || stage != "mtu") return@post
                    mtu = if (status == BluetoothGatt.GATT_SUCCESS) newMtu else 23
                    stage = "discover"
                    arm(6_000)
                    if (!g.discoverServices()) fail("discoverServices refused")
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                main.post {
                    if (finished) return@post
                    ch = g.getService(SERVICE_UUID)?.getCharacteristic(DATA_IN_UUID)
                    if (ch == null) return@post fail("lab service not found on peer (status=$status)")
                    frames = buildFrames()
                    tReady = SystemClock.elapsedRealtime()
                    stage = "write"
                    writeNext()
                }
            }

            override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                main.post {
                    if (finished) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) return@post fail("write #$idx rejected (status=$status)")
                    idx++
                    writeNext()
                }
            }
        }

        fun buildFrames(): List<ByteArray> {
            val chunk = minOf(mtu - 3, MAX_ATT_VALUE) - 3
            val crc = CRC32().apply { update(data) }.value
            val out = ArrayList<ByteArray>()
            out += ByteBuffer.allocate(25).put(T_START).putLong(blobId).putInt(data.size)
                .putInt(origin).putInt(nodeId).putInt(crc.toInt()).array()
            var off = 0
            var seq = 0
            while (off < data.size) {
                val n = minOf(chunk, data.size - off)
                out += ByteBuffer.allocate(3 + n).put(T_DATA).putShort(seq.toShort()).put(data, off, n).array()
                off += n
                seq++
            }
            out += byteArrayOf(T_END)
            return out
        }

        fun writeNext() {
            if (idx >= frames.size) return succeed()
            val g = gatt ?: return fail("no gatt")
            val c = ch ?: return fail("no characteristic")
            val f = frames[idx]
            // START/END always need an ack. DATA can skip it to test throughput.
            val type = if (noResponse && f[0] == T_DATA) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                       else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            arm(6_000)
            val accepted = if (Build.VERSION.SDK_INT >= 33) {
                g.writeCharacteristic(c, f, type) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                c.writeType = type
                @Suppress("DEPRECATION")
                c.value = f
                @Suppress("DEPRECATION")
                g.writeCharacteristic(c)
            }
            if (!accepted) {
                // Stack busy (common on no-response writes); back off briefly.
                if (++busyRetries > 200) return fail("write #$idx: stack stayed busy")
                main.postDelayed({ if (!finished) writeNext() }, 10)
            }
        }

        fun succeed() {
            val now = SystemClock.elapsedRealtime()
            val xferMs = (now - tReady).coerceAtLeast(1)
            finish(mapOf(
                "ok" to true,
                "address" to address,
                "bytes" to data.size,
                "mtu" to mtu,
                "frames" to frames.size,
                "totalMs" to (now - t0),
                "setupMs" to (tReady - t0),
                "transferMs" to xferMs,
                "kBps" to data.size.toDouble() / xferMs,
                "busyRetries" to busyRetries,
            ))
        }

        fun fail(why: String) {
            finish(mapOf(
                "ok" to false, "address" to address, "error" to why, "stage" to stage,
                "mtu" to mtu, "framesSent" to idx, "totalMs" to (SystemClock.elapsedRealtime() - t0),
            ))
        }

        fun finish(result: Map<String, Any?>) {
            if (finished) return
            finished = true
            main.removeCallbacks(timeout)
            gatt?.let { g -> runCatching { g.disconnect() }; main.postDelayed({ runCatching { g.close() } }, 300) }
            main.post { done(result) }
        }
    }

    // ---------------------------------------------------------------- capability tests

    /** Starts a non-legacy advertising set with a large payload. */
    fun testExtendedAdvertising(done: (Map<String, Any?>) -> Unit) {
        val a = adapter
        if (Build.VERSION.SDK_INT < 26 || a == null) return done(mapOf("ok" to false, "error" to "API < 26"))
        if (!a.isLeExtendedAdvertisingSupported) return done(mapOf("ok" to false, "error" to "not supported by controller"))
        val adv = a.bluetoothLeAdvertiser ?: return done(mapOf("ok" to false, "error" to "no advertiser"))
        val payloadSize = (a.leMaximumAdvertisingDataLength - 24).coerceIn(8, 200)
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(false)
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_LOW)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
            .setPrimaryPhy(BluetoothDevice.PHY_LE_1M)
            .setSecondaryPhy(BluetoothDevice.PHY_LE_1M)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceData(ParcelUuid(SERVICE_UUID), ByteArray(payloadSize) { it.toByte() })
            .build()
        var answered = false
        val cb = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                main.post {
                    if (answered) return@post
                    answered = true
                    adv.stopAdvertisingSet(this)
                    done(mapOf(
                        "ok" to (status == ADVERTISE_SUCCESS),
                        "status" to status,
                        "payloadBytes" to payloadSize,
                        "txPower" to txPower,
                    ))
                }
            }
        }
        adv.startAdvertisingSet(params, data, null, null, null, cb)
        main.postDelayed({
            if (!answered) { answered = true; runCatching { adv.stopAdvertisingSet(cb) }; done(mapOf("ok" to false, "error" to "no callback in 4s")) }
        }, 4000)
    }

    /** Starts up to [n] extra legacy advertisers next to the beacon and counts how many the controller accepts. */
    fun testMultiAdvertising(n: Int, done: (Map<String, Any?>) -> Unit) {
        val adv = adapter?.bluetoothLeAdvertiser ?: return done(mapOf("ok" to false, "error" to "no advertiser"))
        val cbs = ArrayList<AdvertiseCallback>()
        val results = arrayOfNulls<String>(n)
        var answered = 0
        fun finishIfDone() {
            if (answered < n) return
            cbs.forEach { runCatching { adv.stopAdvertising(it) } }
            done(mapOf(
                "ok" to true,
                "requested" to n,
                "started" to results.count { it == "ok" },
                "beaconRunning" to (beaconCb != null),
                "results" to results.toList(),
            ))
        }
        for (i in 0 until n) {
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setConnectable(false)
                .build()
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceData(ParcelUuid(SERVICE_UUID), byteArrayOf(0x7f, i.toByte()))
                .build()
            val cb = object : AdvertiseCallback() {
                override fun onStartSuccess(s: AdvertiseSettings?) { main.post { results[i] = "ok"; answered++; finishIfDone() } }
                override fun onStartFailure(code: Int) { main.post { results[i] = advError(code); answered++; finishIfDone() } }
            }
            cbs += cb
            adv.startAdvertising(settings, data, cb)
        }
    }

    /** Opens GATT links to every address at once, holds them for [holdMs] and reports how many connected. */
    fun testConnectAll(addresses: List<String>, holdMs: Long, done: (Map<String, Any?>) -> Unit) {
        val a = adapter ?: return done(mapOf("ok" to false, "error" to "no adapter"))
        val gatts = ArrayList<BluetoothGatt>()
        val connected = HashSet<String>()
        val failed = HashMap<String, Int>()
        for (addr in addresses) {
            val cb = object : BluetoothGattCallback() {
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                    main.post {
                        if (newState == BluetoothProfile.STATE_CONNECTED) connected.add(addr)
                        else { connected.remove(addr); failed[addr] = status }
                    }
                }
            }
            val g = if (Build.VERSION.SDK_INT >= 26)
                a.getRemoteDevice(addr).connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK)
            else a.getRemoteDevice(addr).connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
            g?.let { gatts += it }
        }
        main.postDelayed({
            val res = mapOf(
                "ok" to true,
                "attempted" to addresses.size,
                "connected" to connected.size,
                "connectedAddresses" to connected.toList(),
                "failedStatus" to failed.mapValues { it.value },
                "alsoServingInbound" to serverConns.size,
            )
            gatts.forEach { g -> runCatching { g.disconnect() } }
            main.postDelayed({ gatts.forEach { g -> runCatching { g.close() } } }, 300)
            done(res)
        }, holdMs)
    }

    // ---------------------------------------------------------------- utils

    private fun hex(i: Int) = String.format("%08x", i)

    private fun advError(code: Int) = when (code) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
        else -> "code $code"
    }
}
