package dev.androidsync

internal fun platformMessageSyncModule(engine: SyncEngine): MessageSyncModule = object : MessageSyncModule {
    override val permissionsGranted = false
    override fun refreshPermissionState() = Unit
    override fun snapshot(connection: MacConnection) = connection.enqueue(engine.decorate(Wire("sms.snapshot.error",obj("reason" to "Carrier SMS is available only in the private localFull build."),capability = "sms")))
    override fun contacts(connection: MacConnection) = connection.enqueue(engine.decorate(Wire("contacts.snapshot.error",obj("reason" to "Contacts are available only in the private localFull build."),capability = "sms")))
    override fun send(connection: MacConnection, command: Wire) = connection.enqueue(engine.decorate(Wire("sms.send.result",obj("state" to "failed","reason" to "Carrier SMS sending is unavailable in this build."),replyTo = command.id,capability = "sms")))
    override fun callHistory(connection: MacConnection, command: Wire) = connection.enqueue(engine.decorate(Wire("calls.page.error",obj("reason" to "Call history is available only in the private localFull build."),replyTo = command.id,capability = "calls")))
    override fun dial(connection: MacConnection, command: Wire) = connection.enqueue(engine.decorate(Wire("calls.dial.result",obj("state" to "failed","reason" to "Dialing is available only in the private localFull build."),replyTo = command.id,capability = "calls")))
    override fun close() = Unit
}
