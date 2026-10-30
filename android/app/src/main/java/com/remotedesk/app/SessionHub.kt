package com.remotedesk.app

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import org.webrtc.VideoTrack

/**
 * 全局会话协调器。
 *
 * Activity 负责界面与信令，Service 负责采集与前台通知，两端通过这里
 * 共享「当前唯一的活动会话」。同一时刻只允许一个会话。
 */
object SessionHub {

    interface Listener {
        fun onRemoteTrack(track: VideoTrack)
        fun onState(text: String)
        fun onProgress(text: String, pct: Int)
        fun onEnded(reason: String)
        fun onPeerScreen(width: Int, height: Int) {}
    }

    @Volatile
    var rtc: RtcClient? = null
        private set

    @Volatile
    var role: String = ""
        private set

    @Volatile
    var sessionId: String = ""
        private set

    @Volatile
    var peerDeviceId: String = ""
        private set

    @Volatile
    var controllerName: String = ""
        private set

    @Volatile
    var turn: TurnInfo? = null
        private set

    var signaling: Signaling? = null

    @Volatile
    var listener: Listener? = null

    private var silent = false

    fun isActive(): Boolean = rtc != null

    fun isController(): Boolean = role == "controller"

    fun attach(
        client: RtcClient,
        role: String,
        sessionId: String,
        peer: String,
        controllerName: String = ""
    ) {
        detachSilently()
        this.rtc = client
        this.role = role
        this.sessionId = sessionId
        this.peerDeviceId = peer
        this.controllerName = controllerName
        this.silent = false

        client.listener = object : RtcClient.Listener {
            override fun onRemoteTrack(track: VideoTrack) {
                listener?.onRemoteTrack(track)
            }

            override fun onReady() {
                if (role == "controlled") listener?.onState("已连接，对方正在控制本机")
                else listener?.onState("已连接")
            }

            override fun onClosed(reason: String) {
                finish(reason.ifBlank { "会话已结束" })
            }

            override fun onProgress(text: String, pct: Int) {
                listener?.onProgress(text, pct)
            }

            override fun onInput(evt: JSONObject) {
                // 只有被控端才需要把输入落到本机
                InjectorService.instance?.handle(evt)
            }

            override fun onInfo(text: String) {
                listener?.onState(text)
            }

            override fun onFileSaved(name: String, path: String) {
                listener?.onState("已保存 $name → $path")
            }

            override fun onPeerScreen(width: Int, height: Int) {
                listener?.onPeerScreen(width, height)
            }
        }
    }

    /** 信令消息路由：offer / answer / ice。 */
    fun onWs(msg: JSONObject) {
        val c = rtc ?: return
        when (msg.optString("type")) {
            "offer" -> c.handleOffer(msg.optString("sdp"))
            "answer" -> c.handleAnswer(msg.optString("sdp"))
            "ice" -> c.handleIce(msg.optString("candidate"))
        }
    }

    fun sendInput(evt: JSONObject) {
        rtc?.sendInput(evt)
    }

    fun sendFile(ctx: Context, uri: Uri, name: String, size: Long) {
        rtc?.sendFile(ctx, uri, name, size)
    }

    fun sendMeta(obj: JSONObject) {
        rtc?.sendMeta(obj)
    }

    /** 主动结束（本端发起）。会同时通知服务器关闭会话。 */
    fun end(reason: String = "本机已结束会话") {
        val id = sessionId
        val sig = signaling
        val c = rtc
        if (id.isNotEmpty() && sig != null) {
            sig.send(JSONObject().apply {
                put("type", "cancel")
                put("to", peerDeviceId)
                put("session_id", id)
            })
        }
        silent = true
        try {
            c?.close(reason)
        } catch (_: Throwable) {
        }
        clear()
        listener?.onEnded(reason)
    }

    /** 收到对端 control_end / session_deny 时调用。 */
    fun remoteEnded(reason: String) {
        val c = rtc
        silent = true
        try {
            c?.close(reason)
        } catch (_: Throwable) {
        }
        clear()
        listener?.onEnded(reason)
    }

    private fun finish(reason: String) {
        if (silent) {
            clear()
            return
        }
        clear()
        listener?.onEnded(reason)
    }

    private fun detachSilently() {
        silent = true
        try {
            rtc?.close("")
        } catch (_: Throwable) {
        }
        clear()
    }

    private fun clear() {
        rtc = null
        role = ""
        sessionId = ""
        peerDeviceId = ""
        controllerName = ""
        turn = null
    }
}
