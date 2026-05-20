package com.example.spic

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var deeplinkChannel: MethodChannel? = null
    private var nativeActionsChannel: MethodChannel? = null
    private var apkInstallerChannel: MethodChannel? = null
    private var initialLink: String? = null
    private var initialNativeAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        initialLink = readTrustTunnelLink(intent)
        initialNativeAction = readNativeAction(intent)
        deeplinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEPLINK_CHANNEL,
        )
        deeplinkChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> {
                    result.success(initialLink)
                    initialLink = null
                }
                else -> result.notImplemented()
            }
        }

        nativeActionsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_ACTIONS_CHANNEL,
        )
        nativeActionsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialAction" -> {
                    result.success(initialNativeAction)
                    initialNativeAction = null
                }
                else -> result.notImplemented()
            }
        }

        apkInstallerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APK_INSTALLER_CHANNEL,
        )
        apkInstallerChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "APK path is empty", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(null)
                        } catch (error: Throwable) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val action = readNativeAction(intent)
        if (action != null) {
            val channel = nativeActionsChannel
            if (channel == null) {
                initialNativeAction = action
            } else {
                channel.invokeMethod("onAction", action)
            }
            return
        }

        val link = readTrustTunnelLink(intent)
        if (link != null) {
            val channel = deeplinkChannel
            if (channel == null) {
                initialLink = link
            } else {
                channel.invokeMethod("onLink", link)
            }
        }
    }

    private fun readTrustTunnelLink(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) {
            return null
        }

        val link = intent.dataString?.trim()
        if (link.isNullOrEmpty() || !link.startsWith("tt://", ignoreCase = true)) {
            return null
        }

        return link
    }

    private fun readNativeAction(intent: Intent?): String? {
        val action = intent?.action ?: return null
        return when (action) {
            ACTION_OPEN_DIAGNOSTICS -> NATIVE_ACTION_OPEN_DIAGNOSTICS
            ACTION_OPEN_FROM_TILE -> NATIVE_ACTION_OPEN_FROM_TILE
            else -> null
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }

        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    private fun installApk(path: String) {
        val apk = File(path)
        require(apk.exists() && apk.isFile) { "APK file does not exist" }

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    companion object {
        private const val DEEPLINK_CHANNEL = "spic/deeplink"
        private const val NATIVE_ACTIONS_CHANNEL = "spic/native_actions"
        private const val APK_INSTALLER_CHANNEL = "spic/apk_installer"
        private const val ACTION_OPEN_DIAGNOSTICS =
            "com.example.spic.action.OPEN_DIAGNOSTICS"
        private const val ACTION_OPEN_FROM_TILE =
            "com.example.spic.action.OPEN_FROM_TILE"
        private const val NATIVE_ACTION_OPEN_DIAGNOSTICS = "open_diagnostics"
        private const val NATIVE_ACTION_OPEN_FROM_TILE = "open_from_tile"
        private const val REQUEST_POST_NOTIFICATIONS = 2401
    }
}
