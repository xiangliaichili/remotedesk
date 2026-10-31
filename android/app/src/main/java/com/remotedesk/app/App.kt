package com.remotedesk.app

import android.app.Application
import org.webrtc.PeerConnectionFactory
import org.webrtc.audio.JavaAudioDeviceModule

/**
 * 应用入口：初始化 WebRTC 全局工厂（进程内只能初始化一次）。
 *
 * v1.02 起必须安装 [JavaAudioDeviceModule]：
 *  · Android 上没有默认音频设备模块时 `createAudioSource()` 会返回 null，麦克风轨道建不出来；
 *  · 远端音频也依赖它播放（WebRTC 只负责收包，不负责开扬声器）。
 */
class App : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        Prefs.init(this)

        val opts = PeerConnectionFactory.InitializationOptions.builder(this)
            .setEnableInternalTracer(false)
            .createInitializationOptions()
        PeerConnectionFactory.initialize(opts)

        audioDevice = JavaAudioDeviceModule.builder(this)
            // 硬件回声消除/降噪让「边看屏幕边说话」可用；设备不支持时 WebRTC 自动降级
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()

        factory = PeerConnectionFactory.builder()
            .setOptions(PeerConnectionFactory.Options())
            .setAudioDeviceModule(audioDevice)
            .createPeerConnectionFactory()
    }

    companion object {
        lateinit var instance: App
            private set

        lateinit var factory: PeerConnectionFactory
            private set

        /** 语音采集/播放的设备模块。 */
        lateinit var audioDevice: JavaAudioDeviceModule
            private set
    }
}
