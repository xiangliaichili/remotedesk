package com.remotedesk.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.text.InputType
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "MainActivity"
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private var api: Api? = null
    private var signaling: Signaling? = null
    private var egl: EglBase? = null
    private var remoteTrack: VideoTrack? = null
    private var cameraTrack: VideoTrack? = null

    private var pendingSessionId = ""
    private var pendingPeer = ""
    private var pendingController = ""
    private var pendingTurn: TurnInfo? = null
    private var pendingPolicy: MediaPolicy = MediaPolicy.NONE

    private var reqSessionId = ""
    private var reqController = ""
    private var reqPeer = ""
    private var reqPolicy: MediaPolicy = MediaPolicy.NONE

    private var waitingApprove = false
    private var linkTicker: android.os.Handler? = null

    // ---- 登录方式（v1.03）----
    private var authMethods: AuthMethods? = null
    private var smsCountdown: android.os.Handler? = null
    private var wxPollJob: Job? = null
    private var wxState: String = ""

    // ---- 媒体（语音/摄像头）----
    /** 控制端：对方允许的媒体能力（来自服务端会话响应）。 */
    private var peerPolicy: MediaPolicy = MediaPolicy.NONE
    /** 控制端：我这边希望的开关状态。 */
    private var wantMic = false
    private var wantCam = false
    /** 权限申请完成后的续动作（先授权，再拉 MediaProjection）。 */
    private var afterPermission: (() -> Unit)? = null

    // ---- 视图 ----
    private lateinit var screenAuth: View
    private lateinit var screenHome: View
    private lateinit var screenRemote: View
    private lateinit var controlBanner: View
    private lateinit var reqDialog: View
    private lateinit var settingsDialog: View

    private lateinit var etServer: EditText
    private lateinit var etUser: EditText
    private lateinit var etPass: EditText
    private lateinit var tvAuthError: TextView
    private lateinit var tvDeviceHint: TextView

    // 登录方式切换
    private lateinit var btnTabPwd: Button
    private lateinit var btnTabSms: Button
    private lateinit var btnTabWx: Button
    private lateinit var authPwdPanel: View
    private lateinit var authSmsPanel: View
    private lateinit var authWxPanel: View
    private lateinit var etSmsPhone: EditText
    private lateinit var etSmsCode: EditText
    private lateinit var btnSmsSend: Button
    private lateinit var tvSmsHint: TextView
    private lateinit var btnSmsLogin: Button
    private lateinit var tvWxHint: TextView
    private lateinit var btnWxStart: Button
    private lateinit var btnWxDev: Button

    private lateinit var dotState: View
    private lateinit var tvSelf: TextView
    private lateinit var deviceList: LinearLayout
    private lateinit var tvNoDevices: TextView
    private lateinit var tvLinkCode: TextView
    private lateinit var tvLinkExpire: TextView
    private lateinit var etLink: EditText
    private lateinit var etPeerUser: EditText
    private lateinit var etPeerPass: EditText

    private lateinit var tvRemoteTitle: TextView
    private lateinit var tvMediaState: TextView
    private lateinit var renderer: SurfaceViewRenderer
    private lateinit var cameraRenderer: SurfaceViewRenderer
    private lateinit var tvTransfer: TextView
    private lateinit var progress: ProgressBar
    private lateinit var tvBanner: TextView
    private lateinit var tvReqText: TextView
    private lateinit var tvReqMedia: TextView
    private lateinit var btnMic: Button
    private lateinit var btnCamera: Button
    private lateinit var btnBannerMic: Button
    private lateinit var btnBannerCam: Button

    private lateinit var cbAutoAccept: CheckBox
    private lateinit var cbMic: CheckBox
    private lateinit var cbCamera: CheckBox

    // ---- 授权回调 ----
    private val projectionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            val data = res.data
            if (res.resultCode != RESULT_OK || data == null) {
                toast("未授权屏幕共享，无法被控")
                SessionHub.end("本机拒绝共享屏幕")
                return@registerForActivityResult
            }
            RemoteService.start(
                this,
                res.resultCode,
                data,
                pendingSessionId,
                pendingPeer,
                pendingController,
                pendingTurn,
                pendingPolicy
            )
            showControlledUi(pendingController)
        }

    /** 麦克风 / 摄像头的运行时权限。 */
    private val mediaPermLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            val denied = result.filterValues { granted -> !granted }.keys
            if (denied.isNotEmpty()) {
                toast(
                    Permissions.deniedHint(
                        denied.contains(Permissions.MIC),
                        denied.contains(Permissions.CAMERA)
                    )
                )
            }
            val next = afterPermission
            afterPermission = null
            next?.invoke()
        }

    private val filePicker =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            val uri = res.data?.data ?: return@registerForActivityResult
            if (res.resultCode != RESULT_OK) return@registerForActivityResult
            val (name, size) = queryFile(uri)
            SessionHub.sendFile(this, uri, name, size)
            tvTransfer.text = "发送 $name"
        }

    private val notifPerm =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    // ================= 生命周期 =================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        bindViews()
        egl = EglBase.create()
        renderer.init(egl?.eglBaseContext, null)
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        renderer.setEnableHardwareScaler(true)
        renderer.setMirror(false)
        cameraRenderer.init(egl?.eglBaseContext, null)
        cameraRenderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        cameraRenderer.setMirror(true)

        SessionHub.listener = object : SessionHub.Listener {
            override fun onRemoteTrack(track: VideoTrack) {
                remoteTrack = track
                track.addSink(renderer)
                tvRemoteTitle.text = "远程控制中"
                tvTransfer.text = ""
                progress.progress = 0
            }

            override fun onRemoteCamera(track: VideoTrack) {
                cameraTrack = track
                track.addSink(cameraRenderer)
                cameraRenderer.visibility = View.VISIBLE
            }

            override fun onState(text: String) {
                toast(text)
            }

            override fun onProgress(text: String, pct: Int) {
                tvTransfer.text = text
                progress.progress = pct
            }

            override fun onEnded(reason: String) {
                clearRemoteTracks()
                waitingApprove = false
                controlBanner.visibility = View.GONE
                show(screenHome)
                toast(reason)
                refreshDevices()
            }

            override fun onPeerScreen(width: Int, height: Int) {
                frameSize = Pair(width, height)
            }

            override fun onMediaState(
                mic: Boolean,
                camera: Boolean,
                micOn: Boolean,
                camOn: Boolean,
                reason: String
            ) {
                renderMedia(mic, camera, micOn, camOn, reason)
            }

            override fun onMediaProblem(kind: String, reason: String) {
                showMediaProblem(kind, reason)
            }
        }

        askNotificationPermission()
        restoreSession()
    }

    override fun onDestroy() {
        linkTicker?.removeCallbacksAndMessages(null)
        smsCountdown?.removeCallbacksAndMessages(null)
        wxPollJob?.cancel()
        SessionHub.listener = null
        SessionHub.signaling = null
        signaling?.close()
        SessionHub.rtc?.close("界面已关闭")
        clearRemoteTracks()
        renderer.release()
        cameraRenderer.release()
        egl?.release()
        egl = null
        scope.cancel()
        super.onDestroy()
    }

    private fun clearRemoteTracks() {
        remoteTrack?.removeSink(renderer)
        remoteTrack = null
        cameraTrack?.removeSink(cameraRenderer)
        cameraTrack = null
        cameraRenderer.visibility = View.GONE
    }

    private fun bindViews() {
        screenAuth = findViewById(R.id.screenAuth)
        screenHome = findViewById(R.id.screenHome)
        screenRemote = findViewById(R.id.screenRemote)
        controlBanner = findViewById(R.id.controlBanner)
        reqDialog = findViewById(R.id.reqDialog)
        settingsDialog = findViewById(R.id.settingsDialog)

        etServer = findViewById(R.id.etServer)
        etUser = findViewById(R.id.etUser)
        etPass = findViewById(R.id.etPass)
        tvAuthError = findViewById(R.id.tvAuthError)
        tvDeviceHint = findViewById(R.id.tvDeviceHint)

        btnTabPwd = findViewById(R.id.btnTabPwd)
        btnTabSms = findViewById(R.id.btnTabSms)
        btnTabWx = findViewById(R.id.btnTabWx)
        authPwdPanel = findViewById(R.id.authPwdPanel)
        authSmsPanel = findViewById(R.id.authSmsPanel)
        authWxPanel = findViewById(R.id.authWxPanel)
        etSmsPhone = findViewById(R.id.etSmsPhone)
        etSmsCode = findViewById(R.id.etSmsCode)
        btnSmsSend = findViewById(R.id.btnSmsSend)
        tvSmsHint = findViewById(R.id.tvSmsHint)
        btnSmsLogin = findViewById(R.id.btnSmsLogin)
        tvWxHint = findViewById(R.id.tvWxHint)
        btnWxStart = findViewById(R.id.btnWxStart)
        btnWxDev = findViewById(R.id.btnWxDev)

        dotState = findViewById(R.id.dotState)
        tvSelf = findViewById(R.id.tvSelf)
        deviceList = findViewById(R.id.deviceList)
        tvNoDevices = findViewById(R.id.tvNoDevices)
        tvLinkCode = findViewById(R.id.tvLinkCode)
        tvLinkExpire = findViewById(R.id.tvLinkExpire)
        etLink = findViewById(R.id.etLink)
        etPeerUser = findViewById(R.id.etPeerUser)
        etPeerPass = findViewById(R.id.etPeerPass)

        tvRemoteTitle = findViewById(R.id.tvRemoteTitle)
        tvMediaState = findViewById(R.id.tvMediaState)
        renderer = findViewById(R.id.remoteRenderer)
        cameraRenderer = findViewById(R.id.cameraRenderer)
        tvTransfer = findViewById(R.id.tvTransfer)
        progress = findViewById(R.id.progress)
        tvBanner = findViewById(R.id.tvBanner)
        tvReqText = findViewById(R.id.tvReqText)
        tvReqMedia = findViewById(R.id.tvReqMedia)
        btnMic = findViewById(R.id.btnMic)
        btnCamera = findViewById(R.id.btnCamera)
        btnBannerMic = findViewById(R.id.btnBannerMic)
        btnBannerCam = findViewById(R.id.btnBannerCam)

        cbAutoAccept = findViewById(R.id.cbAutoAccept)
        cbMic = findViewById(R.id.cbMic)
        cbCamera = findViewById(R.id.cbCamera)

        etServer.setText(Prefs.server)
        tvDeviceHint.text = "本机名称：${Prefs.deviceName}"

        findViewById<Button>(R.id.btnLogin).setOnClickListener { doAuth(false) }
        findViewById<Button>(R.id.btnRegister).setOnClickListener { doAuth(true) }
        findViewById<Button>(R.id.btnRefresh).setOnClickListener { refreshDevices() }
        findViewById<Button>(R.id.btnLogout).setOnClickListener { logout() }
        findViewById<Button>(R.id.btnSettings).setOnClickListener { openSettings() }
        findViewById<Button>(R.id.btnGenLink).setOnClickListener { genLink() }
        findViewById<Button>(R.id.btnUseLink).setOnClickListener { useLink() }
        findViewById<Button>(R.id.btnPeerConnect).setOnClickListener { connectByAccount() }
        findViewById<Button>(R.id.btnEnd).setOnClickListener { endSession() }
        findViewById<Button>(R.id.btnKeyboard).setOnClickListener { showTextDialog() }
        findViewById<Button>(R.id.btnSendFile).setOnClickListener { pickFile() }
        findViewById<Button>(R.id.btnCancelControl).setOnClickListener { endSession() }
        findViewById<Button>(R.id.btnDeny).setOnClickListener { denyRequest() }
        findViewById<Button>(R.id.btnAccept).setOnClickListener { acceptRequest() }
        findViewById<Button>(R.id.btnSettingsDone).setOnClickListener { saveSettings() }
        findViewById<Button>(R.id.btnAccessibility).setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            toast("请找到 remotedesk 并开启「注入服务」")
        }

        btnMic.setOnClickListener { toggleRemoteMedia("mic") }
        btnCamera.setOnClickListener { toggleRemoteMedia("camera") }
        btnBannerMic.setOnClickListener { SessionHub.stopLocalMedia("mic") }
        btnBannerCam.setOnClickListener { SessionHub.stopLocalMedia("camera") }

        renderMedia(false, false, false, false, "")
        bindRemoteTouch()

        btnTabPwd.setOnClickListener { switchAuthTab("pwd") }
        btnTabSms.setOnClickListener { switchAuthTab("sms") }
        btnTabWx.setOnClickListener { switchAuthTab("wx") }
        btnSmsSend.setOnClickListener { sendSms() }
        btnSmsLogin.setOnClickListener { smsLogin() }
        btnWxStart.setOnClickListener { wxStart() }
        btnWxDev.setOnClickListener { wxDevSimulate() }
        loadAuthMethods()
    }

    // ================= 登录 / 注册 =================

    private fun restoreSession() {
        if (Prefs.token.isNotEmpty() && Prefs.server.isNotEmpty()) {
            api = Api(Prefs.server, Prefs.token)
            show(screenHome)
            tvSelf.text = "${Prefs.username} · ${Prefs.deviceName}"
            connectSignaling()
        } else {
            show(screenAuth)
        }
    }

    private fun doAuth(register: Boolean) {
        val server = etServer.text.toString().trim()
        val user = etUser.text.toString().trim()
        val pass = etPass.text.toString()
        tvAuthError.text = ""
        if (server.isEmpty()) {
            tvAuthError.text = "请填写服务器地址"
            return
        }
        if (user.length < 3) {
            tvAuthError.text = "用户名至少 3 位"
            return
        }
        if (pass.length < 6) {
            tvAuthError.text = "密码至少 6 位"
            return
        }
        Prefs.server = server
        val a = Api(server, "")
        scope.launch {
            try {
                val r = if (register) a.register(user, pass, Prefs.deviceName, Prefs.deviceId)
                else a.login(user, pass, Prefs.deviceName, Prefs.deviceId)
                a.token = r.token
                api = a
                afterAuth(r)
            } catch (e: ApiException) {
                tvAuthError.text = e.message ?: "请求失败"
            } catch (e: Throwable) {
                tvAuthError.text = "网络错误：${e.message}"
            }
        }
    }

    /** 三种登录方式共用的收尾：存凭证 → 进主页 → 连信令。 */
    private fun afterAuth(r: AuthResult) {
        Prefs.token = r.token
        Prefs.username = r.username
        Prefs.deviceId = r.deviceId
        tvSelf.text = "${Prefs.username} · ${Prefs.deviceName}"
        show(screenHome)
        connectSignaling()
    }

    // ================= 登录方式（v1.03） =================

    /** 问服务端支持哪些登录方式，未配置的入口隐藏。 */
    private fun loadAuthMethods() {
        val server = etServer.text.toString().trim()
        if (server.isEmpty()) return
        val probe = Api(server, "")
        scope.launch {
            try {
                val m = probe.authMethods()
                authMethods = m
                btnTabSms.visibility = if (m.smsEnabled) View.VISIBLE else View.GONE
                btnTabWx.visibility = if (m.wechatEnabled) View.VISIBLE else View.GONE
                btnWxDev.visibility = if (m.wechatDev) View.VISIBLE else View.GONE
                if (!m.smsEnabled) tvSmsHint.text = "服务端未开启短信登录"
                else if (m.smsDev) tvSmsHint.text = "开发模式：验证码会自动填入"
                if (!m.wechatEnabled) tvWxHint.text = "服务端未配置微信登录（RD_WECHAT_APP_ID / SECRET）"
            } catch (e: Throwable) {
                // 服务器地址还没填对，保持默认页面即可
            }
        }
    }

    private fun switchAuthTab(kind: String) {
        tvAuthError.text = ""
        authPwdPanel.visibility = if (kind == "pwd") View.VISIBLE else View.GONE
        authSmsPanel.visibility = if (kind == "sms") View.VISIBLE else View.GONE
        authWxPanel.visibility = if (kind == "wx") View.VISIBLE else View.GONE
        val active = ContextCompat.getColor(this, R.color.accent2)
        val idle = android.graphics.Color.TRANSPARENT
        val activeText = ContextCompat.getColor(this, R.color.white)
        val idleText = ContextCompat.getColor(this, R.color.muted)
        btnTabPwd.backgroundTintList = android.content.res.ColorStateList.valueOf(if (kind == "pwd") active else idle)
        btnTabSms.backgroundTintList = android.content.res.ColorStateList.valueOf(if (kind == "sms") active else idle)
        btnTabWx.backgroundTintList = android.content.res.ColorStateList.valueOf(if (kind == "wx") active else idle)
        btnTabPwd.setTextColor(if (kind == "pwd") activeText else idleText)
        btnTabSms.setTextColor(if (kind == "sms") activeText else idleText)
        btnTabWx.setTextColor(if (kind == "wx") activeText else idleText)
    }

    private val phoneRe = Regex("^1[3-9]\\d{9}$")

    private fun sendSms() {
        tvAuthError.text = ""
        val server = etServer.text.toString().trim()
        if (server.isEmpty()) {
            tvAuthError.text = "请填写服务器地址"
            return
        }
        val phone = etSmsPhone.text.toString().trim()
        if (!phoneRe.matches(phone)) {
            tvAuthError.text = "请输入 11 位手机号"
            return
        }
        Prefs.server = server
        val a = Api(server, "")
        scope.launch {
            try {
                val devCode = a.sendSmsCode(phone)
                if (!devCode.isNullOrEmpty()) {
                    etSmsCode.setText(devCode)
                    tvSmsHint.text = "开发模式：验证码已自动填入（$devCode）"
                } else {
                    tvSmsHint.text = "验证码已发送，5 分钟内有效"
                }
                startSmsCountdown(60)
            } catch (e: ApiException) {
                tvAuthError.text = e.message ?: "发送失败"
                btnSmsSend.isEnabled = true
            } catch (e: Throwable) {
                tvAuthError.text = "网络错误：${e.message}"
                btnSmsSend.isEnabled = true
            }
        }
    }

    private fun startSmsCountdown(seconds: Int) {
        smsCountdown?.removeCallbacksAndMessages(null)
        val handler = android.os.Handler(mainLooper)
        smsCountdown = handler
        var left = seconds
        btnSmsSend.isEnabled = false
        val tick = object : Runnable {
            override fun run() {
                if (left <= 0) {
                    btnSmsSend.isEnabled = true
                    btnSmsSend.text = getString(R.string.btn_send_code)
                    return
                }
                btnSmsSend.text = "${left}s"
                left--
                handler.postDelayed(this, 1000)
            }
        }
        handler.post(tick)
    }

    private fun smsLogin() {
        tvAuthError.text = ""
        val server = etServer.text.toString().trim()
        if (server.isEmpty()) {
            tvAuthError.text = "请填写服务器地址"
            return
        }
        val phone = etSmsPhone.text.toString().trim()
        val code = etSmsCode.text.toString().trim()
        if (!phoneRe.matches(phone)) {
            tvAuthError.text = "请输入 11 位手机号"
            return
        }
        if (code.length != 6) {
            tvAuthError.text = "请输入 6 位验证码"
            return
        }
        Prefs.server = server
        val a = Api(server, "")
        scope.launch {
            try {
                val r = a.smsLogin(phone, code, Prefs.deviceName, Prefs.deviceId)
                a.token = r.token
                api = a
                afterAuth(r)
            } catch (e: ApiException) {
                tvAuthError.text = e.message ?: "登录失败"
            } catch (e: Throwable) {
                tvAuthError.text = "网络错误：${e.message}"
            }
        }
    }

    private fun wxStart() {
        tvAuthError.text = ""
        val server = etServer.text.toString().trim()
        if (server.isEmpty()) {
            tvAuthError.text = "请填写服务器地址"
            return
        }
        Prefs.server = server
        val a = Api(server, "")
        scope.launch {
            try {
                val session = a.wechatAuthUrl(Prefs.deviceName, Prefs.deviceId)
                wxState = session.state
                tvWxHint.text = "已打开授权页，扫码后会自动登录…"
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(session.url)))
                } catch (e: Throwable) {
                    tvWxHint.text = "无法打开浏览器，请手动访问：${session.url}"
                }
                pollWechat(session.state)
            } catch (e: ApiException) {
                tvAuthError.text = e.message ?: "发起微信登录失败"
            } catch (e: Throwable) {
                tvAuthError.text = "网络错误：${e.message}"
            }
        }
    }

    /** 轮询扫码结果：拿到 token 就登录，最多等 10 分钟。 */
    private fun pollWechat(state: String) {
        wxPollJob?.cancel()
        val a = api ?: Api(Prefs.server, "")
        wxPollJob = scope.launch {
            val started = System.currentTimeMillis()
            while (isActive && wxState == state && System.currentTimeMillis() - started < 10 * 60_000) {
                delay(2000)
                if (wxState != state) return@launch
                try {
                    val r = a.wechatPoll(state)
                    when (r.status) {
                        "ok" -> {
                            wxState = ""
                            a.token = r.token
                            api = a
                            afterAuth(
                                AuthResult(
                                    token = r.token,
                                    userId = r.userId,
                                    deviceId = r.deviceId.ifBlank { Prefs.deviceId },
                                    username = r.username
                                )
                            )
                            return@launch
                        }

                        "error" -> {
                            wxState = ""
                            tvWxHint.text = "登录失败：" + (r.message.ifBlank { "授权被拒绝" })
                            return@launch
                        }

                        "expired", "consumed" -> {
                            wxState = ""
                            tvWxHint.text = "二维码已失效，请重新发起"
                            return@launch
                        }

                        else -> {
                            val sec = (System.currentTimeMillis() - started) / 1000
                            tvWxHint.text = "等待扫码…（${sec}s）"
                        }
                    }
                } catch (e: Throwable) {
                    // 网络抖动继续轮询
                }
            }
        }
    }

    private fun wxDevSimulate() {
        if (wxState.isEmpty()) {
            tvAuthError.text = "请先点「打开微信扫码登录」"
            return
        }
        val a = api ?: Api(Prefs.server, "")
        scope.launch {
            try {
                a.wechatDevSimulate(wxState, "dev-openid-" + Prefs.deviceId.take(8))
                tvWxHint.text = "已模拟扫码，正在登录…"
            } catch (e: Throwable) {
                tvAuthError.text = e.message ?: "模拟失败"
            }
        }
    }

    private fun logout() {
        endSession()
        signaling?.close()
        signaling = null
        api = null
        Prefs.clearAuth()
        show(screenAuth)
        dotState.setBackgroundColor(ContextCompat.getColor(this, R.color.muted))
    }

    // ================= 信令 =================

    private fun connectSignaling() {
        if (Prefs.token.isEmpty()) return
        signaling?.close()
        val s = Signaling(Prefs.server)
        signaling = s
        SessionHub.signaling = s
        s.listener = object : Signaling.Listener {
            override fun onOpen() {
                runOnUiThread {
                    dotState.setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.ok))
                    refreshDevices()
                }
            }

            override fun onMessage(msg: JSONObject) {
                runOnUiThread { onWs(msg) }
            }

            override fun onClosed(reason: String) {
                runOnUiThread {
                    dotState.setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.muted))
                }
            }
        }
        s.connect(Prefs.token)
    }

    private fun onWs(msg: JSONObject) {
        when (msg.optString("type")) {
            "offer", "answer", "ice" -> SessionHub.onWs(msg)

            "devices" -> {
                val arr = msg.opt("data")
                if (arr is JSONArray) {
                    val list = ArrayList<DeviceItem>()
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        list.add(
                            DeviceItem(
                                id = o.optString("id"),
                                name = o.optString("name"),
                                os = o.optString("os"),
                                online = o.optBoolean("online"),
                                micEnabled = o.optBoolean("mic_enabled"),
                                cameraEnabled = o.optBoolean("camera_enabled")
                            )
                        )
                    }
                    renderDevices(list)
                }
            }

            "session_req" -> {
                val d = msg.optJSONObject("data")
                reqSessionId = msg.optString("session_id")
                reqPeer = msg.optString("from")
                reqController = d?.optString("controller_name").orEmpty().ifBlank { "对方设备" }
                reqPolicy = MediaPolicy.from(d?.optJSONObject("media")) ?: MediaPolicy.NONE
                val mode = d?.optString("auth_mode").orEmpty()
                val tip = when (mode) {
                    "link" -> "通过统一链接"
                    "account" -> "通过账号密码"
                    else -> "同账号设备"
                }
                tvReqText.text = "「$reqController」请求远程控制本机（$tip）。\n同意后对方将看到本机屏幕，你可以随时点「取消控制」中断。"
                tvReqMedia.text = policySummary(reqPolicy)
                reqDialog.visibility = View.VISIBLE
            }

            "session_ok" -> {
                val d = msg.optJSONObject("data")
                val turn = Api.parseTurn(d?.optJSONObject("turn"))
                val media = MediaPolicy.from(d?.optJSONObject("media")) ?: MediaPolicy.NONE
                val sid = msg.optString("session_id")
                waitingApprove = false
                startController(sid, msg.optString("from"), turn, "", media)
            }

            "session_deny" -> {
                waitingApprove = false
                toast("对方拒绝了控制请求")
                show(screenHome)
            }

            "control_start" -> {
                val d = msg.optJSONObject("data")
                val turn = Api.parseTurn(d?.optJSONObject("turn"))
                val name = d?.optString("controller_name").orEmpty().ifBlank { "对方设备" }
                val media = MediaPolicy.from(d?.optJSONObject("media")) ?: MediaPolicy.NONE
                beginControlled(msg.optString("session_id"), msg.optString("from"), name, turn, media)
            }

            "control_end" -> {
                SessionHub.remoteEnded("对方已结束控制")
            }

            "error" -> {
                val d = msg.optJSONObject("data")
                toast(d?.optString("message").orEmpty().ifBlank { "服务器返回错误" })
            }
        }
    }

    // ================= 设备与控制 =================

    private fun refreshDevices() {
        val a = api ?: return
        scope.launch {
            try {
                renderDevices(a.devices())
            } catch (e: Throwable) {
                Log.w(TAG, "refresh devices failed", e)
            }
        }
    }

    private fun renderDevices(list: List<DeviceItem>) {
        deviceList.removeAllViews()
        val others = list.filter { it.id != Prefs.deviceId }
        tvNoDevices.visibility = if (others.isEmpty()) View.VISIBLE else View.GONE
        for (d in others) {
            val row = layoutInflater.inflate(R.layout.item_device, deviceList, false)
            row.findViewById<TextView>(R.id.tvName).text = d.name
            val media = buildString {
                if (d.micEnabled) append("语音")
                if (d.cameraEnabled) append(if (isEmpty()) "摄像头" else "/摄像头")
            }
            row.findViewById<TextView>(R.id.tvMeta).text =
                "${d.os} · ${if (d.online) "在线" else "离线"}" + if (media.isNotEmpty()) " · 开放$media" else ""
            row.findViewById<View>(R.id.dot).setBackgroundColor(
                ContextCompat.getColor(this, if (d.online) R.color.ok else R.color.muted)
            )
            row.findViewById<Button>(R.id.btnConnect).apply {
                isEnabled = d.online
                setOnClickListener { connectSameAccount(d) }
            }
            deviceList.addView(row)
        }
    }

    private fun connectSameAccount(d: DeviceItem) {
        val a = api ?: return
        if (SessionHub.isActive() || waitingApprove) {
            toast("已有会话进行中")
            return
        }
        val payload = JSONObject().apply {
            put("target_device_id", d.id)
            put("auth", JSONObject().put("mode", "same_account"))
        }
        scope.launch {
            try {
                val r = a.requestSession(payload)
                if (r.status == "active") {
                    startController(r.sessionId, d.id, r.turn, d.name, r.media ?: MediaPolicy.NONE)
                } else {
                    waitingApprove = true
                    pendingSessionId = r.sessionId
                    pendingPeer = d.id
                    peerPolicy = r.media ?: MediaPolicy.NONE
                    toast("等待「${d.name}」同意…")
                }
            } catch (e: ApiException) {
                toast(e.message ?: "连接失败")
            } catch (e: Throwable) {
                toast("网络错误：${e.message}")
            }
        }
    }

    private fun genLink() {
        val a = api ?: return
        scope.launch {
            try {
                val r = a.createLink()
                tvLinkCode.text = r.code
                tvLinkCode.visibility = View.VISIBLE
                startLinkCountdown(r)
            } catch (e: Throwable) {
                toast("生成链接失败：${e.message}")
            }
        }
    }

    private fun startLinkCountdown(r: LinkResult) {
        linkTicker?.removeCallbacksAndMessages(null)
        val handler = android.os.Handler(mainLooper)
        linkTicker = handler
        val endAt = System.currentTimeMillis() + r.ttlMinutes * 60_000L
        val tick = object : Runnable {
            override fun run() {
                val left = endAt - System.currentTimeMillis()
                if (left <= 0) {
                    tvLinkExpire.text = "链接已过期，请重新生成"
                    tvLinkCode.visibility = View.GONE
                    return
                }
                val m = left / 60_000
                val s = (left % 60_000) / 1000
                tvLinkExpire.text = "有效期剩余 %d:%02d，使用一次即失效".format(m, s)
                handler.postDelayed(this, 1000)
            }
        }
        handler.post(tick)
    }

    private fun useLink() {
        val a = api ?: return
        val code = etLink.text.toString().trim().uppercase()
        if (code.length < 6) {
            toast("请输入链接码")
            return
        }
        val payload = JSONObject().apply {
            put("auth", JSONObject().apply {
                put("mode", "link")
                put("link_code", code)
            })
        }
        scope.launch {
            try {
                val r = a.requestSession(payload)
                if (r.status == "active") {
                    startController(r.sessionId, "", r.turn, "链接设备", r.media ?: MediaPolicy.NONE)
                } else {
                    waitingApprove = true
                    pendingSessionId = r.sessionId
                    toast("等待对方同意…")
                }
            } catch (e: ApiException) {
                toast(e.message ?: "链接无效")
            } catch (e: Throwable) {
                toast("网络错误：${e.message}")
            }
        }
    }

    // ---- 控制端 ----

    /**
     * 账号密码连接：先用对方账号查出他名下的设备，选一台在线发起请求。
     * 服务端会把这次请求打成 pending，对方必须在弹窗里点「同意」。
     */
    private fun connectByAccount() {
        val a = api ?: return
        val user = etPeerUser.text.toString().trim()
        val pass = etPeerPass.text.toString()
        if (user.isEmpty() || pass.isEmpty()) {
            toast("请填写对方的账号和密码")
            return
        }
        scope.launch {
            try {
                val list = a.lookup(user, pass)
                val targets = list.filter { it.online && it.id != Prefs.deviceId }
                if (targets.isEmpty()) {
                    toast("该账号下没有在线设备")
                    return@launch
                }
                val names = targets.map { "${it.name}（${it.os}）" }.toTypedArray()
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("选择要控制的设备")
                    .setItems(names) { _, idx ->
                        requestByAccount(targets[idx], user, pass)
                    }
                    .setNegativeButton("取消", null)
                    .show()
            } catch (e: ApiException) {
                toast(if (e.code == 401) "账号或密码错误" else (e.message ?: "查询失败"))
            } catch (e: Throwable) {
                toast("网络错误：${e.message}")
            }
        }
    }

    private fun requestByAccount(d: DeviceItem, user: String, pass: String) {
        val a = api ?: return
        if (SessionHub.isActive() || waitingApprove) {
            toast("已有会话进行中")
            return
        }
        val payload = JSONObject().apply {
            put("target_device_id", d.id)
            put("auth", JSONObject().apply {
                put("mode", "account")
                put("username", user)
                put("password", pass)
            })
        }
        scope.launch {
            try {
                val r = a.requestSession(payload)
                if (r.status == "active") {
                    startController(r.sessionId, d.id, r.turn, d.name, r.media ?: MediaPolicy.NONE)
                } else {
                    waitingApprove = true
                    pendingSessionId = r.sessionId
                    pendingPeer = d.id
                    peerPolicy = r.media ?: MediaPolicy.NONE
                    toast("已发送请求，等待「${d.name}」同意…")
                }
            } catch (e: ApiException) {
                toast(e.message ?: "连接失败")
            } catch (e: Throwable) {
                toast("网络错误：${e.message}")
            }
        }
    }

    private fun startController(
        sessionId: String,
        peer: String,
        turn: TurnInfo?,
        name: String,
        policy: MediaPolicy
    ) {
        val sig = signaling ?: return
        peerPolicy = policy
        wantMic = false
        wantCam = false
        val client = RtcClient("controller", sessionId, peer, turn, sig, policy)
        SessionHub.attach(client, "controller", sessionId, peer, name, policy)
        client.start(this)
        tvRemoteTitle.text = "正在连接 ${name.ifBlank { "对方设备" }}…"
        tvTransfer.text = ""
        renderMedia(policy.mic, policy.camera, false, false, "")
        show(screenRemote)
    }

    // ---- 被控端 ----

    private fun beginControlled(
        sessionId: String,
        peer: String,
        name: String,
        turn: TurnInfo?,
        policy: MediaPolicy
    ) {
        pendingSessionId = sessionId
        pendingPeer = peer
        pendingController = name
        pendingTurn = turn
        pendingPolicy = policy
        // 先要系统权限，再拉 MediaProjection：两个授权弹窗按依赖顺序出现，不易被用户漏点
        ensurePermissions(policy.mic, policy.camera) { launchProjection() }
    }

    private fun launchProjection() {
        val mgr = getSystemService(MediaProjectionManager::class.java)
        if (mgr == null) {
            toast("本机不支持屏幕共享")
            return
        }
        projectionLauncher.launch(mgr.createScreenCaptureIntent())
    }

    /** 缺哪个申请哪个，申请完（无论允许与否）都继续走 then。 */
    private fun ensurePermissions(mic: Boolean, camera: Boolean, then: () -> Unit) {
        val missing = Permissions.missingFor(this, mic, camera)
        if (missing.isEmpty()) {
            then()
            return
        }
        afterPermission = then
        mediaPermLauncher.launch(missing)
    }

    private fun showControlledUi(name: String) {
        show(screenHome)
        tvBanner.text = "正在被「$name」控制 · 你可以随时取消"
        controlBanner.visibility = View.VISIBLE
        renderMedia(pendingPolicy.mic, pendingPolicy.camera, false, false, "")
        if (!InjectorService.alive) {
            toast("未开启无障碍服务，对方暂时无法点击本机屏幕")
        }
    }

    private fun acceptRequest() {
        reqDialog.visibility = View.GONE
        val a = api ?: return
        scope.launch {
            try {
                val r = a.acceptSession(reqSessionId, true)
                if (r.status == "active") {
                    beginControlled(reqSessionId, reqPeer, reqController, r.turn, r.media ?: reqPolicy)
                } else {
                    toast("已同意")
                }
            } catch (e: Throwable) {
                toast("操作失败：${e.message}")
            }
        }
    }

    private fun denyRequest() {
        reqDialog.visibility = View.GONE
        val a = api ?: return
        scope.launch {
            try {
                a.acceptSession(reqSessionId, false)
            } catch (_: Throwable) {
            }
        }
    }

    private fun endSession() {
        reqDialog.visibility = View.GONE
        if (SessionHub.isActive()) {
            SessionHub.end("已结束会话")
        } else {
            show(screenHome)
        }
        controlBanner.visibility = View.GONE
        tvRemoteTitle.text = "远程控制中"
        tvMediaState.text = ""
        cameraRenderer.visibility = View.GONE
    }

    // ================= 语音 / 摄像头 UI =================

    private fun toggleRemoteMedia(kind: String) {
        if (!SessionHub.isController() || !SessionHub.isActive()) return
        val allowed = if (kind == "mic") peerPolicy.mic else peerPolicy.camera
        if (!allowed) {
            toast("对方未开放${if (kind == "mic") "麦克风" else "摄像头"}权限，请对方在设置里打开后重连")
            return
        }
        if (kind == "mic") wantMic = !wantMic else wantCam = !wantCam
        SessionHub.requestRemoteMedia(wantMic, wantCam)
        renderMedia(peerPolicy.mic, peerPolicy.camera, SessionHub.micOn, SessionHub.camOn, "")
    }

    private fun renderMedia(
        policyMic: Boolean,
        policyCam: Boolean,
        micOn: Boolean,
        camOn: Boolean,
        reason: String
    ) {
        val controller = SessionHub.isController() && SessionHub.isActive()
        val fmt = { allowed: Boolean, on: Boolean, label: String ->
            when {
                on -> "$label 已开"
                !allowed -> "$label 已关权限"
                else -> "$label 未开"
            }
        }
        val summary = fmt(policyMic, micOn, "麦克风") + " · " + fmt(policyCam, camOn, "摄像头")
        val tail = when (reason) {
            "" -> ""
            "policy_off" -> " · 被控端已关闭该权限"
            "permission_denied" -> " · 系统权限未授予"
            "no_device" -> " · 没有可用设备"
            "busy" -> " · 设备被其他程序占用"
            else -> " · 不可用（$reason）"
        }
        tvMediaState.text = summary + tail

        if (controller) {
            btnMic.visibility = if (policyMic) View.VISIBLE else View.GONE
            btnCamera.visibility = if (policyCam) View.VISIBLE else View.GONE
            btnMic.text = if (micOn) "语音·开" else "语音"
            btnCamera.text = if (camOn) "摄像头·开" else "摄像头"
        } else {
            btnMic.visibility = View.GONE
            btnCamera.visibility = View.GONE
            btnBannerMic.isEnabled = micOn
            btnBannerCam.isEnabled = camOn
            btnBannerMic.text = if (micOn) "关麦克风" else "麦克风已关"
            btnBannerCam.text = if (camOn) "关摄像头" else "摄像头已关"
            if (!camOn) cameraRenderer.visibility = View.GONE
        }
    }

    private fun showMediaProblem(kind: String, reason: String) {
        val what = if (kind == "mic") "麦克风" else "摄像头"
        val msg = when (reason) {
            "permission_denied" -> "系统未允许使用${what}。点「去设置」在权限里打开后重试。"
            "no_device" -> "本机没有可用的${what}。"
            "busy" -> "${what}正被其他应用占用，请关闭后重试。"
            "policy_off" -> "设置里已关闭${what}，本次不会采集。"
            else -> "${what}打开失败：$reason"
        }
        AlertDialog.Builder(this)
            .setTitle("$what 未能开启")
            .setMessage(msg)
            .setPositiveButton("去设置") { _, _ ->
                if (reason == "permission_denied") Permissions.openAppSettings(this) else openSettings()
            }
            .setNegativeButton("知道了", null)
            .show()
    }

    private fun policySummary(p: MediaPolicy): String {
        val parts = ArrayList<String>(2)
        if (p.mic) parts.add("麦克风")
        if (p.camera) parts.add("摄像头")
        return if (parts.isEmpty()) {
            "本次不开放麦克风 / 摄像头"
        } else {
            "本次允许对方使用：${parts.joinToString("、")}（连上后仍可随时关闭）"
        }
    }

    // ================= 远程画面交互 =================

    private var lastX = 0f
    private var lastY = 0f
    private var downAt = 0L

    private fun bindRemoteTouch() {
        renderer.setOnTouchListener { _, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    lastX = ev.x
                    lastY = ev.y
                    downAt = System.currentTimeMillis()
                    sendTouch("down", ev.x, ev.y)
                }

                MotionEvent.ACTION_MOVE -> {
                    if (Math.abs(ev.x - lastX) > 2 || Math.abs(ev.y - lastY) > 2) {
                        sendTouch("move", ev.x, ev.y)
                        lastX = ev.x
                        lastY = ev.y
                    }
                }

                MotionEvent.ACTION_UP -> {
                    sendTouch("up", ev.x, ev.y)
                }

                MotionEvent.ACTION_CANCEL -> {
                    sendTouch("cancel", ev.x, ev.y)
                }
            }
            true
        }
    }

    private fun sendTouch(action: String, x: Float, y: Float) {
        val (nx, ny) = normalize(x, y) ?: return
        SessionHub.sendInput(JSONObject().apply {
            put("type", "touch")
            put("action", action)
            put("x", nx.toDouble())
            put("y", ny.toDouble())
        })
    }

    /** 把渲染视图坐标按 letterbox 反算成 0..1 的画面坐标。 */
    private fun normalize(x: Float, y: Float): Pair<Float, Float>? {
        val vw = renderer.width.toFloat()
        val vh = renderer.height.toFloat()
        if (vw <= 0f || vh <= 0f) return null
        val (fw, fh) = frameSize
        if (fw <= 0 || fh <= 0) {
            return Pair((x / vw).coerceIn(0f, 1f), (y / vh).coerceIn(0f, 1f))
        }
        val frameAspect = fw.toFloat() / fh.toFloat()
        val viewAspect = vw / vh
        var dw = vw
        var dh = vh
        var ox = 0f
        var oy = 0f
        if (viewAspect > frameAspect) {
            dw = vh * frameAspect
            ox = (vw - dw) / 2f
        } else {
            dh = vw / frameAspect
            oy = (vh - dh) / 2f
        }
        val nx = ((x - ox) / dw).coerceIn(0f, 1f)
        val ny = ((y - oy) / dh).coerceIn(0f, 1f)
        return Pair(nx, ny)
    }

    private var frameSize = Pair(0, 0)

    private fun showTextDialog() {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            hint = "输入要发送到对方的内容"
            setSingleLine(false)
        }
        AlertDialog.Builder(this)
            .setTitle("发送文本")
            .setView(input)
            .setPositiveButton("发送") { _, _ ->
                val t = input.text.toString()
                if (t.isNotEmpty()) {
                    SessionHub.sendInput(JSONObject().apply {
                        put("type", "text")
                        put("text", t)
                    })
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ================= 文件 =================

    private fun pickFile() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        filePicker.launch(i)
    }

    private fun queryFile(uri: Uri): Pair<String, Long> {
        var name = "file"
        var size = -1L
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0) name = c.getString(ni) ?: name
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "query file failed", e)
        }
        return Pair(name, size)
    }

    // ================= 设置 =================

    private fun openSettings() {
        val a = api ?: return
        scope.launch {
            try {
                val s = a.getSettings()
                cbAutoAccept.isChecked = s.optBoolean("auto_accept_same_account", false)
                cbMic.isChecked = s.optBoolean("mic_enabled", false)
                cbCamera.isChecked = s.optBoolean("camera_enabled", false)
                settingsDialog.visibility = View.VISIBLE
            } catch (e: Throwable) {
                toast("读取设置失败：${e.message}")
            }
        }
    }

    private fun saveSettings() {
        val a = api ?: return
        val mic = cbMic.isChecked
        val camera = cbCamera.isChecked
        val patch = JSONObject().apply {
            put("auto_accept_same_account", cbAutoAccept.isChecked)
            put("mic_enabled", mic)
            put("camera_enabled", camera)
        }
        scope.launch {
            try {
                a.putSettings(patch)
                settingsDialog.visibility = View.GONE
                // 会话中改了设置：立刻让当前会话生效（关闭就停采集）
                if (SessionHub.isActive() && !SessionHub.isController()) {
                    SessionHub.applyPolicy(MediaPolicy(mic, camera))
                }
                // 打开开关时顺手把运行时权限也申请掉，避免被控时才弹窗
                if (mic || camera) {
                    ensurePermissions(mic, camera) { }
                }
                toast("设置已保存")
            } catch (e: Throwable) {
                toast("保存失败：${e.message}")
            }
        }
    }

    // ================= 小工具 =================

    private fun show(v: View) {
        screenAuth.visibility = if (v === screenAuth) View.VISIBLE else View.GONE
        screenHome.visibility = if (v === screenHome) View.VISIBLE else View.GONE
        screenRemote.visibility = if (v === screenRemote) View.VISIBLE else View.GONE
    }

    private fun toast(s: String) {
        if (s.isBlank()) return
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show()
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val ok = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
        if (ok != PackageManager.PERMISSION_GRANTED) {
            notifPerm.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}
