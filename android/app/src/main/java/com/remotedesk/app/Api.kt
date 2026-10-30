package com.remotedesk.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** 服务端返回的业务错误（HTTP 非 2xx）。 */
class ApiException(val code: Int, message: String) : IOException(message)

data class AuthResult(val token: String, val userId: Long, val deviceId: String, val username: String)

data class DeviceItem(val id: String, val name: String, val os: String, val online: Boolean)

data class TurnInfo(val urls: List<String>, val username: String, val credential: String)

data class SessionResult(val sessionId: String, val status: String, val turn: TurnInfo?)

data class LinkResult(val code: String, val expireAt: String, val ttlMinutes: Int)

/**
 * REST 客户端。所有请求都走 HTTPS（或内网 HTTP），JWT 放在 Authorization 头。
 */
class Api(private val base: String, var token: String? = null) {

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    // ---------- 账号 ----------

    suspend fun register(username: String, password: String, deviceName: String, deviceId: String): AuthResult =
        authCall("/api/register", username, password, deviceName, deviceId)

    suspend fun login(username: String, password: String, deviceName: String, deviceId: String): AuthResult =
        authCall("/api/login", username, password, deviceName, deviceId)

    private suspend fun authCall(
        path: String,
        username: String,
        password: String,
        deviceName: String,
        deviceId: String
    ): AuthResult {
        val body = JSONObject().apply {
            put("username", username)
            put("password", password)
            put("device_name", deviceName)
            put("os", "android")
            put("device_id", deviceId)
        }.toString()
        val obj = JSONObject(request(path, "POST", body, auth = false))
        return AuthResult(
            token = obj.optString("token"),
            userId = obj.optLong("user_id"),
            deviceId = obj.optString("device_id"),
            username = obj.optString("username")
        )
    }

    // ---------- 设备 ----------

    suspend fun devices(): List<DeviceItem> = parseDevices(JSONObject(request("/api/devices", "GET")))

    /** 账号密码连接：先查目标账号下有哪些设备。 */
    suspend fun lookup(username: String, password: String): List<DeviceItem> {
        val body = JSONObject().apply {
            put("username", username)
            put("password", password)
        }.toString()
        return parseDevices(JSONObject(request("/api/session/lookup", "POST", body)))
    }

    private fun parseDevices(obj: JSONObject): List<DeviceItem> {
        val arr = obj.optJSONArray("devices") ?: return emptyList()
        val out = ArrayList<DeviceItem>(arr.length())
        for (i in 0 until arr.length()) {
            val d = arr.optJSONObject(i) ?: continue
            out.add(
                DeviceItem(
                    id = d.optString("id"),
                    name = d.optString("name"),
                    os = d.optString("os"),
                    online = d.optBoolean("online")
                )
            )
        }
        return out
    }

    // ---------- 会话 ----------

    suspend fun requestSession(payload: JSONObject): SessionResult {
        val obj = JSONObject(request("/api/session/request", "POST", payload.toString()))
        return SessionResult(
            sessionId = obj.optString("session_id"),
            status = obj.optString("status"),
            turn = parseTurn(obj.optJSONObject("turn"))
        )
    }

    suspend fun acceptSession(sessionId: String, accept: Boolean): SessionResult {
        val body = JSONObject().apply {
            put("session_id", sessionId)
            put("accept", accept)
        }.toString()
        val obj = JSONObject(request("/api/session/accept", "POST", body))
        return SessionResult(
            sessionId = sessionId,
            status = obj.optString("status"),
            turn = parseTurn(obj.optJSONObject("turn"))
        )
    }

    suspend fun cancelSession(sessionId: String) {
        val body = JSONObject().apply { put("session_id", sessionId) }.toString()
        request("/api/session/cancel", "POST", body)
    }

    // ---------- 链接 ----------

    suspend fun createLink(): LinkResult {
        val obj = JSONObject(request("/api/link/create", "POST", "{}"))
        return LinkResult(
            code = obj.optString("code"),
            expireAt = obj.optString("expires_at"),
            ttlMinutes = obj.optInt("ttl_minutes", 10)
        )
    }

    // ---------- 设置 ----------

    suspend fun getSettings(): JSONObject = JSONObject(request("/api/settings", "GET"))

    suspend fun putSettings(patch: JSONObject) {
        request("/api/settings", "PUT", patch.toString())
    }

    // ---------- 底层 ----------

    private suspend fun request(
        path: String,
        method: String,
        body: String? = null,
        auth: Boolean = true
    ): String = withContext(Dispatchers.IO) {
        val url = base.trimEnd('/') + path
        val builder = Request.Builder().url(url)
        val t = token
        if (auth && !t.isNullOrEmpty()) {
            builder.header("Authorization", "Bearer $t")
        }
        if (method == "GET") {
            builder.get()
        } else {
            builder.method(method, (body ?: "{}").toRequestBody(jsonType))
        }
        http.newCall(builder.build()).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            if (!resp.isSuccessful) {
                val msg = runCatching { JSONObject(text).optString("error") }.getOrNull()
                throw ApiException(resp.code, if (msg.isNullOrBlank()) "请求失败（HTTP ${resp.code}）" else msg)
            }
            text
        }
    }

    companion object {
        fun parseTurn(o: JSONObject?): TurnInfo? {
            if (o == null) return null
            val arr = o.optJSONArray("urls") ?: return null
            val urls = ArrayList<String>(arr.length())
            for (i in 0 until arr.length()) {
                val u = arr.optString(i)
                if (u.isNotEmpty()) urls.add(u)
            }
            if (urls.isEmpty()) return null
            return TurnInfo(urls, o.optString("username"), o.optString("credential"))
        }
    }
}
