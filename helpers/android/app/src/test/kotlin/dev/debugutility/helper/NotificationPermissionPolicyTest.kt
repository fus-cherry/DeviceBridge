package dev.debugutility.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPermissionPolicyTest {
    @Test
    fun `ordinary helper launch never requests notification permission`() {
        assertFalse(NotificationPermissionPolicy.shouldRequest(action = null, requiresRuntimePermission = true, granted = false))
        assertFalse(NotificationPermissionPolicy.shouldRequest(action = "android.intent.action.MAIN", requiresRuntimePermission = true, granted = false))
    }

    @Test
    fun `explicit keepalive permission action requests only when required and denied`() {
        assertTrue(NotificationPermissionPolicy.shouldRequest(
            action = NotificationPermissionPolicy.ACTION_REQUEST_KEEPALIVE_PERMISSION,
            requiresRuntimePermission = true,
            granted = false
        ))
        assertFalse(NotificationPermissionPolicy.shouldRequest(
            action = NotificationPermissionPolicy.ACTION_REQUEST_KEEPALIVE_PERMISSION,
            requiresRuntimePermission = false,
            granted = false
        ))
        assertFalse(NotificationPermissionPolicy.shouldRequest(
            action = NotificationPermissionPolicy.ACTION_REQUEST_KEEPALIVE_PERMISSION,
            requiresRuntimePermission = true,
            granted = true
        ))
    }
}
