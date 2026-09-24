package dev.androidsync

import android.Manifest
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.provider.CallLog
import android.telecom.TelecomManager
import android.telephony.PhoneNumberUtils
import android.telephony.SmsManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal fun platformMessageSyncModule(engine: SyncEngine): MessageSyncModule = LocalMessageSyncModule(engine)

private class LocalMessageSyncModule(private val engine: SyncEngine) : MessageSyncModule {
    private val handler = Handler(Looper.getMainLooper())
    private var registered = false
    private var refreshJob: Job? = null
    private val observer = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            refreshJob?.cancel()
            refreshJob = engine.scope.launch {
                delay(750)
                engine.state.value.messageDevices.forEach { id -> engine.connections[id]?.let(::snapshot) }
            }
        }
    }
    override val permissionsGranted: Boolean
        get() = has(Manifest.permission.READ_SMS) && has(Manifest.permission.SEND_SMS) && has(Manifest.permission.READ_CONTACTS)

    override fun refreshPermissionState() {
        val shouldObserve = has(Manifest.permission.READ_SMS)
        if (shouldObserve && !registered) {
            engine.context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI,true,observer)
            registered = true
        } else if (!shouldObserve && registered) {
            engine.context.contentResolver.unregisterContentObserver(observer); registered = false
        }
    }

    override fun snapshot(connection: MacConnection) {
        engine.scope.launch {
            if (!has(Manifest.permission.READ_SMS)) { emit(connection,Wire("sms.snapshot.error",obj("reason" to "Allow SMS access on Android first."),capability = "sms")); return@launch }
            runCatching {
                val contacts = contactRows()
                val messages = mutableListOf<SmsMessageRecord>()
                val threads = linkedMapOf<String,SmsThreadRecord>()
                val projection = arrayOf(Telephony.Sms._ID,Telephony.Sms.THREAD_ID,Telephony.Sms.ADDRESS,Telephony.Sms.BODY,Telephony.Sms.DATE,Telephony.Sms.TYPE,Telephony.Sms.READ)
                engine.context.contentResolver.query(Telephony.Sms.CONTENT_URI,projection,null,null,"${Telephony.Sms.DATE} DESC")?.use { cursor ->
                    val idIndex = cursor.getColumnIndexOrThrow(Telephony.Sms._ID); val threadIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
                    val addressIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS); val bodyIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
                    val dateIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE); val typeIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.TYPE); val readIndex = cursor.getColumnIndexOrThrow(Telephony.Sms.READ)
                    var count = 0
                    while (cursor.moveToNext() && count++ < 2_000) {
                        val address = cursor.getString(addressIndex).orEmpty().take(200)
                        val body = cursor.getString(bodyIndex).orEmpty().take(16_000)
                        val threadId = cursor.getLong(threadIndex).toString(); val timestamp = cursor.getLong(dateIndex).coerceAtLeast(0)
                        val type = cursor.getInt(typeIndex); val outgoing = type in setOf(Telephony.Sms.MESSAGE_TYPE_SENT,Telephony.Sms.MESSAGE_TYPE_OUTBOX,Telephony.Sms.MESSAGE_TYPE_QUEUED)
                        val read = cursor.getInt(readIndex) != 0
                        messages += SmsMessageRecord(cursor.getLong(idIndex).toString(),threadId,address,body,timestamp,outgoing,read)
                        val existing = threads[threadId]
                        val unread = (existing?.unreadCount ?: 0) + if (!outgoing && !read) 1 else 0
                        threads[threadId] = existing?.copy(unreadCount = unread) ?: SmsThreadRecord(threadId,address,contactName(address,contacts),body.take(240),timestamp,unread)
                    }
                } ?: error("Android SMS provider is unavailable.")
                emitSnapshot(connection,buildList {
                    add(Wire("sms.snapshot.begin",obj("count" to messages.size),capability = "sms"))
                    threads.values.forEach { add(Wire("sms.thread",it.json(),capability = "sms")) }
                    messages.asReversed().forEach { add(Wire("sms.message",it.json(),capability = "sms")) }
                    add(Wire("sms.snapshot.end",obj("threads" to threads.size,"messages" to messages.size),capability = "sms"))
                })
            }.onFailure { runCatching { emitSnapshot(connection,listOf(Wire("sms.snapshot.error",obj("reason" to (it.message ?: "Could not read carrier SMS.")),capability = "sms"))) } }
        }
    }

    override fun contacts(connection: MacConnection) {
        engine.scope.launch {
            if (!has(Manifest.permission.READ_CONTACTS)) { emit(connection,Wire("contacts.snapshot.error",obj("reason" to "Allow Contacts access on Android first."),capability = "sms")); return@launch }
            runCatching {
                val contacts = contactRows().take(2_000)
                emitSnapshot(connection,buildList {
                    add(Wire("contacts.snapshot.begin",obj("count" to contacts.size),capability = "sms"))
                    contacts.forEach { add(Wire("contact",it.json(),capability = "sms")) }
                    add(Wire("contacts.snapshot.end",obj("count" to contacts.size),capability = "sms"))
                })
            }.onFailure { runCatching { emitSnapshot(connection,listOf(Wire("contacts.snapshot.error",obj("reason" to (it.message ?: "Could not read contacts.")),capability = "sms"))) } }
        }
    }

    override fun send(connection: MacConnection, command: Wire) {
        engine.scope.launch {
            val result = runCatching {
                check(has(Manifest.permission.SEND_SMS)) { "Allow SMS sending on Android first." }
                val address = command.body.getString("address").trim()
                val body = command.body.getString("body").trim()
                val normalized = PhoneNumberUtils.normalizeNumber(address)
                require(normalized.length in 3..20 && body.isNotEmpty() && body.length <= 10_000) { "Enter a valid phone number and a message of at most 10,000 characters." }
                val manager = engine.context.getSystemService(SmsManager::class.java)
                val parts = manager.divideMessage(body)
                if (parts.size == 1) manager.sendTextMessage(address,null,body,null,null)
                else manager.sendMultipartTextMessage(address,null,parts,null,null)
                Wire("sms.send.result",obj("state" to "accepted","reason" to "Android accepted the carrier SMS request."),replyTo = command.id,capability = "sms")
            }.getOrElse { Wire("sms.send.result",obj("state" to "failed","reason" to (it.message ?: "Android rejected the SMS request.")),replyTo = command.id,capability = "sms") }
            emit(connection,result)
            if (result.body.optString("state") == "accepted") { delay(1_000); snapshot(connection) }
        }
    }

    override fun callHistory(connection: MacConnection, command: Wire) {
        engine.scope.launch {
            val offset = command.body.optInt("offset",-1)
            if (offset < 0 || offset > 100_000) { emit(connection,Wire("calls.page.error",obj("reason" to "Invalid call history page."),replyTo = command.id,capability = "calls")); return@launch }
            if (!has(Manifest.permission.READ_CALL_LOG)) { emit(connection,Wire("calls.page.error",obj("reason" to "Allow Call history in Android Sync Setup."),replyTo = command.id,capability = "calls")); return@launch }
            runCatching {
                val rows = mutableListOf<org.json.JSONObject>()
                val projection = arrayOf(CallLog.Calls._ID,CallLog.Calls.NUMBER,CallLog.Calls.CACHED_NAME,CallLog.Calls.DATE,CallLog.Calls.DURATION,CallLog.Calls.TYPE)
                var more = false
                engine.context.contentResolver.query(CallLog.Calls.CONTENT_URI,projection,null,null,"${CallLog.Calls.DATE} DESC, ${CallLog.Calls._ID} DESC")?.use { cursor ->
                    if (cursor.moveToPosition(offset)) do {
                        if (rows.size == 100) { more = true; break }
                        rows += obj(
                            "id" to cursor.getString(0),
                            "number" to cursor.getString(1).orEmpty().take(100),
                            "name" to cursor.getString(2)?.take(300),
                            "timestamp" to cursor.getLong(3).coerceAtLeast(0),
                            "duration" to cursor.getLong(4).coerceAtLeast(0),
                            "type" to cursor.getInt(5)
                        )
                    } while (cursor.moveToNext())
                } ?: error("Android call history is unavailable.")
                emit(connection,Wire("calls.page.result",obj("offset" to offset,"nextOffset" to (offset + rows.size),"hasMore" to more,"rows" to array(rows)),replyTo = command.id,capability = "calls"))
            }.onFailure { emit(connection,Wire("calls.page.error",obj("reason" to (it.message ?: "Could not read call history.")),replyTo = command.id,capability = "calls")) }
        }
    }

    override fun dial(connection: MacConnection, command: Wire) {
        engine.scope.launch {
            val result = runCatching {
                check(engine.context.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) { "Allow Place calls in Android Sync Setup." }
                val number = command.body.getString("number").trim()
                require(number.length in 3..40 && number.all { it.isDigit() || it in "+*#() -." } && PhoneNumberUtils.normalizeNumber(number).isNotBlank()) { "Enter a valid phone number." }
                engine.context.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel",number,null),null)
                Wire("calls.dial.result",obj("state" to "uncertain","reason" to "Dial request sent to Android. Check the phone for call status."),replyTo = command.id,capability = "calls")
            }.getOrElse { Wire("calls.dial.result",obj("state" to "failed","reason" to (it.message ?: "Android rejected the call request.")),replyTo = command.id,capability = "calls") }
            emit(connection,result)
        }
    }

    override fun close() { if (registered) runCatching { engine.context.contentResolver.unregisterContentObserver(observer) }; registered = false; refreshJob?.cancel() }

    private fun contactRows(): List<ContactRecord> {
        if (!has(Manifest.permission.READ_CONTACTS)) return emptyList()
        val grouped = linkedMapOf<String,Pair<String,MutableList<String>>>()
        val projection = arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID,ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,ContactsContract.CommonDataKinds.Phone.NUMBER)
        engine.context.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,projection,null,null,ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE NOCASE")?.use { cursor ->
            val id = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.CONTACT_ID); val name = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME); val number = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (cursor.moveToNext() && grouped.size < 2_000) {
                val key = cursor.getLong(id).toString(); val phone = cursor.getString(number).orEmpty().take(100)
                val row = grouped.getOrPut(key) { cursor.getString(name).orEmpty().take(300) to mutableListOf() }
                if (phone.isNotBlank() && phone !in row.second) row.second += phone
            }
        }
        return grouped.map { (id,row) -> ContactRecord(id,row.first,row.second.take(20)) }
    }
    private fun contactName(address: String, contacts: List<ContactRecord>): String? = contacts.firstOrNull { contact -> contact.phones.any { PhoneNumberUtils.compare(it,address) } }?.name
    private fun has(permission: String) = engine.context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    private fun emit(connection: MacConnection, wire: Wire) = connection.enqueue(engine.decorate(wire))
    private suspend fun emitSnapshot(connection: MacConnection, wires: List<Wire>) {
        wires.chunked(SNAPSHOT_BATCH_SIZE).forEach { batch ->
            connection.enqueueBatchAwait(batch.map(engine::decorate))
        }
    }

    private companion object { const val SNAPSHOT_BATCH_SIZE = 64 }
}
