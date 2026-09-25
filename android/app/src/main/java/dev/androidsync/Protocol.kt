package dev.androidsync

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID

const val MAX_FRAME = 262_144
const val CHUNK_SIZE = 65_536
fun obj(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().apply { pairs.forEach { (k,v) -> put(k,v) } }
fun array(values: Iterable<Any>): JSONArray = JSONArray().apply { values.forEach { put(it) } }
fun String.isWebUrl(): Boolean = runCatching { val u = java.net.URI(this); u.scheme?.lowercase() in listOf("http", "https") && u.host != null }.getOrDefault(false)
fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 255) }
fun normalizeSharedStoragePath(value: String): String {
    val clean = value.trim().trim('/').replace('\\','/')
    require(clean.length <= 1024 && clean.split('/').none { it == ".." || it == "." || it.contains('\u0000') }) { "Invalid shared-storage path." }
    val lower = clean.lowercase()
    require(lower != "android/data" && !lower.startsWith("android/data/") && lower != "android/obb" && !lower.startsWith("android/obb/")) { "That Android folder is private or unavailable." }
    return clean
}
fun sha256(input: InputStream): String {
    val digest = MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(CHUNK_SIZE)
    while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer,0,n) }; return digest.digest().hex()
}
fun signaturePayload(macId: String, nonce: String, stream: String, phoneId: String): ByteArray = "android-sync/1|$macId|$nonce|$stream|$phoneId".toByteArray(StandardCharsets.UTF_8)

enum class CapabilityAvailability { SUPPORTED, PERMISSION_REQUIRED, ENABLED, TEMPORARILY_UNAVAILABLE, UNSUPPORTED }
data class WireCapability(val id: String, val state: CapabilityAvailability, val reason: String? = null) {
    fun json() = obj("id" to id, "state" to state.name.lowercase(), "reason" to reason)
}
data class WireCapabilitySet(val capabilities: List<WireCapability>) {
    fun json() = obj("capabilities" to array(capabilities.map { it.json() }))
}
class LogicalClock(initial: Long = 0) {
    private var value = initial.coerceAtLeast(0)
    @Synchronized fun tick(): Long { value += 1; return value }
    @Synchronized fun observe(remote: Long): Long { value = maxOf(value, remote.coerceAtLeast(0)) + 1; return value }
    @Synchronized fun current(): Long = value
}
fun shouldAdoptFileTransportSetting(revision: Long, origin: String, currentRevision: Long, currentOrigin: String): Boolean =
    revision > currentRevision || (revision == currentRevision && origin > currentOrigin)
