package dev.androidsync

import android.content.ClipData
import android.content.ClipDescription
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

const val MAX_CLIPBOARD_IMAGE_BYTES = 25L * 1024L * 1024L

data class ClipboardClip(
    val id: String = UUID.randomUUID().toString(),
    val kind: String,
    val text: String = "",
    val imagePath: String? = null,
    val mime: String? = null,
    val size: Long = 0,
    val width: Int = 0,
    val height: Int = 0,
    val originDevice: String,
    val sourceApp: String? = null,
    val sourcePackage: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    val syncedMacs: Set<String> = emptySet(),
    val originDeviceId: String = "",
    val logicalClock: Long = 0,
    val contentHash: String = "",
    val pinned: Boolean = false,
    val archiveName: String? = null
) {
    val isImage get() = kind == "image"
    val isLink get() = kind == "link"
    val quotaBytes get() = if (isImage) size else text.toByteArray().size.toLong()
    fun json() = obj(
        "id" to id,"kind" to kind,"text" to text,"mime" to mime,"size" to size,
        "width" to width,"height" to height,"originDevice" to originDevice,
        "sourceApp" to sourceApp,"sourcePackage" to sourcePackage,"createdAt" to createdAt,
        "syncedMacs" to array(syncedMacs),"originDeviceId" to originDeviceId,
        "logicalClock" to logicalClock,"contentHash" to contentHash,"pinned" to pinned,
        "archiveName" to archiveName
    )
    companion object {
        fun parse(value: JSONObject): ClipboardClip {
            val synced = value.optJSONArray("syncedMacs") ?: JSONArray()
            return ClipboardClip(
                id = value.getString("id"),
                kind = value.getString("kind"),
                text = value.optString("text"),
                mime = value.optString("mime").takeIf { it.isNotBlank() },
                size = value.optLong("size"),
                width = value.optInt("width"),
                height = value.optInt("height"),
                originDevice = value.optString("originDevice","Android"),
                sourceApp = value.optString("sourceApp").takeIf { it.isNotBlank() },
                sourcePackage = value.optString("sourcePackage").takeIf { it.isNotBlank() },
                createdAt = value.optLong("createdAt",System.currentTimeMillis()),
                syncedMacs = (0 until synced.length()).map { synced.getString(it) }.toSet(),
                originDeviceId = value.optString("originDeviceId"),
                logicalClock = value.optLong("logicalClock"),
                contentHash = value.optString("contentHash"),
                pinned = value.optBoolean("pinned"),
                archiveName = value.optString("archiveName").takeIf { it.isNotBlank() }
            )
        }
    }
}

fun clipboardHash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()

object ClipboardQuota {
    fun retain(values: List<ClipboardClip>, quotaPerDevice: Long): Pair<List<ClipboardClip>,List<ClipboardClip>> {
        val usage = values.filter { it.pinned }.groupBy { it.originDeviceId.ifBlank { it.originDevice } }
            .mapValues { (_,clips) -> clips.sumOf { it.quotaBytes } }.toMutableMap()
        val retained = mutableListOf<ClipboardClip>()
        val evicted = mutableListOf<ClipboardClip>()
        for (clip in values.sortedWith(compareByDescending<ClipboardClip> { it.logicalClock }.thenByDescending { it.createdAt })) {
            val device = clip.originDeviceId.ifBlank { clip.originDevice }
            if (clip.pinned) { retained += clip; continue }
            val used = usage[device] ?: 0
            if (used + clip.quotaBytes <= quotaPerDevice) {
                retained += clip
                usage[device] = used + clip.quotaBytes
            } else evicted += clip
        }
        return retained to evicted
    }
}

/** Encrypted persistent clipboard metadata and image archives. Decrypted files are disposable working copies. */
class ClipboardHistoryStore(private val engine: SyncEngine) {
    private val root = File(engine.context.filesDir,"clipboard-history").apply { mkdirs() }
    private val images = File(root,"images").apply { mkdirs() }
    private val working = File(engine.context.cacheDir,"clipboard-history").apply {
        deleteRecursively(); mkdirs()
    }
    private val metadata = File(root,"history.enc")
    private val aad = "clipboard-history-v1"

    @Synchronized fun load(): List<ClipboardClip> {
        if (!metadata.isFile) return emptyList()
        val decoded = JSONArray(String(engine.store.open(aad,metadata.readBytes()),Charsets.UTF_8))
        return (0 until decoded.length()).mapNotNull { index ->
            runCatching { ClipboardClip.parse(decoded.getJSONObject(index)) }.getOrNull()
        }.sortedWith(compareByDescending<ClipboardClip> { it.logicalClock }.thenByDescending { it.createdAt })
    }

