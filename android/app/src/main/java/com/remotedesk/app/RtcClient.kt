package com.remotedesk.app

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * 一次远程控制会话的 WebRTC 实现。
 *
 * 角色约定（三端一致）：
 *  · controller —— 发起方，创建三条数据通道，并负责 createOffer。
 *  · controlled —— 被控方，只负责屏幕采集与 answer。
 *
 * 数据通道分工：
 *  · control —— 输入事件（JSON 文本）
 *  · meta    —— 元信息与文件控制消息（JSON 文本）
 *  · file    —— 仅二进制文件块
 */
class RtcClient(
    val role: String,
    val sessionId: String,
    val peerDeviceId: String,
    private val turn: TurnInfo?,
    private val signaling: Signaling
) {

    companion object {
        private const val TAG = "RtcClient"
        private const val CHUNK = 48 * 1024
    }

    val isController: Boolean get() = role == "controller"

    interface Listener {
        fun onRemoteTrack(track: VideoTrack)
        fun onReady()
        fun onClosed(reason: String)
        fun onProgress(text: String, pct: Int)
        fun onInput(evt: JSONObject)
        fun onInfo(text: String)
        fun onFileSaved(name: String, path: String)
        fun onPeerScreen(width: Int, height: Int)
    }

    var listener: Listener? = null

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private var egl: EglBase? = null
    private var pc: PeerConnection? = null
    private var helper: SurfaceTextureHelper? = null
    private var capturer: ScreenCapturerAndroid? = null
    private var vSource: VideoSource? = null
    private var vTrack: VideoTrack? = null

    private var cControl: DataChannel? = null
    private var cFile: DataChannel? = null
    private var cMeta: DataChannel? = null

    private val queued = ArrayList<IceCandidate>()
    private var hasRemote = false

    /** meta 通道尚未就绪时先排队，就绪后统一补发。 */
    private val pendingMeta = ArrayList<String>()

    @Volatile
    private var closed = false
    private var ctxRef: Context? = null

    // 发送文件
    private var sendUri: Uri? = null
    private var sendName = ""
    private var sendSize = 0L
    private var sendId = ""

    // 接收文件
    private var recvRaf: RandomAccessFile? = null
    private var recvPath: String? = null
    private var recvName = ""
    private var recvSize = 0L
    private var recvOffset = 0L
    private var lastPct = -1

    /** 被控端本机屏幕（原分辨率），用于上报给控制端换算坐标。 */
    private var localW = 0
    private var localH = 0

    // ---------- 生命周期 ----------

    fun start(ctx: Context) {
        ctxRef = ctx.applicationContext
        egl = EglBase.create()

        val cfg = PeerConnection.RTCConfiguration(iceServers()).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val conn = App.factory.createPeerConnection(cfg, observer)
        if (conn == null) {
            fail("无法创建 PeerConnection")
            return
        }
        pc = conn

        if (isController) {
            cControl = newChannel("control")
            cFile = newChannel("file")
            cMeta = newChannel("meta")
            createOffer()
        } else {
            val src = App.factory.createVideoSource(true) // isScreencast = true
            val track = App.factory.createVideoTrack("screen0", src)
            vSource = src
            vTrack = track
            conn.addTrack(track, listOf("rd-screen"))
        }
    }

    /**
     * 被控方：用 MediaProjection 授权结果启动屏幕采集。
     * 必须在 mediaProjection 类型的前台服务已经运行之后调用（Android 14 要求）。
     */
    fun startCapture(permission: Intent, width: Int, height: Int, fps: Int) {
        if (isController || capturer != null) return
        val src = vSource ?: return
        try {
            val h = SurfaceTextureHelper.create("rd-capture", egl?.eglBaseContext)
            helper = h
            val cap = ScreenCapturerAndroid(permission, object : MediaProjection.Callback() {
                override fun onStop() {
                    main.post { listener?.onInfo("系统已停止屏幕共享") }
                }
            })
            capturer = cap
            cap.initialize(h, ctxRef, src.capturerObserver)
            cap.startCapture(width, height, fps)
            localW = width
            localH = height
            Log.i(TAG, "capture started ${width}x$height@$fps")
            announceScreen()
        } catch (e: Throwable) {
            Log.w(TAG, "startCapture failed", e)
            listener?.onInfo("屏幕采集启动失败：${e.message}")
        }
    }

    fun stopCapture() {
        try {
            capturer?.stopCapture()
        } catch (_: Throwable) {
        }
        try {
            capturer?.dispose()
        } catch (_: Throwable) {
        }
        capturer = null
        try {
            helper?.dispose()
        } catch (_: Throwable) {
        }
        helper = null
    }

    fun close(reason: String = "") {
        if (closed) return
        closed = true
        stopCapture()
        try {
            io.shutdownNow()
        } catch (_: Throwable) {
        }
        listOf(cControl, cFile, cMeta).forEach {
            try {
                it?.close()
            } catch (_: Throwable) {
            }
        }
        cControl = null
        cFile = null
        cMeta = null
        try {
            pc?.close()
            pc?.dispose()
        } catch (_: Throwable) {
        }
        pc = null
        try {
            vTrack?.dispose()
        } catch (_: Throwable) {
        }
        try {
            vSource?.dispose()
        } catch (_: Throwable) {
        }
        vTrack = null
        vSource = null
        try {
            egl?.release()
        } catch (_: Throwable) {
        }
        egl = null
        try {
            recvRaf?.close()
        } catch (_: Throwable) {
        }
        recvRaf = null
        main.post { listener?.onClosed(reason) }
    }

    private fun fail(msg: String) {
        main.post { listener?.onInfo(msg) }
        close(msg)
    }

    // ---------- 协商 ----------

    private fun iceServers(): List<PeerConnection.IceServer> {
        val out = ArrayList<PeerConnection.IceServer>()
        val t = turn
        if (t != null && t.urls.isNotEmpty()) {
            for (u in t.urls) {
                try {
                    out.add(
                        PeerConnection.IceServer.builder(u)
                            .setUsername(t.username)
                            .setPassword(t.credential)
                            .createIceServer()
                    )
                } catch (e: Throwable) {
                    Log.w(TAG, "bad ice url $u", e)
                }
            }
        }
        if (out.isEmpty() || out.none { it.urls.any { u -> u.startsWith("stun:") } }) {
            out.add(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        }
        return out
    }

    private fun newChannel(name: String): DataChannel? {
        val ch = pc?.createDataChannel(name, DataChannel.Init().apply { ordered = true }) ?: return null
        ch.registerObserver(channelObserver(name))
        return ch
    }

    private fun createOffer() {
        val c = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"))
        }
        pc?.createOffer(object : SimpleSdp() {
            override fun onCreateSuccess(sdp: SessionDescription?) {
                val d = sdp ?: return
                pc?.setLocalDescription(SimpleSdp(), d)
                signaling.send(JSONObject().apply {
                    put("type", "offer")
                    put("to", peerDeviceId)
                    put("session_id", sessionId)
                    put("sdp", d.description)
                })
            }

            override fun onCreateFailure(err: String?) {
                fail("创建 offer 失败：$err")
            }
        }, c)
    }

    fun handleOffer(sdp: String) {
        val desc = SessionDescription(SessionDescription.Type.OFFER, sdp)
        pc?.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() {
                hasRemote = true
                flushCandidates()
                pc?.createAnswer(object : SimpleSdp() {
                    override fun onCreateSuccess(sdp: SessionDescription?) {
                        val a = sdp ?: return
                        pc?.setLocalDescription(SimpleSdp(), a)
                        signaling.send(JSONObject().apply {
                            put("type", "answer")
                            put("to", peerDeviceId)
                            put("session_id", sessionId)
                            put("sdp", a.description)
                        })
                    }

                    override fun onCreateFailure(err: String?) {
                        fail("创建 answer 失败：$err")
                    }
                }, MediaConstraints())
            }

            override fun onSetFailure(err: String?) {
                fail("设置远端描述失败：$err")
            }
        }, desc)
    }

    fun handleAnswer(sdp: String) {
        val desc = SessionDescription(SessionDescription.Type.ANSWER, sdp)
        pc?.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() {
                hasRemote = true
                flushCandidates()
            }

            override fun onSetFailure(err: String?) {
                Log.w(TAG, "setRemoteDescription(answer) failed: $err")
            }
        }, desc)
    }

    fun handleIce(candidateJson: String) {
        val o = runCatching { JSONObject(candidateJson) }.getOrNull() ?: return
        val sdp = o.optString("candidate")
        if (sdp.isEmpty()) return
        val c = IceCandidate(o.optString("sdpMid", "0"), o.optInt("sdpMLineIndex", 0), sdp)
        if (!hasRemote) {
            queued.add(c)
            return
        }
        try {
            pc?.addIceCandidate(c)
        } catch (e: Throwable) {
            Log.w(TAG, "addIceCandidate failed", e)
        }
    }

    private fun flushCandidates() {
        val snapshot = ArrayList(queued)
        queued.clear()
        for (c in snapshot) {
            try {
                pc?.addIceCandidate(c)
            } catch (e: Throwable) {
                Log.w(TAG, "flush candidate failed", e)
            }
        }
    }

    // ---------- 数据通道 ----------

    private fun channelOf(name: String): DataChannel? = when (name) {
        "control" -> cControl
        "file" -> cFile
        else -> cMeta
    }

    private fun channelObserver(name: String) = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) {}

        override fun onStateChange() {
            val st = channelOf(name)?.state()
            if (st == DataChannel.State.OPEN) {
                if (name == "meta") {
                    flushMeta()
                    announceScreen()
                }
                main.post { listener?.onReady() }
            }
        }

        override fun onMessage(buffer: DataChannel.Buffer) {
            val bytes = ByteArray(buffer.data.remaining())
            buffer.data.get(bytes)
            if (buffer.binary) {
                if (name == "file") writeChunk(bytes)
            } else {
                onText(name, String(bytes, Charsets.UTF_8))
            }
        }
    }

    private fun onText(name: String, text: String) {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (name) {
            "control" -> main.post { listener?.onInput(obj) }
            "meta" -> {
                val t = obj.optString("t")
                when {
                    t.startsWith("file_") -> onFileCtl(obj)
                    t == "screen" -> {
                        val w = obj.optInt("w")
                        val h = obj.optInt("h")
                        if (w > 0 && h > 0) main.post { listener?.onPeerScreen(w, h) }
                    }

                    else -> main.post { listener?.onInfo(text) }
                }
            }
        }
    }

    private fun sendText(ch: DataChannel?, obj: JSONObject) {
        val c = ch ?: return
        if (c.state() != DataChannel.State.OPEN) return
        try {
            val bytes = obj.toString().toByteArray(Charsets.UTF_8)
            c.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
        } catch (e: Throwable) {
            Log.w(TAG, "send failed", e)
        }
    }

    /** 控制端 → 被控端：发送一条输入事件。 */
    fun sendInput(evt: JSONObject) = sendText(cControl, evt)

    fun sendMeta(obj: JSONObject) {
        val c = cMeta
        if (c == null || c.state() != DataChannel.State.OPEN) {
            pendingMeta.add(obj.toString())
            return
        }
        sendText(c, obj)
    }

    private fun flushMeta() {
        if (pendingMeta.isEmpty()) return
        val list = ArrayList(pendingMeta)
        pendingMeta.clear()
        for (s in list) {
            val obj = runCatching { JSONObject(s) }.getOrNull() ?: continue
            sendText(cMeta, obj)
        }
    }

    /** 被控端把自己的屏幕尺寸告知控制端，用于比例换算。 */
    private fun announceScreen() {
        if (isController) return
        if (localW <= 0 || localH <= 0) return
        sendMeta(JSONObject().apply {
            put("t", "screen")
            put("w", localW)
            put("h", localH)
        })
    }

    // ---------- 文件：发送 ----------

    fun sendFile(ctx: Context, uri: Uri, name: String, size: Long) {
        val total = if (size >= 0) size else guessSize(ctx, uri)
        if (total <= 0) {
            listener?.onInfo("无法读取文件大小")
            return
        }
        sendUri = uri
        sendName = name
        sendSize = total
        sendId = "f" + System.currentTimeMillis()
        sendText(cMeta, JSONObject().apply {
            put("t", "file_offer")
            put("id", sendId)
            put("name", name)
            put("size", total)
        })
        listener?.onProgress("等待对方接收…", 0)
    }

    private fun guessSize(ctx: Context, uri: Uri): Long = try {
        ctx.contentResolver.openInputStream(uri)?.use { input ->
            val buf = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                total += n
            }
            total
        } ?: 0L
    } catch (e: Throwable) {
        0L
    }

    private fun streamFile() {
        val ctx = ctxRef ?: return
        val uri = sendUri ?: return
        val id = sendId
        val total = sendSize
        io.execute {
            var sent = 0L
            try {
                ctx.contentResolver.openInputStream(uri)?.use { input ->
                    val buf = ByteArray(CHUNK)
                    while (sent < total && !closed) {
                        val fc = cFile ?: break
                        if (fc.state() != DataChannel.State.OPEN) break
                        if (fc.bufferedAmount() > 2L * 1024 * 1024) {
                            Thread.sleep(12)
                            continue
                        }
                        var read = 0
                        while (read < buf.size) {
                            val n = input.read(buf, read, buf.size - read)
                            if (n <= 0) break
                            read += n
                        }
                        if (read <= 0) break
                        val chunk = buf.copyOf(read)
                        fc.send(DataChannel.Buffer(ByteBuffer.wrap(chunk), true))
                        sent += read
                        val pct = (sent * 100 / total).toInt()
                        main.post { listener?.onProgress("发送 ${sendName}  $pct%", pct) }
                    }
                }
                sendText(cMeta, JSONObject().apply {
                    put("t", "file_done")
                    put("id", id)
                })
                main.post { listener?.onProgress("已发送 $sendName", 100) }
            } catch (e: Throwable) {
                Log.w(TAG, "streamFile failed", e)
                main.post { listener?.onInfo("发送失败：${e.message}") }
            }
        }
    }

    // ---------- 文件：接收 ----------

    private fun onFileCtl(m: JSONObject) {
        when (m.optString("t")) {
            "file_offer" -> {
                val name = m.optString("name", "file")
                val size = m.optLong("size", 0)
                val target = uniqueTarget(name)
                recvName = name
                recvSize = size
                recvOffset = 0
                lastPct = -1
                recvPath = target.absolutePath
                recvRaf = try {
                    RandomAccessFile(target, "rw").also { it.setLength(0) }
                } catch (e: Throwable) {
                    Log.w(TAG, "open recv file failed", e)
                    null
                }
                if (recvRaf == null) {
                    sendText(cMeta, JSONObject().apply {
                        put("t", "file_reject")
                        put("id", m.optString("id"))
                    })
                    listener?.onInfo("无法创建接收文件")
                    return
                }
                sendText(cMeta, JSONObject().apply {
                    put("t", "file_accept")
                    put("id", m.optString("id"))
                })
                listener?.onProgress("接收 $name  0%", 0)
            }

            "file_accept" -> {
                if (m.optString("id") == sendId) {
                    main.post { listener?.onProgress("开始发送 $sendName", 0) }
                    streamFile()
                }
            }

            "file_reject" -> {
                sendUri = null
                listener?.onInfo("对方拒绝接收文件")
            }

            "file_done" -> finishRecv(m.optString("id"))
        }
    }

    private fun writeChunk(bytes: ByteArray) {
        val raf = recvRaf ?: return
        try {
            raf.seek(recvOffset)
            raf.write(bytes)
            recvOffset += bytes.size
            val pct = if (recvSize > 0) (recvOffset * 100 / recvSize).toInt() else 0
            if (pct != lastPct) {
                lastPct = pct
                main.post { listener?.onProgress("接收 $recvName  $pct%", pct) }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "write chunk failed", e)
            main.post { listener?.onInfo("写入文件失败：${e.message}") }
        }
    }

    private fun finishRecv(id: String) {
        try {
            recvRaf?.close()
        } catch (_: Throwable) {
        }
        recvRaf = null
        sendText(cMeta, JSONObject().apply {
            put("t", "file_ack")
            put("id", id)
            put("ok", true)
        })
        val p = recvPath
        val n = recvName
        recvPath = null
        if (p != null) {
            main.post {
                listener?.onProgress("已接收 $n", 100)
                listener?.onFileSaved(n, p)
            }
        }
    }

    /** 接收目录：App 私有外部目录，无需存储权限。 */
    private fun recvDir(): File {
        val base = App.instance.getExternalFilesDir(null) ?: App.instance.filesDir
        val dir = File(base, "remotedesk-received")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun uniqueTarget(name: String): File {
        val dir = recvDir()
        val safe = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").ifBlank { "file" }
        val dot = safe.lastIndexOf('.')
        val stem = if (dot > 0) safe.substring(0, dot) else safe
        val ext = if (dot > 0) safe.substring(dot) else ""
        var f = File(dir, safe)
        var i = 1
        while (f.exists()) {
            f = File(dir, "$stem ($i)$ext")
            i++
        }
        return f
    }

    // ---------- PeerConnection 回调 ----------

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            when (state) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> main.post { listener?.onReady() }

                PeerConnection.IceConnectionState.FAILED -> main.post {
                    listener?.onInfo("网络不通，连接失败（可让对方检查 NAT/TURN）")
                }

                PeerConnection.IceConnectionState.DISCONNECTED -> main.post {
                    listener?.onInfo("连接不稳定，正在重连…")
                }

                else -> {}
            }
        }

        override fun onIceConnectionReceivingChange(receiving: Boolean) {}

        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}

        override fun onIceCandidate(candidate: IceCandidate?) {
            val c = candidate ?: return
            val payload = JSONObject().apply {
                put("candidate", c.sdp)
                put("sdpMid", c.sdpMid)
                put("sdpMLineIndex", c.sdpMLineIndex)
            }
            signaling.send(JSONObject().apply {
                put("type", "ice")
                put("to", peerDeviceId)
                put("session_id", sessionId)
                put("candidate", payload.toString())
            })
        }

        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}

        override fun onAddStream(stream: MediaStream?) {}

        override fun onRemoveStream(stream: MediaStream?) {}

        override fun onDataChannel(channel: DataChannel?) {
            val ch = channel ?: return
            when (ch.label()) {
                "control" -> cControl = ch
                "file" -> cFile = ch
                "meta" -> cMeta = ch
            }
            ch.registerObserver(channelObserver(ch.label()))
        }

        override fun onRenegotiationNeeded() {}

        override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {
            val track = receiver?.track()
            if (track is VideoTrack) {
                main.post { listener?.onRemoteTrack(track) }
            }
        }
    }

    /** SdpObserver 的空实现，子类只覆盖关心的回调。 */
    private open class SimpleSdp : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription?) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(err: String?) {}
        override fun onSetFailure(err: String?) {}
    }
}
