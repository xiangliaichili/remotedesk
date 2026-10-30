package com.remotedesk.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 无障碍服务：把远端的输入事件翻译成手机上真实的触摸与按键。
 *
 * 说明：Android 出于安全，普通应用无法注入触摸；无障碍服务是官方允许的
 * 唯一免 root 途径。用户必须在本机「设置 → 无障碍」里手动开启本服务。
 */
class InjectorService : AccessibilityService() {

    companion object {
        private const val TAG = "InjectorService"

        @Volatile
        var alive: Boolean = false
            private set

        /** 当前服务实例（未开启时为 null），供 Activity 判断可用性。 */
        @Volatile
        var instance: InjectorService? = null
            private set

        private const val DRAG_THRESHOLD = 10f
        private const val TAP_MS = 60L
        private const val SEG_MS = 20L
    }

    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)

    private var stroke: GestureDescription.StrokeDescription? = null
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var dragging = false
    private var screenW = 1080
    private var screenH = 1920

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        alive = true
        val dm = resources.displayMetrics
        screenW = dm.widthPixels
        screenH = dm.heightPixels
        Log.i(TAG, "connected, screen ${screenW}x$screenH")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 本服务只负责注入，不需要读取界面内容。
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        alive = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        alive = false
        super.onDestroy()
    }

    // ---------------- 对外入口 ----------------

    /**
     * 处理一条来自 control 通道的输入事件。
     * 支持 mouse_*（Windows 控制端）与 touch（手机控制端）两套事件名。
     */
    fun handle(evt: JSONObject) {
        when (evt.optString("type")) {
            "touch", "mouse_move", "mouse_down", "mouse_up", "mouse_wheel" -> onPointer(evt)
            "key" -> onKey(evt)
            "text" -> onText(evt.optString("text"))
            else -> {}
        }
    }

    // ---------------- 指针 ----------------

    private fun onPointer(evt: JSONObject) {
        val type = evt.optString("type")
        val px = (evt.optDouble("x", 0.0).toFloat() * screenW).coerceIn(0f, screenW - 1f)
        val py = (evt.optDouble("y", 0.0).toFloat() * screenH).coerceIn(0f, screenH - 1f)

        when (type) {
            "mouse_wheel" -> {
                val dy = evt.optDouble("dy", 0.0).toFloat()
                if (dy > 0) swipe(py, screenH * 0.65f, py - screenH * 0.35f)
                else swipe(py, screenH * 0.35f, py + screenH * 0.35f)
            }

            "touch" -> {
                when (evt.optString("action")) {
                    "down" -> begin(px, py)
                    "move" -> move(px, py)
                    "up", "cancel" -> end()
                    else -> {
                        if (evt.has("y")) {
                            begin(px, py)
                            end()
                        }
                    }
                }
            }

            "mouse_down" -> {
                val btn = evt.optInt("button", 0)
                if (btn == 2) {
                    // 右键 → 返回
                    performGlobalAction(GLOBAL_ACTION_BACK)
                } else {
                    begin(px, py)
                }
            }

            "mouse_move" -> {
                if (dragging) move(px, py) else {
                    lastX = px
                    lastY = py
                }
            }

            "mouse_up" -> end()
        }
    }

    private fun begin(x: Float, y: Float) {
        main.post {
            downX = x
            downY = y
            lastX = x
            lastY = y
            dragging = false
            stroke = null
        }
    }

    private fun move(x: Float, y: Float) {
        main.post {
            if (!dragging) {
                val dx = x - downX
                val dy = y - downY
                if (dx * dx + dy * dy < DRAG_THRESHOLD * DRAG_THRESHOLD) return@post
                dragging = true
                // 起手：从按下点画到当前点
                val p = Path().apply {
                    moveTo(downX, downY)
                    lineTo(x, y)
                }
                val s = GestureDescription.StrokeDescription(p, 0, SEG_MS, true)
                val ok = dispatchGesture(GestureDescription.Builder().addStroke(s).build(), null, null)
                if (ok) stroke = s
                lastX = x
                lastY = y
            } else if (busy.compareAndSet(false, true)) {
                val prev = stroke
                if (prev == null) {
                    busy.set(false)
                    return@post
                }
                val p = Path().apply {
                    moveTo(lastX, lastY)
                    lineTo(x, y)
                }
                val cont = try {
                    prev.continueStroke(p, 0, SEG_MS, true)
                } catch (e: Throwable) {
                    Log.w(TAG, "continueStroke failed", e)
                    null
                }
                if (cont == null) {
                    stroke = null
                    busy.set(false)
                    return@post
                }
                val ok = dispatchGesture(
                    GestureDescription.Builder().addStroke(cont).build(),
                    object : GestureResultCallback() {
                        override fun onCompleted(g: GestureDescription?) {
                            busy.set(false)
                        }

                        override fun onCancelled(g: GestureDescription?) {
                            busy.set(false)
                        }
                    },
                    null
                )
                if (!ok) busy.set(false) else stroke = cont
                lastX = x
                lastY = y
            }
        }
    }

    private fun end() {
        main.post {
            if (!dragging) {
                // 没有拖动过 → 视为一次点击
                val p = Path().apply {
                    moveTo(downX, downY)
                    lineTo(downX + 1f, downY + 1f)
                }
                val s = GestureDescription.StrokeDescription(p, 0, TAP_MS)
                dispatchGesture(GestureDescription.Builder().addStroke(s).build(), null, null)
            } else {
                val prev = stroke
                if (prev != null) {
                    val p = Path().apply {
                        moveTo(lastX, lastY)
                        lineTo(lastX + 1f, lastY + 1f)
                    }
                    try {
                        val cont = prev.continueStroke(p, 0, 1, false)
                        dispatchGesture(GestureDescription.Builder().addStroke(cont).build(), null, null)
                    } catch (e: Throwable) {
                        Log.w(TAG, "finish stroke failed", e)
                    }
                }
            }
            dragging = false
            stroke = null
        }
    }

    /** 上下滑动（滚轮转成滑动）。 */
    private fun swipe(fromX: Float, fromY: Float, toY: Float) {
        main.post {
            val p = Path().apply {
                moveTo(fromX, fromY)
                lineTo(fromX, toY)
            }
            val s = GestureDescription.StrokeDescription(p, 0, 180)
            dispatchGesture(GestureDescription.Builder().addStroke(s).build(), null, null)
        }
    }

    // ---------------- 按键 ----------------

    private fun onKey(evt: JSONObject) {
        if (evt.optString("action") != "down") return
        val code = evt.optString("code")
        val key = evt.optString("key")
        when {
            key == "Escape" || code == "Escape" || code == "BrowserBack" ->
                performGlobalAction(GLOBAL_ACTION_BACK)

            key == "Home" || code == "Home" ->
                performGlobalAction(GLOBAL_ACTION_HOME)

            code == "AppSwitch" || key == "AppSwitch" || code == "RecentApps" ->
                performGlobalAction(GLOBAL_ACTION_RECENTS)

            code == "NotificationCenter" ->
                performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)

            code == "PowerDialog" ->
                performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)

            code == "Backspace" || code == "Delete" -> {
                // 注意：AccessibilityNodeInfo 没有 ACTION_DELETE 常量，
                // 这里用「整串回写去掉末位」实现退格。
                val node = focused() ?: return
                val cur = node.text?.toString().orEmpty()
                if (cur.isNotEmpty()) {
                    val args = Bundle().apply {
                        putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                            cur.substring(0, cur.length - 1)
                        )
                    }
                    node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                }
                node.recycle()
            }

            code == "Enter" || code == "NumpadEnter" || key == "Enter" -> {
                val node = focused() ?: return
                val args = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        (node.text?.toString() ?: "") + "\n"
                    )
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                node.recycle()
            }

            else -> {
                val ch = key.firstOrNull()
                if (ch != null && !ch.isISOControl()) onText(ch.toString())
            }
        }
    }

    // ---------------- 文本 ----------------

    private fun onText(text: String) {
        if (text.isEmpty()) return
        main.post {
            val node = focused() ?: return@post
            val cur = node.text?.toString() ?: ""
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    cur + text
                )
            }
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (!ok) Log.w(TAG, "ACTION_SET_TEXT rejected")
            node.recycle()
        }
    }

    private fun focused(): AccessibilityNodeInfo? {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (node == null) Log.w(TAG, "no focused input node")
        return node
    }
}