    @Synchronized fun save(values: List<ClipboardClip>): List<ClipboardClip> {
        val persisted = values.map { clip ->
            if (!clip.isImage) clip
            else {
                val archive = clip.archiveName ?: (clip.id + ".clip")
                val destination = File(images,archive)
                if (!destination.isFile) {
                    val source = clip.imagePath?.let(::File)?.takeIf { it.isFile } ?: error("Clipboard image working copy is missing")
                    engine.store.encryptFile("clipboard-image:" + clip.id,source,destination)
                }
                clip.copy(archiveName = archive)
            }
        }
        val clear = array(persisted.map { it.json() }).toString().toByteArray(Charsets.UTF_8)
        val sealed = engine.store.seal(aad,clear)
        val temporary = File(root,".history." + UUID.randomUUID() + ".tmp")
        try {
            temporary.writeBytes(sealed)
            check(temporary.renameTo(metadata) || run { temporary.copyTo(metadata,overwrite = true); temporary.delete(); true })
        } finally { if (temporary.exists()) temporary.delete() }
        return persisted
    }

    @Synchronized fun deleteArchive(clip: ClipboardClip) {
        clip.archiveName?.let { File(images,it).delete() }
    }

    @Synchronized fun materialize(clip: ClipboardClip): ClipboardClip {
        if (!clip.isImage || clip.imagePath?.let(::File)?.isFile == true) return clip
        val archive = clip.archiveName ?: return clip
        val encrypted = File(images,archive)
        if (!encrypted.isFile) return clip
        val output = File(working,clip.id + "." + extensionFor(clip.mime))
        engine.store.decryptFile("clipboard-image:" + clip.id,encrypted,output)
        return clip.copy(imagePath = output.path)
    }

    private fun extensionFor(mime: String?) = when (mime?.lowercase()) {
        "image/jpeg", "image/jpg" -> "jpg"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "image/heic", "image/heif" -> "heic"
        else -> "png"
    }
}

data class ClipboardSource(val app: String?, val packageName: String?)

/** Moves clipboard images on authenticated file streams so notifications are never blocked by image bytes. */
class ClipboardImageSync(private val engine: SyncEngine) {
    private val directory = File(engine.context.cacheDir, "clipboard").apply {
        mkdirs()
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        listFiles()?.filter { it.lastModified() < cutoff }?.forEach(File::delete)
    }

