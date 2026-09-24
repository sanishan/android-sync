package dev.androidsync

import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.selects.select
import java.util.concurrent.atomic.AtomicReference

class MacConnection(val peer: MacPeer, val socket: SSLSocket, val io: FrameIO, val protocolVersion: Int) : AutoCloseable {
    private val outbound = Channel<List<Wire>>(256)
    private val latestRealtimeFrame = AtomicReference<List<Wire>?>(null)
    private val realtimeFrameReady = Channel<Unit>(Channel.CONFLATED)
    private var writer: Job? = null
    @Synchronized fun startWriter(scope: CoroutineScope) {
        if (writer != null) return
        writer = scope.launch {
            try {
                while (isActive) {
                    val batch = select<List<Wire>?> {
                        outbound.onReceiveCatching { it.getOrNull() }
                        realtimeFrameReady.onReceiveCatching { if (it.isSuccess) latestRealtimeFrame.getAndSet(null) else null }
                    } ?: break
                    batch.forEach { io.send(it) }
                }
            } catch (_: Exception) { close() }
        }
    }
    fun enqueue(wire: Wire) = enqueueBatch(listOf(wire))
    fun enqueueBatch(batch: List<Wire>) { if (outbound.trySend(batch).isFailure) close() }
    /**
     * Screen video must favor the newest frame. Keeping a large FIFO
     * here turns a brief Wi-Fi slowdown into seconds of visible latency.
     * At most one complete encoded frame waits behind the frame being written.
     * The caller requests a fresh keyframe when this reports a replacement.
     */
    fun enqueueLatestRealtimeFrame(batch: List<Wire>): Boolean {
        if (batch.isEmpty()) return false
        val replaced = latestRealtimeFrame.getAndSet(batch) != null
        realtimeFrameReady.trySend(Unit)
        return replaced
    }
    /**
     * Large snapshots must wait for the writer instead of treating a temporarily
     * full queue as a broken connection. The regular non-suspending enqueue path
     * remains fail-fast for realtime/control events.
     */
    suspend fun enqueueBatchAwait(batch: List<Wire>) { outbound.send(batch) }
    override fun close() { latestRealtimeFrame.set(null); realtimeFrameReady.close(); outbound.close(); writer?.cancel(); runCatching { socket.close() } }
    companion object {
        fun openBulk(peer: MacPeer, store: SecureStore): MacConnection = runCatching { open(peer,store,"bulk") }.getOrElse { open(peer,store,"file") }
        fun open(peer: MacPeer, store: SecureStore, stream: String, secret: String? = null): MacConnection {
            // Pin the invitation's complete DER certificate. No permissive trust manager or plaintext fallback.
            val trust = object : X509TrustManager {
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) { error("Not a server") }
                override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                    require(!chain.isNullOrEmpty())
                    chain[0].checkValidity()
                    val actual = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                    val expected = peer.fingerprint.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                    require(MessageDigest.isEqual(actual,expected)) { "Mac identity changed. Pair again." }
                }
            }
            val address = InetAddress.getByName(peer.host)
            require(address.isSiteLocalAddress || address.isLinkLocalAddress || address.isLoopbackAddress) { "Use a local network address" }
            val ssl = SSLContext.getInstance("TLSv1.3").apply { init(null,arrayOf<TrustManager>(trust),null) }
            val socket = ssl.socketFactory.createSocket() as SSLSocket
            try {
                socket.enabledProtocols = arrayOf("TLSv1.3"); socket.soTimeout = 35_000
                socket.tcpNoDelay = true; socket.sendBufferSize = 256 * 1024
                socket.connect(InetSocketAddress(address,peer.port),8000); socket.startHandshake()
                val io = FrameIO(socket.inputStream,socket.outputStream); io.protocolVersion = 1
                val challenge = io.read(); require(challenge.type == "auth.challenge" && challenge.body.getString("macId") == peer.id)
                val nonce = challenge.body.getString("nonce"); require(nonce.length in 32..128)
                val body = obj("phoneId" to store.phoneId,"stream" to stream,"versions" to array(listOf(2,1)),"signature" to store.sign(signaturePayload(peer.id,nonce,stream,store.phoneId)))
                if (secret != null) { body.put("secret",secret); body.put("publicKey",store.publicKey()); body.put("name",android.os.Build.MODEL) }
                io.send(Wire(if (secret != null) "pair.request" else "auth.request",body,version = 1,sentAt = null))
                val result = io.read(); require(result.type == "auth.ok") { "Pairing rejected. Generate a new invitation." }
                val selected = result.body.optInt("protocol",1); require(selected in 1..2); io.protocolVersion = selected
                return MacConnection(peer,socket,io,selected)
            } catch (e: Exception) { socket.close(); throw e }
        }
    }
}
