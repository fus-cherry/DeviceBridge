package dev.debugutility.helper

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.TextView

class MainActivity : Activity() {
    private var clipboardBridge: ClipboardBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            gravity = Gravity.CENTER
            text = "Device Bridge Helper\nManaged by the Mac application\n\nWi-Fi maintenance is visible in a notification and may use additional battery."
        })
        if (NotificationPermissionPolicy.shouldRequest(
                action = intent?.action,
                requiresRuntimePermission = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU,
                granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            )) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
        clipboardBridge = ClipboardBridge(this).also { it.start() }
    }

    override fun onDestroy() {
        clipboardBridge?.close()
        clipboardBridge = null
        super.onDestroy()
    }
}
