package dev.debugutility.helper

internal object NotificationPermissionPolicy {
    const val ACTION_REQUEST_KEEPALIVE_PERMISSION =
        "dev.debugutility.helper.action.REQUEST_KEEPALIVE_PERMISSION"

    fun shouldRequest(action: String?, requiresRuntimePermission: Boolean, granted: Boolean): Boolean {
        return action == ACTION_REQUEST_KEEPALIVE_PERMISSION && requiresRuntimePermission && !granted
    }
}
