package dev.androidsync

/** A bounded H.264 queue must preserve references, rather than replace arbitrary P frames. */
internal class RealtimeVideoQueue<T> {
    data class Offer(val accepted: Boolean, val congested: Boolean = false, val requestKeyFrame: Boolean = false)
    private var pending: T? = null
    private var awaitingKeyFrame = true

    @Synchronized fun offer(frame: T, keyFrame: Boolean): Offer {
        if (keyFrame) {
            val replaced = pending != null
            pending = frame
            awaitingKeyFrame = false
            return Offer(accepted = true, congested = replaced)
        }
        if (awaitingKeyFrame) return Offer(accepted = false)
        if (pending != null) {
            // Keep the earlier reference frame. The dropped frame and all of
            // its dependents must be skipped until an independent keyframe.
            awaitingKeyFrame = true
            return Offer(accepted = false, congested = true, requestKeyFrame = true)
        }
        pending = frame
        return Offer(accepted = true)
    }

    @Synchronized fun poll(): T? = pending.also { pending = null }
    @Synchronized fun needsKeyFrame(): Boolean = awaitingKeyFrame
    @Synchronized fun clear() { pending = null; awaitingKeyFrame = true }
}
