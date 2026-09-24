package dev.androidsync

interface RemoteControlModule {
    val enabled: Boolean
    fun refresh()
    fun execute(command: Wire): Pair<Boolean,String>
}

/** Accessibility implementation is present only in the private localFull source set. */
fun createRemoteControlModule(engine: SyncEngine): RemoteControlModule = platformRemoteControlModule(engine)
