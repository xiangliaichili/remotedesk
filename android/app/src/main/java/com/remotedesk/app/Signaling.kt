package com.remotedesk.app

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 信令通道：wss://<服务器>/ws。
 *
 * 连接建立后的第一帧必须是 {"type":"auth","data":"<JWT>"}，收到 auth_ok 才算可用。
 */
class Signaling(baseUrl: String) {

    interface Listener {
        fun onOpen()
        fun onMessage(msg: JSONObject)
        fun onClosed(reason: String)
    }

    var listener: Listener? = null

    private val http = OkHttpClient.Builder()
        .pingInterval(25, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .build()

    private var ws: WebSocket? = null
    @Volatile
    private var closedByUser = false

    private val url: String = normalize(baseUrl)

    fun connect(token: String) {
        closedByUser = false
        val req = Request.Builder().url(url).build()
        ws = http.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val auth = JSONObject().apply {
                    put("type", "auth")
                    put("data", token)
                }
                webSocket.send(auth.toString())
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
                if (obj.optString("type") == "auth_ok") {
                    listener?.onOpen()
                }
                listener?.onMessage(obj)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (!closedByUser) listener?.onClosed(t.message ?: "信令连接中断")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!closedByUser) listener?.onClosed(reason.ifEmpty { "信令连接已关闭" })
            }
        })
    }

    fun send(obj: JSONObject) {
        ws?.send(obj.toString())
    }

    fun sendRaw(text: String) {
        ws?.send(text)
    }

    fun close() {
        closedByUser = true
        try {
            ws?.close(1000, "bye")
        } catch (_: Throwable) {
        }
        ws = null
    }

    companion object {
        /** http(s)://host → ws(s)://host/ws */
        fun normalize(base: String): String {
            var u = base.trim().trimEnd('/')
            u = when {
                u.startsWith("https://") -> "wss://" + u.removePrefix("https://")
                u.startsWith("http://") -> "ws://" + u.removePrefix("http://")
                u.startsWith("wss://") || u.startsWith("ws://") -> u
                else -> "ws://$u"
            }
            if (!u.endsWith("/ws")) u += "/ws"
            return u
        }
    }
}
