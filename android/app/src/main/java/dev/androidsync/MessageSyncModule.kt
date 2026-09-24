package dev.androidsync

interface MessageSyncModule {
    val permissionsGranted: Boolean
    fun refreshPermissionState()
    fun snapshot(connection: MacConnection)
    fun contacts(connection: MacConnection)
    fun send(connection: MacConnection, command: Wire)
    fun callHistory(connection: MacConnection, command: Wire)
    fun dial(connection: MacConnection, command: Wire)
    fun close()
}

/** Implemented separately by localFull and standard so restricted provider code never enters the standard flavor. */
fun createMessageSyncModule(engine: SyncEngine): MessageSyncModule = platformMessageSyncModule(engine)
