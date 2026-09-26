package dev.androidsync
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class ProtocolTest {
    private fun fixture(name: String) = javaClass.getResourceAsStream("/fixtures/$name.json")!!.readBytes()
    @Test fun notificationFixturePreservesUnicode() { val wire = Wire.parse(fixture("notification")); assertEquals("Messages",wire.body.getString("app")); assertTrue(wire.body.getString("text").contains("👋")); assertTrue(wire.body.getBoolean("reply")); assertTrue(java.util.Base64.getDecoder().decode(wire.body.getString("appIcon")).isNotEmpty()); assertEquals("notification.upsert",Wire.parse(wire.bytes().dropLast(1).toByteArray()).type) }
    @Test fun callNotificationFixtureKeepsTypedControls() {
        val body = Wire.parse(fixture("call-notification")).body
        assertTrue(body.getBoolean("call"))
        assertEquals("incoming",body.getString("callState"))
        assertEquals("Taylor Reed",body.getString("callerName"))
        assertEquals("+1 202-555-0147",body.getString("callerNumber"))
        val actions = body.getJSONArray("callActions")
        assertEquals(listOf("answer","decline","mute","declineMessage"),(0 until actions.length()).map { actions.getJSONObject(it).getString("kind") })
        assertTrue(actions.getJSONObject(3).getBoolean("requiresText"))
    }
    @Test fun clipboardImageFixtureKeepsIntegrityMetadata() {
        val wire = Wire.parse(fixture("clipboard-image-put"))
        assertEquals("clipboard.put", wire.type)
        assertEquals(24576L, wire.body.getLong("size"))
        assertEquals("image/png", wire.body.getString("mime"))
        assertEquals(64, wire.body.getString("sha256").length)
        assertEquals("Gallery", wire.body.getString("sourceApp"))
    }
    @Test fun clipboardEventFixtureKeepsStableMeshIdentity() {
        val wire = Wire.parse(fixture("clipboard-event-v2"))
        assertEquals(wire.id,wire.body.getString("clipId"))
        assertEquals(wire.originDeviceId,wire.body.getString("originDeviceId"))
        assertEquals(84L,wire.clock)
        assertEquals(64,wire.body.getString("contentHash").length)
    }
    @Test fun frameReaderHandlesConsecutiveLines() { val frames = Wire("ping").bytes()+Wire("pong").bytes(); val io = FrameIO(ByteArrayInputStream(frames),ByteArrayOutputStream()); assertEquals("ping",io.read().type); assertEquals("pong",io.read().type) }
    @Test fun binaryFileBytesCanFollowAJsonHeaderWithoutChangingTheirContents() {
        val payload = byteArrayOf(0,10,13,0,1,127,-1)
        val input = FrameIO(ByteArrayInputStream(Wire("file.ready",obj("offset" to 0)).bytes() + payload),ByteArrayOutputStream())
        assertEquals("file.ready",input.read().type)
        val actual = ByteArray(payload.size)
        assertEquals(payload.size,input.readRaw(actual,actual.size))
        assertArrayEquals(payload,actual)
        val output = ByteArrayOutputStream()
        FrameIO(ByteArrayInputStream(byteArrayOf()),output).writeRaw(payload,payload.size)
        assertArrayEquals(payload,output.toByteArray())
    }
    @Test fun fileTransportRequiresAnAuthenticatedOfferToken() {
        val file = SharedFile("c4c08708-64c0-45d5-af49-9a04e20a334b","video.mp4",1,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","video/mp4")
        val id = "91b26b3a-b58d-4f98-9487-2700bff6ed5e"
        for (mode in listOf("tls-binary","plain-binary")) {
            val offer = FileOffer(id,listOf(file),transport = mode,transferToken = "a".repeat(64))
            offer.validate()
            assertEquals(offer,FileOffer.parse(offer.json()))
        }
        assertThrows(IllegalArgumentException::class.java) { FileOffer(id,listOf(file),transport = "plain-binary").validate() }
        assertThrows(IllegalArgumentException::class.java) { FileOffer(id,listOf(file),transport = "unknown",transferToken = "a".repeat(64)).validate() }
        FileOffer(id,listOf(file)).validate()
    }
    @Test fun fileTransportSettingConvergesWithoutEcho() {
        assertTrue(shouldAdoptFileTransportSetting(11,"phone",10,"mac"))
        assertFalse(shouldAdoptFileTransportSetting(9,"phone",10,"mac"))
        assertFalse(shouldAdoptFileTransportSetting(10,"mac",10,"mac"))
        assertTrue(shouldAdoptFileTransportSetting(10,"phone",10,"mac"))
    }
    @Test fun boundedReaderRejectsMissingDelimiter() { val io = FrameIO(ByteArrayInputStream(ByteArray(MAX_FRAME+1){65}),ByteArrayOutputStream()); assertThrows(IllegalArgumentException::class.java) { io.read() } }
    @Test fun acceptsV2EnvelopeAndDowngradesForV1Peers() {
        val wire = Wire.parse(fixture("envelope-v2"))
        assertEquals(2,wire.version); assertEquals(42L,wire.clock); assertEquals("clipboard",wire.capability)
        val v1 = Wire.parse(wire.bytes(1).dropLast(1).toByteArray())
        assertEquals(1,v1.version); assertNull(v1.originDeviceId); assertNull(v1.clock)
    }
    @Test fun actionResultsCorrelateWithoutReplyContent() {
        val result = Wire("action.result",obj("commandId" to "command-1","state" to "accepted","code" to "action_accepted"),replyTo = "command-1")
        val decoded = Wire.parse(result.bytes().dropLast(1).toByteArray())
        assertEquals("command-1",decoded.replyTo)
        assertFalse(decoded.body.toString().contains("private reply"))
    }
    @Test fun rejectsUnknownProtocolVersion() { assertThrows(IllegalArgumentException::class.java) { Wire.parse("""{"v":3,"id":"x","type":"ping","body":{}}""".toByteArray()) } }
    @Test fun logicalClockOrdersRemoteEvents() { val clock = LogicalClock(); assertEquals(1,clock.tick()); assertEquals(8,clock.observe(7)); assertEquals(9,clock.tick()) }
    @Test fun clipboardQuotaIsPerDeviceAndKeepsPinnedItems() {
        fun clip(id: String, device: String, clock: Long, bytes: Long, pinned: Boolean = false) = ClipboardClip(id = id,kind = "image",size = bytes,originDevice = device,originDeviceId = device,logicalClock = clock,pinned = pinned)
        val pinned = clip("pinned","phone-a",1,90,pinned = true)
        val newest = clip("new","phone-a",3,20)
        val old = clip("old","phone-a",2,20)
        val other = clip("other","phone-b",1,100)
        val (kept,evicted) = ClipboardQuota.retain(listOf(old,pinned,other,newest),100)
        assertTrue(kept.any { it.id == "pinned" })
        assertFalse(kept.any { it.id == "new" })
        assertTrue(kept.any { it.id == "other" })
        assertEquals(setOf("new","old"),evicted.map { it.id }.toSet())
    }
    @Test fun sharedStorageFixtureAndPathsStayInPublicStorage() {
        val wire = Wire.parse(fixture("storage-list-v2"))
        assertEquals("files",wire.capability)
        assertEquals("Download/notes.txt",wire.body.getJSONArray("entries").getJSONObject(1).getString("path"))
        assertEquals("Download/photos",normalizeSharedStoragePath("/Download/photos/"))
        assertThrows(IllegalArgumentException::class.java) { normalizeSharedStoragePath("Download/../DCIM") }
        assertThrows(IllegalArgumentException::class.java) { normalizeSharedStoragePath("Android/data/com.example") }
        val file = SharedFile("c4c08708-64c0-45d5-af49-9a04e20a334b","notes.txt",0,"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","text/plain")
        assertThrows(IllegalArgumentException::class.java) { FileOffer("91b26b3a-b58d-4f98-9487-2700bff6ed5e",listOf(file),"../Download").validate() }
        val rootOffer = FileOffer("91b26b3a-b58d-4f98-9487-2700bff6ed5e",listOf(file),"")
        rootOffer.validate(); assertEquals("",FileOffer.parse(rootOffer.json()).targetPath)
    }
    @Test fun smsFixtureParsesWithoutSendingAnything() {
        val wire = Wire.parse(fixture("sms-message-v2"))
        assertEquals("sms",wire.capability)
        assertEquals("92",wire.body.getString("threadId"))
        assertEquals("Generated fixture message",wire.body.getString("body"))
        assertFalse(wire.body.getBoolean("outgoing"))
    }
    @Test fun screenOfferFixtureRequiresExplicitSessionAndCodec() {
        val wire = Wire.parse(fixture("stream-offer-v2"))
        assertEquals("stream.offer",wire.type); assertEquals("realtime",wire.capability)
        assertEquals("screen",wire.body.getString("kind")); assertEquals("h264",wire.body.getString("codec")); assertTrue(wire.body.getBoolean("control"))
    }
    @Test fun deduplicatesActions() { val cache = SeenEvents(); assertTrue(cache.insert("reply")); assertFalse(cache.insert("reply")); repeat(4096) { cache.insert("$it") }; assertTrue(cache.insert("reply")) }
    @Test fun emptyFileAndUnsafeManifest() { val offer = FileOffer.parse(Wire.parse(fixture("file-offer")).body); assertEquals(0,offer.files[0].size); assertEquals("Notes/Empty.txt",offer.files[0].relativePath); assertThrows(IllegalArgumentException::class.java) { offer.files[0].copy(name="../bad").validate() }; assertThrows(IllegalArgumentException::class.java) { offer.files[0].copy(relativePath="../Empty.txt").validate() }; assertThrows(IllegalArgumentException::class.java) { offer.files[0].copy(relativePath="Other/name.txt").validate() }; assertThrows(IllegalArgumentException::class.java) { offer.files[0].copy(size=-1).validate() }; assertThrows(IllegalArgumentException::class.java) { offer.copy(files=offer.files+offer.files).validate() }; assertThrows(IllegalArgumentException::class.java) { offer.copy(files=offer.files+offer.files[0].copy(id="8066f3c8-32d7-45f7-8f93-bd7a701edf42")).validate() } }
    @Test fun linksRejectPrivilegedSchemes() { assertTrue("https://example.com".isWebUrl()); assertFalse("file:///etc/passwd".isWebUrl()); assertFalse("javascript:alert(1)".isWebUrl()) }
    @Test fun authenticationBindsStreamAndNonce() {
        val keys = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val payload = signaturePayload("mac","nonce","control","phone")
        val sig = Signature.getInstance("SHA256withECDSA").apply { initSign(keys.private); update(payload) }.sign()
        fun verify(data: ByteArray): Boolean { val verifier = Signature.getInstance("SHA256withECDSA"); verifier.initVerify(keys.public); verifier.update(data); return verifier.verify(sig) }
        assertTrue(verify(payload)); assertFalse(verify(signaturePayload("mac","nonce","file","phone"))); assertFalse(verify(signaturePayload("mac","new","control","phone")))
    }
}