data class Wire(
    val type: String,
    val body: JSONObject = JSONObject(),
    val id: String = UUID.randomUUID().toString(),
    val version: Int = 2,
    val originDeviceId: String? = null,
    val clock: Long? = null,
    val sentAt: Long? = if (version >= 2) System.currentTimeMillis() else null,
    val capability: String? = null,
    val replyTo: String? = null
) {
    fun bytes(protocolVersion: Int = version): ByteArray {
        require(protocolVersion in 1..2)
        val envelope = obj("v" to protocolVersion, "type" to type, "id" to id, "body" to body)
        if (protocolVersion >= 2) {
            originDeviceId?.let { envelope.put("originDeviceId", it) }
            clock?.let { envelope.put("clock", it) }
            envelope.put("sentAt", sentAt ?: System.currentTimeMillis())
            capability?.let { envelope.put("capability", it) }
            replyTo?.let { envelope.put("replyTo", it) }
        }
        val result = envelope.toString().toByteArray(StandardCharsets.UTF_8)
        require(result.size <= MAX_FRAME); return result + byteArrayOf(10)
    }
    companion object {
        fun parse(data: ByteArray): Wire {
            require(data.size <= MAX_FRAME); val o = JSONObject(String(data,StandardCharsets.UTF_8)); val version = o.getInt("v"); require(version in 1..2)
            val type = o.getString("type"); val id = o.getString("id"); require(type.isNotEmpty() && id.length <= 128)
            val origin = o.optString("originDeviceId").takeIf { it.isNotBlank() }
            val clock = if (o.has("clock")) o.getLong("clock").also { require(it >= 0) } else null
            val sentAt = if (o.has("sentAt")) o.getLong("sentAt") else null
            val capability = o.optString("capability").takeIf { it.isNotBlank() }
            val replyTo = o.optString("replyTo").takeIf { it.isNotBlank() }
            return Wire(type,o.getJSONObject("body"),id,version,origin,clock,sentAt,capability,replyTo)
        }
    }
}
class FrameIO(input: InputStream, private val output: OutputStream) {
    private val input = BufferedInputStream(input)
    @Volatile var protocolVersion: Int = 2
    @Synchronized fun send(wire: Wire) { output.write(wire.bytes(protocolVersion)); output.flush() }
    @Synchronized fun writeRaw(bytes: ByteArray, length: Int) {
        require(length in 0..bytes.size)
        output.write(bytes, 0, length)
    }
    @Synchronized fun flushRaw() { output.flush() }
    fun readRaw(bytes: ByteArray, length: Int): Int {
        require(length in 1..bytes.size)
        return input.read(bytes, 0, length)
    }
    fun read(): Wire {
        val out = java.io.ByteArrayOutputStream()
        while (true) {
            val n = input.read(); if (n < 0) throw java.io.EOFException("Connection closed")
            if (n == 10 && out.size() > 0) return Wire.parse(out.toByteArray())
            if (n != 10) { require(out.size() < MAX_FRAME) { "Frame too large" }; out.write(n) }
        }
    }
}
class SeenEvents {
    private val ids = LinkedHashSet<String>()
    @Synchronized fun insert(id: String): Boolean { if (!ids.add(id)) return false; if (ids.size > 4096) ids.remove(ids.first()); return true }
}
data class SharedFile(val id: String, val name: String, val size: Long, val sha256: String, val mime: String, val relativePath: String? = null) {
    fun validate() {
        UUID.fromString(id)
        require(name.isNotEmpty() && name.length <= 240 && name !in listOf(".","..") && name.none { it == '/' || it == '\\' || it == '\u0000' })
        require(size in 0..100_000_000_000 && sha256.matches(Regex("[0-9a-fA-F]{64}")))
        relativePath?.let { path ->
            val parts = path.split('/')
            require(path.isNotEmpty() && path.length <= 2048 && !path.startsWith('/') && !path.endsWith('/') && '\\' !in path && '\u0000' !in path)
            require(parts.isNotEmpty() && parts.all { it.isNotEmpty() && it !in listOf(".","..") && it.length <= 240 } && parts.last() == name)
        }
    }
    fun json() = obj("id" to id,"name" to name,"size" to size,"sha256" to sha256,"mime" to mime,"relativePath" to relativePath)
    companion object { fun parse(o: JSONObject) = SharedFile(o.getString("id"),o.getString("name"),o.getLong("size"),o.getString("sha256"),o.optString("mime","application/octet-stream"),o.optString("relativePath").takeIf { o.has("relativePath") && !o.isNull("relativePath") && it.isNotBlank() }).also { it.validate() } }
}
data class FileOffer(val id: String, val files: List<SharedFile>, val targetPath: String? = null, val transport: String? = null, val transferToken: String? = null) {
    fun validate() {
        UUID.fromString(id)
        require(files.isNotEmpty() && files.size <= 100 && files.map { it.id }.distinct().size == files.size)
        require(files.mapNotNull { it.relativePath }.distinct().size == files.count { it.relativePath != null })
        files.forEach { it.validate() }
        targetPath?.let { require(it.isEmpty() || normalizeSharedStoragePath(it) == it.trim().trim('/').replace('\\','/')) }
        if (transport != null) require(transport in listOf("tls-binary","plain-binary") && transferToken?.matches(Regex("[0-9a-fA-F]{64}")) == true)
        else require(transferToken == null)
    }
    fun json() = obj("id" to id,"files" to array(files.map { it.json() }),"targetPath" to targetPath,"transport" to transport,"transferToken" to transferToken)
    companion object { fun parse(o: JSONObject): FileOffer { val a = o.getJSONArray("files"); return FileOffer(o.getString("id"),(0 until a.length()).map { SharedFile.parse(a.getJSONObject(it)) },o.optString("targetPath").takeIf { o.has("targetPath") && !o.isNull("targetPath") },o.optString("transport").takeIf { o.has("transport") && !o.isNull("transport") },o.optString("transferToken").takeIf { o.has("transferToken") && !o.isNull("transferToken") }).also { it.validate() } } }
}

