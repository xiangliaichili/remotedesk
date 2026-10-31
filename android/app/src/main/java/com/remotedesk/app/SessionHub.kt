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

        /** 对方摄像头画面（画中画渲染）。 */
        fun onRemoteCamera(track: VideoTrack) {}

        /** 媒体状态变化：policy 为政策位，on 为是否真的在采集。 */
        fun onMediaState(mic: Boolean, camera: Boolean, micOn: Boolean, camOn: Boolean, reason: String) {}

        /** 本机设备打开失败（权限被拒 / 无设备 / 被占用）。 */
        fun onMediaProblem(kind: String, reason: String) {}
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

    /** 被控端的媒体政策位（来自服务端 control_start / 本机设置）。 */
    @Volatile
    var policy: MediaPolicy = MediaPolicy.NONE
        private set

    @Volatile
    var micOn: Boolean = false
        private set

    @Volatile
    var camOn: Boolean = false
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
        controllerName: String = "",
        policy: MediaPolicy = MediaPolicy.NONE
    ) {
        detachSilently()
        this.rtc = client
        this.role = role
        this.sessionId = sessionId
        this.peerDeviceId = peer
        this.controllerName = controllerName
        this.policy = policy
        this.micOn = false
        this.camOn = false
        this.silent = false

        client.listener = object : RtcClient.Listener {
            override fun onRemoteTrack(track: VideoTrack) {
                listener?.onRemoteTrack(track)
            }

            override fun onRemoteCamera(track: VideoTrack) {
                listener?.onRemoteCamera(track)
            }

            override fun onRemoteAudio() {
                listener?.onState("已接入对方语音")
            }

            override fun onMediaState(
                mic: Boolean,
                camera: Boolean,
                micOn: Boolean,
                camOn: Boolean,
                reason: String
            ) {
                this@SessionHub.policy = MediaPolicy(mic, camera)
                this@SessionHub.micOn = micOn
                this@SessionHub.camOn = camOn
                listener?.onMediaState(mic, camera, micOn, camOn, reason)
            }

            override fun onMediaProblem(kind: String, reason: String) {
                listener?.onMediaProblem(kind, reason)
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

    /** 控制端：请求 / 停止接收对方的麦克风与摄像头。 */
    fun requestRemoteMedia(mic: Boolean, camera: Boolean) {
        rtc?.requestRemoteMedia(mic, camera)
    }

    /** 被控端：横幅上直接关掉某一路。 */
    fun stopLocalMedia(kind: String) {
        rtc?.stopLocalMedia(kind)
    }

    /** 被控端：设置变更后同步政策位。 */
    fun applyPolicy(p: MediaPolicy) {
        policy = p
        rtc?.applyMediaPolicy(p)
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
        policy = MediaPolicy.NONE
        micOn = false
        camOn = false
    }
}
