package dev.debugutility.helper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeepAliveServiceTest {
    @Test
    fun `start creates a 30 second visible lease and acquires resources once`() {
        val clock = FakeLeaseClock(1_000)
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(clock, resources, listOf("lease-a"))

        val status = coordinator.start()

        assertEquals(KeepAliveLeasePhase.ACTIVE, status.phase)
        assertEquals("lease-a", status.leaseId)
        assertEquals(1_000L, status.startedAtMillis)
        assertEquals(31_000L, status.expiresAtMillis)
        assertTrue(status.notificationVisible)
        assertTrue(status.wifiLockHeld)
        assertEquals(1, resources.acquireCount)
        assertEquals(0, resources.releaseCount)
    }

    @Test
    fun `renew extends from current time by at most 30 seconds and status does not renew`() {
        val clock = FakeLeaseClock(2_000)
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(clock, resources, listOf("lease-b"))
        val started = coordinator.start()

        clock.nowMillis = 11_000
        val observed = coordinator.status()
        assertEquals(started.expiresAtMillis, observed.expiresAtMillis)

        val renewed = coordinator.renew("lease-b")
        assertEquals(41_000L, renewed.expiresAtMillis)
        assertEquals(11_000L, renewed.renewedAtMillis)
        assertEquals(1, resources.acquireCount)
    }

    @Test
    fun `wrong lease cannot renew and expiry releases all resources`() {
        val clock = FakeLeaseClock(3_000)
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(clock, resources, listOf("lease-c"))
        val started = coordinator.start()

        clock.nowMillis = 10_000
        val wrongLease = coordinator.renew("another-lease")
        assertEquals(KeepAliveLeasePhase.ACTIVE, wrongLease.phase)
        assertEquals(started.expiresAtMillis, wrongLease.expiresAtMillis)

        clock.nowMillis = 33_000
        val expired = coordinator.status()
        assertEquals(KeepAliveLeasePhase.EXPIRED, expired.phase)
        assertNull(expired.leaseId)
        assertFalse(expired.notificationVisible)
        assertFalse(expired.wifiLockHeld)
        assertEquals(1, resources.releaseCount)
    }

    @Test
    fun `stop is idempotent and a new start uses a different lease`() {
        val clock = FakeLeaseClock(4_000)
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(clock, resources, listOf("lease-d", "lease-e"))
        val first = coordinator.start()

        val stopped = coordinator.stop("lease-d")
        val stoppedAgain = coordinator.stop("lease-d")
        assertEquals(KeepAliveLeasePhase.STOPPED, stopped.phase)
        assertEquals(stopped, stoppedAgain)
        assertEquals(1, resources.releaseCount)

        clock.nowMillis = 5_000
        val second = coordinator.start()
        assertNotEquals(first.leaseId, second.leaseId)
        assertEquals(2, resources.acquireCount)
    }

    @Test
    fun `a new host start replaces an unexpired lease instead of inheriting it`() {
        val clock = FakeLeaseClock(5_000)
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(clock, resources, listOf("old-host", "new-host"))
        val oldLease = coordinator.start()

        clock.nowMillis = 6_000
        val newLease = coordinator.start()

        assertEquals("old-host", oldLease.leaseId)
        assertEquals("new-host", newLease.leaseId)
        assertEquals(2, resources.acquireCount)
        assertEquals(1, resources.releaseCount)
    }

    @Test
    fun `reboot or process crash cannot restore an old lease`() {
        val clock = FakeLeaseClock(6_000)
        val oldResources = FakeKeepAliveResources()
        val oldProcess = coordinator(clock, oldResources, listOf("old-lease"))
        oldProcess.start()

        val afterCrash = coordinator(clock, FakeKeepAliveResources(), listOf("new-lease"))
        val recoveredStatus = afterCrash.status()

        assertEquals(KeepAliveLeasePhase.INACTIVE, recoveredStatus.phase)
        assertNull(recoveredStatus.leaseId)
        assertFalse(recoveredStatus.notificationVisible)
        assertFalse(recoveredStatus.wifiLockHeld)
    }

    @Test
    fun `orderly process shutdown releases an active lease`() {
        val resources = FakeKeepAliveResources()
        val coordinator = coordinator(FakeLeaseClock(7_000), resources, listOf("lease-f"))
        coordinator.start()

        val status = coordinator.shutdown()

        assertEquals(KeepAliveLeasePhase.STOPPED, status.phase)
        assertEquals(1, resources.releaseCount)
    }

    private fun coordinator(
        clock: FakeLeaseClock,
        resources: FakeKeepAliveResources,
        ids: List<String>
    ): KeepAliveLeaseCoordinator {
        val remaining = ArrayDeque(ids)
        return KeepAliveLeaseCoordinator(
            clock = clock,
            idGenerator = KeepAliveLeaseIdGenerator { remaining.removeFirst() },
            resources = resources
        )
    }
}

private class FakeLeaseClock(var nowMillis: Long) : KeepAliveLeaseClock {
    override fun nowMillis(): Long = nowMillis
}

private class FakeKeepAliveResources : KeepAliveResources {
    var acquireCount = 0
    var releaseCount = 0

    override fun acquire(): KeepAliveResourceState {
        acquireCount += 1
        return KeepAliveResourceState(notificationVisible = true, wifiLockHeld = true)
    }

    override fun release() {
        releaseCount += 1
    }
}
