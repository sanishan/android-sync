package dev.androidsync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.CipherInputStream
import javax.crypto.CipherOutputStream
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SecureStore(context: Context) {
    private val preferences = context.getSharedPreferences("secure",Context.MODE_PRIVATE)
    private val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val phoneId: String = preferences.getString("phone-id",null) ?: UUID.randomUUID().toString().also { preferences.edit().putString("phone-id",it).commit() }
    init {
        if (!keys.containsAlias("sync-sign")) KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore").apply {
            initialize(KeyGenParameterSpec.Builder("sync-sign",KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY).setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1")).setDigests(KeyProperties.DIGEST_SHA256).build())
        }.generateKeyPair()
        if (!keys.containsAlias("sync-storage")) KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("sync-storage",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        }.generateKey()
    }
    fun publicKey(): String = Base64.encodeToString(keys.getCertificate("sync-sign").publicKey.encoded,Base64.NO_WRAP)
    fun sign(message: ByteArray): String = Signature.getInstance("SHA256withECDSA").run { initSign(keys.getKey("sync-sign",null) as java.security.PrivateKey); update(message); Base64.encodeToString(sign(),Base64.NO_WRAP) }
    @Synchronized fun get(name: String): String? {
        val saved = preferences.getString(name,null) ?: return null
        return String(open(name,Base64.decode(saved,Base64.NO_WRAP)),Charsets.UTF_8)
    }
    @Synchronized fun put(name: String, value: String) {
        val data = seal(name,value.toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(name,Base64.encodeToString(data,Base64.NO_WRAP)).commit()) { "Could not save encrypted settings" }
    }
    @Synchronized fun seal(name: String, value: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,keys.getKey("sync-storage",null) as SecretKey); cipher.updateAAD(name.toByteArray())
        return cipher.iv + cipher.doFinal(value)
    }
    @Synchronized fun open(name: String, value: ByteArray): ByteArray {
        require(value.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE,keys.getKey("sync-storage",null) as SecretKey,GCMParameterSpec(128,value.copyOfRange(0,12)))
        cipher.updateAAD(name.toByteArray())
        return cipher.doFinal(value.copyOfRange(12,value.size))
    }
    @Synchronized fun encryptFile(name: String, source: java.io.File, destination: java.io.File) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE,keys.getKey("sync-storage",null) as SecretKey)
        cipher.updateAAD(name.toByteArray())
        destination.parentFile?.mkdirs()
        val temporary = java.io.File(destination.parentFile,"." + destination.name + "." + UUID.randomUUID() + ".tmp")
        try {
            temporary.outputStream().buffered().use { raw ->
                raw.write(cipher.iv)
                CipherOutputStream(raw,cipher).use { encrypted -> source.inputStream().buffered().use { it.copyTo(encrypted,64 * 1024) } }
            }
            check(temporary.renameTo(destination) || run { temporary.copyTo(destination,overwrite = true); temporary.delete(); true })
        } finally { if (temporary.exists()) temporary.delete() }
    }
    @Synchronized fun decryptFile(name: String, source: java.io.File, destination: java.io.File) {
        source.inputStream().buffered().use { raw ->
            val iv = ByteArray(12)
            require(raw.read(iv) == iv.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE,keys.getKey("sync-storage",null) as SecretKey,GCMParameterSpec(128,iv))
            cipher.updateAAD(name.toByteArray())
            destination.parentFile?.mkdirs()
            val temporary = java.io.File(destination.parentFile,"." + destination.name + "." + UUID.randomUUID() + ".tmp")
            try {
                CipherInputStream(raw,cipher).use { decrypted -> temporary.outputStream().buffered().use { decrypted.copyTo(it,64 * 1024) } }
                check(temporary.renameTo(destination) || run { temporary.copyTo(destination,overwrite = true); temporary.delete(); true })
            } finally { if (temporary.exists()) temporary.delete() }
        }
    }
}
