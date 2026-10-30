package com.remotedesk.app

import android.app.Application
import org.webrtc.PeerConnectionFactory

/**
 * 应用入口：初始化 WebRTC 全局工厂（进程内只能初始化一次）。
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

        factory = PeerConnectionFactory.builder()
            .setOptions(PeerConnectionFactory.Options())
            .createPeerConnectionFactory()
    }

    companion object {
        lateinit var instance: App
            private set

        lateinit var factory: PeerConnectionFactory
            private set
    }
}
