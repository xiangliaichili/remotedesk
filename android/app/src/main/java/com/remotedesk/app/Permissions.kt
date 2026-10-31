package com.remotedesk.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat

/**
 * 麦克风 / 摄像头运行时权限。
 *
 * Android 6+ 这两个权限都是「危险权限」，必须在运行时申请，Manifest 里声明只是前提。
 * 被拒后再次申请若用户勾了「不再询问」，系统会直接返回拒绝且不弹窗——此时只能引导去应用设置页。
 */
object Permissions {

    const val MIC = Manifest.permission.RECORD_AUDIO
    const val CAMERA = Manifest.permission.CAMERA

    fun granted(ctx: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, permission) == PackageManager.PERMISSION_GRANTED

    fun micGranted(ctx: Context): Boolean = granted(ctx, MIC)

    fun cameraGranted(ctx: Context): Boolean = granted(ctx, CAMERA)

    /** 只返回「需要且尚未授予」的权限，避免无意义弹窗。 */
    fun missingFor(ctx: Context, mic: Boolean, camera: Boolean): Array<String> {
        val out = ArrayList<String>(2)
        if (mic && !micGranted(ctx)) out.add(MIC)
        if (camera && !cameraGranted(ctx)) out.add(CAMERA)
        return out.toTypedArray()
    }

    /** 语音 + 摄像头一起申请（设置里两个开关都打开时用）。 */
    fun allMedia(): Array<String> = arrayOf(MIC, CAMERA)

    /** 跳转到本应用的系统设置页（用户勾了「不再询问」时的唯一出路）。 */
    fun openAppSettings(ctx: Context) {
        val i = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", ctx.packageName, null)
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
    }

    /** 本机是否有摄像头硬件（部分平板/模拟器没有）。 */
    fun hasCamera(ctx: Context): Boolean =
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

    /** 权限被拒的理由文案。 */
    fun deniedHint(mic: Boolean, camera: Boolean): String {
        val parts = ArrayList<String>(2)
        if (mic) parts.add("麦克风")
        if (camera) parts.add("摄像头")
        return "未获得${parts.joinToString("、")}权限，对方将听不到/看不到本机。" +
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) "可到「设置 → 应用 → 远程桌面 → 权限」中开启。" else ""
    }
}
