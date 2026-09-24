package dev.androidsync

internal fun platformRemoteControlModule(engine: SyncEngine): RemoteControlModule = object : RemoteControlModule {
    override val enabled = false
    override fun refresh() = Unit
    override fun execute(command: Wire) = false to "Remote control is available only in the private localFull build."
}
