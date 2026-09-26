package dev.androidsync

import org.junit.Assert.*
import org.junit.Test

class RealtimeVideoQueueTest {
    @Test fun congestionKeepsTheQueuedReferenceAndSkipsItsMissingDependents() {
        val queue = RealtimeVideoQueue<String>()
        assertTrue(queue.offer("I0",keyFrame = true).accepted)
        assertEquals("I0",queue.poll())
        assertTrue(queue.offer("P1",keyFrame = false).accepted)
        val dropped = queue.offer("P2",keyFrame = false)
        assertFalse(dropped.accepted)
        assertTrue(dropped.requestKeyFrame)
        assertEquals("P1",queue.poll())
        assertFalse(queue.offer("P3 depends on missing P2",keyFrame = false).accepted)
        assertNull(queue.poll())
        assertTrue(queue.offer("I4",keyFrame = true).accepted)
        assertEquals("I4",queue.poll())
        assertTrue(queue.offer("P5",keyFrame = false).accepted)
        assertEquals("P5",queue.poll())
    }

    @Test fun aPendingKeyFrameIsNeverReplacedByAPredictedFrame() {
        val queue = RealtimeVideoQueue<Int>()
        queue.offer(1,keyFrame = true)
        assertFalse(queue.offer(2,keyFrame = false).accepted)
        assertEquals(1,queue.poll())
        assertTrue(queue.needsKeyFrame())
        assertFalse(queue.offer(3,keyFrame = false).accepted)
        assertTrue(queue.offer(4,keyFrame = true).accepted)
        assertFalse(queue.needsKeyFrame())
    }

    @Test fun anIndependentKeyFrameCanReplaceStalePendingVideo() {
        val queue = RealtimeVideoQueue<Int>()
        queue.offer(1,keyFrame = true); queue.poll()
        queue.offer(2,keyFrame = false)
        val replacement = queue.offer(3,keyFrame = true)
        assertTrue(replacement.accepted)
        assertTrue(replacement.congested)
        assertFalse(replacement.requestKeyFrame)
        assertEquals(3,queue.poll())
        assertTrue(queue.offer(4,keyFrame = false).accepted)
    }

    @Test fun repeatedCongestionRemainsBoundedAndRecovers() {
        val queue = RealtimeVideoQueue<Int>()
        repeat(500) { cycle ->
            assertTrue(queue.offer(cycle * 3,keyFrame = true).accepted)
            assertFalse(queue.offer(cycle * 3 + 1,keyFrame = false).accepted)
            assertFalse(queue.offer(cycle * 3 + 2,keyFrame = false).accepted)
            assertEquals(cycle * 3,queue.poll())
            assertNull(queue.poll())
        }
        queue.clear()
        assertTrue(queue.needsKeyFrame())
        assertFalse(queue.offer(-1,keyFrame = false).accepted)
    }
}