    fun capture(uri: Uri, mime: String?, source: ClipboardSource?) {
        engine.scope.launch {
            try {
                val imageMime = mime?.takeIf { it.startsWith("image/") } ?: "image/png"
                val file = File(directory, "${UUID.randomUUID()}.${extensionFor(imageMime)}")
                var total = 0L
                engine.context.contentResolver.openInputStream(uri)?.use { input ->
                    file.outputStream().use { output ->
                        val buffer = ByteArray(CHUNK_SIZE)
                        while (true) {
                            ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= MAX_CLIPBOARD_IMAGE_BYTES) { "Clipboard images are limited to 25 MB." }
                            output.write(buffer, 0, count)
                        }
                    }
                } ?: error("The source app no longer allows access to this image.")
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.path, options)
                require(options.outWidth > 0 && options.outHeight > 0) { "The clipboard item is not a readable image." }
                val clip = ClipboardClip(
                    kind = "image",
                    imagePath = file.path,
                    mime = imageMime,
                    size = file.length(),
                    width = options.outWidth,
                    height = options.outHeight,
                    originDevice = android.os.Build.MODEL,
                    sourceApp = source?.app,
                    sourcePackage = source?.packageName,
                    originDeviceId = engine.store.phoneId,
                    contentHash = file.inputStream().use(::sha256)
                )
                engine.coordinateImage(clip)
            } catch (e: Exception) {
                engine.fail(e.message ?: "Could not read the clipboard image.")
            }
        }
    }

    fun push(clip: ClipboardClip, revision: Long, session: String, macIds: Set<String>) {
        val path = clip.imagePath ?: return
        macIds.forEach { macId ->
            engine.scope.launch {
                val peer = engine.peerForLane(macId) ?: return@launch
                try {
                    val source = File(path)
                    require(source.isFile && source.length() == clip.size)
                    MacConnection.openBulk(peer, engine.store).use { connection ->
                        connection.io.send(Wire("clipboard.put", metadata(clip, revision, session)))
                        val ready = connection.io.read()
                        require(ready.type == "clipboard.ready" && ready.body.getLong("offset") == 0L)
                        RandomAccessFile(source, "r").use { input ->
                            val buffer = ByteArray(CHUNK_SIZE)
                            var offset = 0L
                            while (offset < clip.size) {
                                ensureActive()
                                val count = input.read(buffer, 0, minOf(buffer.size.toLong(), clip.size - offset).toInt())
                                require(count > 0)
                                connection.io.send(Wire("clipboard.chunk", obj("offset" to offset, "data" to android.util.Base64.encodeToString(buffer.copyOf(count), android.util.Base64.NO_WRAP))))
                                val progress = connection.io.read()
                                require(progress.type == "clipboard.progress" && progress.body.getLong("offset") == offset + count)
                                offset += count
                            }
                        }
                        connection.io.send(Wire("clipboard.end", obj("clipId" to clip.id)))
                        require(connection.io.read().type == "clipboard.saved")
                    }
                    engine.markClipboardSynced(clip.id, macId)
                } catch (_: Exception) {
                    // Clipboard updates are intentionally not replayed. The UI simply leaves this Mac unsynced.
                }
            }
        }
    }

    fun receiveProposal(peerId: String, body: JSONObject) {
        engine.scope.launch {
            val peer = engine.peerForLane(peerId) ?: return@launch
            val sourceId = body.getString("clipId")
            val size = body.getLong("size")
            val expectedHash = body.getString("sha256")
            val mime = body.optString("mime", "image/png")
            if (size !in 1..MAX_CLIPBOARD_IMAGE_BYTES || !expectedHash.matches(Regex("[0-9a-fA-F]{64}")) || !mime.startsWith("image/")) return@launch
            val partial = File(directory, "${UUID.randomUUID()}.${extensionFor(mime)}")
            try {
                MacConnection.openBulk(peer, engine.store).use { connection ->
                    connection.io.send(Wire("clipboard.get", obj("clipId" to sourceId, "offset" to 0)))
                    val ready = connection.io.read()
                    require(ready.type == "clipboard.ready" && ready.body.getLong("offset") == 0L)
                    var offset = 0L
                    partial.outputStream().use { output ->
                        while (true) {
                            ensureActive()
                            connection.io.send(Wire("clipboard.next", obj("offset" to offset)))
                            val message = connection.io.read()
                            if (message.type == "clipboard.end") break
                            require(message.type == "clipboard.chunk" && message.body.getLong("offset") == offset)
                            val bytes = android.util.Base64.decode(message.body.getString("data"), android.util.Base64.NO_WRAP)
                            require(bytes.isNotEmpty() && bytes.size <= CHUNK_SIZE && offset + bytes.size <= size)
                            output.write(bytes)
                            offset += bytes.size
                        }
                    }
                    require(offset == size && partial.inputStream().use { sha256(it) }.equals(expectedHash, true))
                    connection.io.send(Wire("clipboard.saved", obj("clipId" to sourceId)))
                }
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(partial.path, options)
                require(options.outWidth > 0 && options.outHeight > 0)
                val clip = ClipboardClip(
                    id = sourceId,
                    kind = "image",
                    imagePath = partial.path,
                    mime = mime,
                    size = size,
                    width = options.outWidth,
                    height = options.outHeight,
                    originDevice = body.optString("origin", peer.name),
                    sourceApp = body.optString("sourceApp").takeIf { it.isNotBlank() },
                    sourcePackage = body.optString("sourcePackage").takeIf { it.isNotBlank() },
                    createdAt = minOf(body.optLong("createdAt",System.currentTimeMillis()),System.currentTimeMillis() + 60_000),
                    originDeviceId = body.optString("originDeviceId",peer.id),
                    contentHash = expectedHash.lowercase()
                )
                engine.coordinateImage(clip, copyToPhone = true)
            } catch (_: Exception) {
                partial.delete()
            }
        }
    }

    fun copyToPhone(clip: ClipboardClip) {
        val file = clip.imagePath?.let(::File) ?: return
        if (!file.isFile) return
        val uri = FileProvider.getUriForFile(engine.context, "${engine.context.packageName}.files", file)
        engine.markOwnClipboard("image:$uri")
        engine.clipboard.setPrimaryClip(ClipData.newUri(engine.context.contentResolver, "Android Sync image", uri))
    }

    fun delete(clip: ClipboardClip) {
        val file = clip.imagePath?.let(::File)?.takeIf(File::exists) ?: return
        val activeUri = if (engine.foreground) runCatching {
            engine.clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
        }.getOrNull() else null
        val fileUri = runCatching { FileProvider.getUriForFile(engine.context, "${engine.context.packageName}.files", file) }.getOrNull()
        if (activeUri != fileUri) file.delete()
    }

    private fun metadata(clip: ClipboardClip, revision: Long, session: String) = obj(
        "clipId" to clip.id,
        "size" to clip.size,
        "sha256" to File(clip.imagePath!!).inputStream().use { sha256(it) },
        "mime" to (clip.mime ?: "image/png"),
        "width" to clip.width,
        "height" to clip.height,
        "origin" to clip.originDevice,
        "sourceApp" to clip.sourceApp,
        "sourcePackage" to clip.sourcePackage,
        "originDeviceId" to clip.originDeviceId,
        "createdAt" to clip.createdAt,
        "contentHash" to clip.contentHash,
        "acceptedClock" to clip.logicalClock,
        "revision" to revision,
        "session" to session
    )

    private fun extensionFor(mime: String) = when (mime.lowercase()) {
        "image/jpeg", "image/jpg" -> "jpg"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "image/heic", "image/heif" -> "heic"
        else -> "png"
    }
}
