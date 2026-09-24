package dev.androidsync

import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import kotlinx.coroutines.*
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class TransferManager(private val engine: SyncEngine) {
    private val directory = File(engine.context.filesDir,"transfers").apply { mkdirs() }
    private val jobs = ConcurrentHashMap<String,Job>()
    private val streams = ConcurrentHashMap<String,MacConnection>()
    private data class Meter(var bytes: Long, var time: Long)
    private val meters = ConcurrentHashMap<String,Meter>()
    private fun partial(id: String, fileId: String) = File(directory,"$id-$fileId.part")
    fun cleanupTerminal() {
        engine.state.value.transfers.filter { it.status in listOf("Completed","Cancelled","Declined") }.forEach { transfer ->
            transfer.offer.files.forEach { file ->
                // Only remove our generated staging files, never selected originals or Downloads.
                File(directory,"${file.id}.source").delete()
                partial(transfer.offer.id,file.id).delete()
            }
        }
    }
    fun prepare(uris: List<Uri>, macId: String) {
        if (!engine.state.value.fileTransferEnabled) { engine.fail("Enable file transfer in Settings first."); return }
        if (uris.isEmpty() || uris.size > 100) { engine.fail("Choose between 1 and 100 files."); return }
        if (!engine.connections.containsKey(macId)) { engine.fail("Connect the receiving Mac first."); return }
        engine.setPreparing(true)
        engine.scope.launch {
            try {
                prepareUris(uris,macId)
            } catch (e: Exception) { engine.fail("Could not prepare files: ${e.message}") }
            finally { engine.setPreparing(false) }
        }
    }
    suspend fun prepareUris(uris: List<Uri>, macId: String, announce: Boolean = true): FileOffer {
        require(engine.state.value.fileTransferEnabled) { "Enable file transfer in Settings first." }
        require(engine.connections.containsKey(macId)) { "Reconnect the receiving Mac first." }
        require(uris.isNotEmpty() && uris.size <= 100) { "Choose between 1 and 100 files." }
        val staged = mutableListOf<File>()
        try {
            val resolver = engine.context.contentResolver
            val sources = mutableMapOf<String,String>()
            val files = uris.map { uri ->
                val name = resolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Shared file"
                val safeName = name.replace('/','_').replace('\\','_').replace('\u0000','_').take(240).ifEmpty { "Shared file" }
                val id = UUID.randomUUID().toString(); val source = File(directory,"$id.source"); staged.add(source)
                resolver.openInputStream(uri)?.use { input -> source.outputStream().use { output -> input.copyTo(output) } } ?: error("Cannot read $safeName")
                sources[id] = source.path
                SharedFile(id,safeName,source.length(),source.inputStream().use { sha256(it) },resolver.getType(uri) ?: "application/octet-stream").also { it.validate() }
            }
            val offer = FileOffer(UUID.randomUUID().toString(),files).also { it.validate() }
            engine.addTransfer(TransferState(offer,macId,false,"Awaiting Mac acceptance",sources = sources))
            if (announce) engine.send(macId,Wire("file.offer",offer.json(),capability = "files"))
            return offer
        } catch (error: Exception) {
            staged.forEach { it.delete() }
            throw error
        }
    }
    suspend fun prepareFiles(sourceFiles: List<File>, macId: String, announce: Boolean = true, relativePaths: Map<String,String> = emptyMap()): FileOffer {
        require(engine.state.value.fileTransferEnabled) { "Enable file transfer in Settings first." }
        require(engine.connections.containsKey(macId)) { "Reconnect the receiving Mac first." }
        require(sourceFiles.isNotEmpty() && sourceFiles.size <= 100)
        val sources = mutableMapOf<String,String>()
        val files = sourceFiles.map { source ->
            require(source.isFile && source.canRead()) { "${source.name} is unavailable." }
            val id = UUID.randomUUID().toString()
            sources[id] = source.path
            SharedFile(id,source.name.take(240),source.length(),source.inputStream().use(::sha256),"application/octet-stream",relativePaths[source.canonicalPath]).also { it.validate() }
        }
        val offer = FileOffer(UUID.randomUUID().toString(),files).also { it.validate() }
        engine.addTransfer(TransferState(offer,macId,false,"Awaiting Mac acceptance",sources = sources))
        if (announce) engine.send(macId,Wire("file.offer",offer.json(),capability = "files"))
        return offer
    }
    fun receiveOffer(connection: MacConnection, offer: FileOffer) {
        if (!engine.state.value.fileTransferEnabled) { engine.send(connection.peer.id,Wire("file.decline",obj("transferId" to offer.id))); return }
        val existing = engine.transfer(offer.id)
        if (existing != null) {
            require(existing.macId == connection.peer.id && existing.incoming && existing.offer == offer)
            if (existing.accepted && existing.status != "Completed") acceptIncoming(offer.id)
            else if (existing.status in listOf("Declined","Cancelled")) engine.send(connection.peer.id,Wire("file.decline",obj("transferId" to offer.id)))
            else if (existing.status == "Completed") engine.send(connection.peer.id,Wire("file.complete",obj("transferId" to offer.id)))
            return
        }
        val autoAccept = !engine.state.value.askEveryTimeFiles.contains(connection.peer.id)
        engine.addTransfer(TransferState(offer,connection.peer.id,true,if (autoAccept) "Preparing to receive" else "Awaiting your acceptance"))
        if (autoAccept) acceptIncoming(offer.id)
        else ConnectionService.notice(engine.context,"Files from ${connection.peer.name}","Open Android Sync to accept or decline this batch.")
    }
    fun acceptIncoming(id: String) {
        val transfer = engine.transfer(id) ?: return
        if (!transfer.incoming || transfer.status in listOf("Declined","Cancelled","Completed")) return
        val control = engine.connections[transfer.macId] ?: run { engine.fail("Reconnect the Mac before accepting."); return }
        val remaining = transfer.total - transfer.completed.sumOf { completed -> transfer.offer.files.firstOrNull { it.id == completed }?.size ?: 0 }
        val available = StatFs(Environment.getExternalStorageDirectory().path).availableBytes
        if (remaining > available - 16L * 1024 * 1024) {
            engine.updateTransfer(id) { it.copy(status = "Failed — not enough free space",accepted = false) }
            engine.fail("Not enough shared-storage space for this batch.")
            engine.send(transfer.macId,Wire("file.decline",obj("transferId" to id,"reason" to "insufficient_storage")))
            return
        }
        val now = System.currentTimeMillis()
        meters[id] = Meter(transfer.bytes,SystemClock.elapsedRealtime())
        engine.updateTransfer(id) { it.copy(accepted = true,status = "Receiving",startedAt = if (it.startedAt > 0) it.startedAt else now) }
        launchTransfer(id) {
            control.io.send(Wire("file.accept",obj("transferId" to id)))
            download(id,control.peer)
        }
    }
    fun acceptedByMac(connection: MacConnection, id: String) {
        val transfer = engine.transfer(id) ?: return
        require(transfer.macId == connection.peer.id && !transfer.incoming)
        if (transfer.status in listOf("Cancelled","Declined","Completed")) return
        val now = System.currentTimeMillis()
        meters[id] = Meter(transfer.bytes,SystemClock.elapsedRealtime())
        engine.updateTransfer(id) { it.copy(accepted = true,status = "Sending",startedAt = if (it.startedAt > 0) it.startedAt else now) }
        launchTransfer(id) { upload(id,connection.peer) }
    }
    @Synchronized private fun launchTransfer(id: String, work: suspend () -> Unit) {
        if (jobs[id]?.isActive == true) return
        val job = engine.scope.launch(start = CoroutineStart.LAZY) {
            try { work() }
            catch (e: Exception) {
                val current = engine.transfer(id)
                if (current?.status !in listOf("Cancelled","Declined","Completed")) {
                    val interrupted = e is IOException
                    engine.updateTransfer(id) { it.copy(status = if (interrupted) "Interrupted — reconnect or resume" else "Failed — ${e.message ?: "transfer error"}",speedBytesPerSecond = 0) }
                    ConnectionService.notice(engine.context,if (interrupted) "File transfer interrupted" else "File transfer failed",if (interrupted) "Reconnect and resume the batch in Android Sync." else (e.message ?: "Open Android Sync to retry."))
                }
            } finally { streams.remove(id)?.close() }
        }
        jobs[id] = job; job.start()
    }
    private fun ensureAccepted(id: String): TransferState = engine.transfer(id)?.also { check(it.accepted && it.status !in listOf("Cancelled","Declined")) } ?: error("Transfer no longer exists")
    private suspend fun upload(id: String, peer: MacPeer) {
        val transfer = ensureAccepted(id)
        for (file in transfer.offer.files) {
            currentCoroutineContext().ensureActive(); ensureAccepted(id)
            val source = File(transfer.sources[file.id] ?: error("Source unavailable")); require(source.isFile)
            MacConnection.openBulk(peer,engine.store).use { connection ->
                streams[id] = connection
                connection.io.send(Wire("file.put",obj("transferId" to id,"fileId" to file.id)))
                val ready = connection.io.read()
                if (ready.type == "file.saved") { completeFile(id,file); return@use }
                require(ready.type == "file.ready")
                var offset = ready.body.getLong("offset"); require(offset in 0..file.size)
                RandomAccessFile(source,"r").use { handle ->
                    handle.seek(offset); val buffer = ByteArray(CHUNK_SIZE)
                    while (offset < file.size) {
                        currentCoroutineContext().ensureActive(); ensureAccepted(id)
                        val n = handle.read(buffer,0,minOf(buffer.size.toLong(),file.size-offset).toInt()); require(n > 0)
                        connection.io.send(Wire("file.chunk",obj("offset" to offset,"data" to Base64.encodeToString(buffer.copyOf(n),Base64.NO_WRAP))))
                        val progress = connection.io.read(); require(progress.type == "file.progress" && progress.body.getLong("offset") == offset+n)
                        offset += n; progress(id,file.id,offset)
                    }
                }
                connection.io.send(Wire("file.end",obj("fileId" to file.id)))
                val saved = connection.io.read(); require(saved.type == "file.saved")
                completeFile(id,file)
            }
            streams.remove(id)
        }
        meters.remove(id)
        engine.updateTransfer(id) { it.copy(status = "Completed",bytes = it.total,speedBytesPerSecond = 0) }
        ConnectionService.notice(engine.context,"Files sent","${transfer.offer.files.size} ${if (transfer.offer.files.size == 1) "file was" else "files were"} sent successfully.")
    }
    private suspend fun download(id: String, peer: MacPeer) {
        val transfer = ensureAccepted(id)
        for (file in transfer.offer.files) {
            currentCoroutineContext().ensureActive(); ensureAccepted(id)
            if (engine.transfer(id)?.completed?.contains(file.id) == true) continue
            val partial = partial(id,file.id)
            if (partial.length() > file.size) partial.delete()
            MacConnection.openBulk(peer,engine.store).use { connection ->
                streams[id] = connection; var offset = partial.length()
                connection.io.send(Wire("file.get",obj("transferId" to id,"fileId" to file.id,"offset" to offset)))
                val ready = connection.io.read(); require(ready.type == "file.ready" && ready.body.getLong("offset") == offset)
                RandomAccessFile(partial,"rw").use { handle ->
                    handle.seek(offset)
                    while (true) {
                        currentCoroutineContext().ensureActive(); ensureAccepted(id)
                        connection.io.send(Wire("file.next",obj("offset" to offset)))
                        val message = connection.io.read()
                        if (message.type == "file.end") break
                        require(message.type == "file.chunk" && message.body.getLong("offset") == offset)
                        val bytes = Base64.decode(message.body.getString("data"),Base64.NO_WRAP)
                        require(bytes.isNotEmpty() && bytes.size <= CHUNK_SIZE && offset+bytes.size <= file.size)
                        handle.write(bytes); offset += bytes.size; progress(id,file.id,offset)
                    }
                    handle.fd.sync()
                }
                require(offset == file.size)
                engine.updateTransfer(id) { it.copy(status = "Verifying") }
                if (partial.inputStream().use { sha256(it) } != file.sha256) { partial.delete(); error("Integrity check failed") }
                ensureAccepted(id)
                val uri = publishDownload(transfer,file,partial)
                completeFile(id,file,uri.toString()); partial.delete()
                connection.io.send(Wire("file.saved",obj("fileId" to file.id)))
            }
            streams.remove(id)
        }
        meters.remove(id)
        engine.updateTransfer(id) { it.copy(status = "Completed",bytes = it.total,speedBytesPerSecond = 0) }
        engine.send(peer.id,Wire("file.complete",obj("transferId" to id)))
        val destination = transfer.offer.targetPath?.let { if (it.isEmpty()) "Device storage" else "Device storage / $it" } ?: "Downloads / Android Sync"
        ConnectionService.notice(engine.context,"Files received","${transfer.offer.files.size} ${if (transfer.offer.files.size == 1) "file was" else "files were"} saved to $destination.")
    }
    private fun publishDownload(transfer: TransferState, file: SharedFile, partial: File): Uri {
        transfer.offer.targetPath?.let { target ->
            check(engine.sharedStorage.available) { "Allow All files access before uploading into an Android folder." }
            val folder = engine.sharedStorage.resolve(target)
            require(folder.isDirectory && folder.canWrite()) { "The selected Android folder is unavailable." }
            val destination = engine.sharedStorage.uniqueFile(folder,file.name)
            try {
                partial.inputStream().use { input -> destination.outputStream().use { input.copyTo(it) } }
                check(destination.inputStream().use(::sha256) == file.sha256) { "Published file integrity check failed." }
            } catch (error: Exception) { destination.delete(); throw error }
            return Uri.fromFile(destination)
        }
        val resolver = engine.context.contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME,file.name); put(MediaStore.Downloads.MIME_TYPE,file.mime)
            put(MediaStore.Downloads.RELATIVE_PATH,"Download/Android Sync/"); put(MediaStore.Downloads.IS_PENDING,1)
        }
        val uri = resolver.insert(collection,values) ?: error("Downloads unavailable")
        try {
            resolver.openOutputStream(uri,"w")?.use { out -> partial.inputStream().use { it.copyTo(out) } } ?: error("Cannot write download")
            check(resolver.openInputStream(uri)?.use(::sha256) == file.sha256) { "Published file integrity check failed." }
            values.clear(); values.put(MediaStore.Downloads.IS_PENDING,0); resolver.update(uri,values,null,null); return uri
        } catch (e: Exception) { resolver.delete(uri,null,null); throw e }
    }
    private fun completeFile(id: String, file: SharedFile, uri: String? = null) {
        engine.updateTransfer(id) { current ->
            val completed = current.completed + file.id
            current.copy(completed = completed,saved = if (uri != null) current.saved + (file.id to uri) else current.saved,bytes = current.offer.files.filter { it.id in completed }.sumOf { it.size },status = if (completed.size == current.offer.files.size) "Completed" else if (current.incoming) "Receiving" else "Sending")
        }
    }
    private fun progress(id: String, fileId: String, offset: Long) {
        engine.updateTransfer(id,false) { current ->
            val bytes = current.offer.files.filter { it.id in current.completed && it.id != fileId }.sumOf { it.size } + offset
            val now = SystemClock.elapsedRealtime(); val meter = meters.getOrPut(id) { Meter(bytes,now) }
            val elapsed = now - meter.time
            val speed = if (elapsed >= 250) ((bytes - meter.bytes).coerceAtLeast(0) * 1000 / elapsed).also { meter.bytes = bytes; meter.time = now } else current.speedBytesPerSecond
            current.copy(bytes = bytes,speedBytesPerSecond = speed)
        }
    }
    fun decline(id: String) { val t = engine.transfer(id) ?: return; engine.updateTransfer(id) { it.copy(status = "Declined",accepted = false) }; interrupt(id); engine.send(t.macId,Wire("file.decline",obj("transferId" to id))) }
    fun cancel(id: String) { val t = engine.transfer(id) ?: return; engine.updateTransfer(id) { it.copy(status = "Cancelled",accepted = false) }; interrupt(id); engine.send(t.macId,Wire("file.cancel",obj("transferId" to id))) }
    fun remoteCancel(macId: String, id: String, decline: Boolean) { val t = engine.transfer(id) ?: return; require(t.macId == macId); engine.updateTransfer(id) { it.copy(status = if (decline) "Declined" else "Cancelled",accepted = false) }; interrupt(id) }
    fun resume(id: String) { val t = engine.transfer(id) ?: return; if (t.incoming) acceptIncoming(id) else { engine.updateTransfer(id) { it.copy(status = "Awaiting Mac acceptance",accepted = false) }; engine.send(t.macId,Wire("file.offer",t.offer.json())) } }
    private fun interrupt(id: String) { streams.remove(id)?.close(); jobs.remove(id)?.cancel() }
    fun interruptMac(macId: String) { engine.state.value.transfers.filter { it.macId == macId && it.status !in listOf("Completed","Cancelled","Declined") }.forEach { interrupt(it.offer.id); if (it.accepted) engine.updateTransfer(it.offer.id) { t -> t.copy(status = "Interrupted — reconnect or resume") } } }
    fun interruptAll() { jobs.keys.toList().forEach { interrupt(it) } }
}