data class StorageEntry(val path: String, val name: String, val directory: Boolean, val size: Long, val modified: Long, val mime: String) {
    fun json() = obj("path" to path,"name" to name,"directory" to directory,"size" to size,"modified" to modified,"mime" to mime)
}
data class MediaEntry(
    val id: String,
    val name: String,
    val size: Long,
    val modified: Long,
    val mime: String,
    val width: Int,
    val height: Int,
    val duration: Long
) {
    fun json() = obj(
        "id" to id,"name" to name,"size" to size,"modified" to modified,"mime" to mime,
        "width" to width,"height" to height,"duration" to duration
    )
}
data class SmsThreadRecord(val id: String, val address: String, val contactName: String?, val snippet: String, val timestamp: Long, val unreadCount: Int) {
    fun json() = obj("id" to id,"address" to address,"contactName" to contactName,"snippet" to snippet,"timestamp" to timestamp,"unreadCount" to unreadCount)
}
data class SmsMessageRecord(val id: String, val threadId: String, val address: String, val body: String, val timestamp: Long, val outgoing: Boolean, val read: Boolean) {
    fun json() = obj("id" to id,"threadId" to threadId,"address" to address,"body" to body,"timestamp" to timestamp,"outgoing" to outgoing,"read" to read)
}
data class ContactRecord(val id: String, val name: String, val phones: List<String>) {
    fun json() = obj("id" to id,"name" to name,"phones" to array(phones))
}
data class MediaStateRecord(val packageName: String, val app: String, val title: String, val artist: String, val playing: Boolean, val actions: List<String>) {
    fun json() = obj("packageName" to packageName,"app" to app,"title" to title,"artist" to artist,"playing" to playing,"actions" to array(actions))
}
data class StreamOfferRecord(val sessionId: String, val kind: String, val codec: String, val control: Boolean = false) {
    fun json() = obj("sessionId" to sessionId,"kind" to kind,"codec" to codec,"control" to control)
}
data class MacPeer(val id: String, val name: String, val host: String, val port: Int, val fingerprint: String) {
    fun json() = obj("id" to id,"name" to name,"host" to host,"port" to port,"fingerprint" to fingerprint)
    companion object { fun parse(o: JSONObject) = MacPeer(o.getString("id"),o.getString("name"),o.getString("host"),o.getInt("port"),o.getString("fingerprint")) }
}
data class Invitation(val peer: MacPeer, val hosts: List<String>, val secret: String, val expires: Long) {
    companion object {
        fun parse(text: String): Invitation {
            require(text.length <= 8192); val o = JSONObject(text); require(o.getInt("v") in 1..2)
            val hosts = o.getJSONArray("hosts"); val addresses = (0 until hosts.length()).map { hosts.getString(it) }
            val id = o.getString("macId"); UUID.fromString(id)
            val port = o.getInt("port"); require(port in 1..65535)
            val fingerprint = o.getString("fingerprint"); require(fingerprint.matches(Regex("[0-9a-f]{64}")))
            val secret = o.getString("secret"); require(secret.length in 32..128)
            val expires = o.getLong("expires"); require(expires > System.currentTimeMillis()) { "Invitation expired. Generate another on your Mac." }
            return Invitation(MacPeer(id,o.getString("name"),addresses.firstOrNull() ?: "",port,fingerprint),addresses,secret,expires)
        }
    }
}
