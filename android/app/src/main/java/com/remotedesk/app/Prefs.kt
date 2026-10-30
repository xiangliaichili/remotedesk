package com.remotedesk.app

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import java.util.UUID

/**
 * 本地持久化：服务器地址、令牌、设备身份。
 *
 * device_id 必须在同一台设备上保持稳定，否则服务端会把它当成一台新设备，
 * 「我的设备」列表里就会出现重复项。
 */
object Prefs {

    private const val FILE = "remotedesk"
    private lateinit var sp: SharedPreferences

    fun init(ctx: Context) {
        sp = ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    }

    var server: String
        get() = sp.getString("server", "") ?: ""
        set(v) {
            sp.edit().putString("server", v.trim().trimEnd('/')).apply()
        }

    var token: String
        get() = sp.getString("token", "") ?: ""
        set(v) {
            sp.edit().putString("token", v).apply()
        }

    var username: String
        get() = sp.getString("username", "") ?: ""
        set(v) {
            sp.edit().putString("username", v).apply()
        }

    var deviceId: String
        get() {
            val cur = sp.getString("device_id", "") ?: ""
            if (cur.isNotEmpty()) return cur
            val id = UUID.randomUUID().toString()
            sp.edit().putString("device_id", id).apply()
            return id
        }
        set(v) {
            sp.edit().putString("device_id", v).apply()
        }

    /** 本机显示名，默认取机型。 */
    var deviceName: String
        get() {
            val cur = sp.getString("device_name", "") ?: ""
            if (cur.isNotEmpty()) return cur
            val def = defaultName()
            sp.edit().putString("device_name", def).apply()
            return def
        }
        set(v) {
            sp.edit().putString("device_name", v).apply()
        }

    fun clearAuth() {
        sp.edit().remove("token").apply()
    }

    private fun defaultName(): String {
        val m = Build.MANUFACTURER ?: ""
        val model = Build.MODEL ?: "手机"
        val name = if (m.isNotEmpty() && !model.startsWith(m, ignoreCase = true)) "$m $model" else model
        return name.take(32)
    }
}
