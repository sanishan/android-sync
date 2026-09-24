package dev.androidsync

import android.content.ContentResolver
import android.content.ContentUris
import android.graphics.Bitmap
import android.os.Bundle
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream

/** Paged, read-only access to user-visible photos and videos for trusted Macs. */
class GalleryBrowser(private val engine: SyncEngine) {
    private val resolver get() = engine.context.contentResolver
    private val available get() = engine.sharedStorage.available

    fun list(connection: MacConnection, requestId: String, cursor: Int, requestedLimit: Int) {
        engine.scope.launch {
            val response = runCatching {
                check(available) { "Allow All files access on Android before browsing photos and videos." }
                require(cursor >= 0) { "Invalid media page." }
                val limit = requestedLimit.coerceIn(1,20)
                val rows = query(cursor,limit + 1)
                val page = rows.take(limit)
                Wire("gallery.list.result",obj(
                    "requestId" to requestId,
                    "cursor" to cursor,
                    "nextCursor" to (cursor + page.size),
                    "hasMore" to (rows.size > limit),
                    "entries" to array(page.map { it.json() }),
                    "state" to "accepted"
                ),replyTo = requestId,capability = "files")
            }.getOrElse { error ->
                Wire("gallery.list.result",obj(
                    "requestId" to requestId,"cursor" to cursor,"entries" to array(emptyList<Any>()),
                    "hasMore" to false,"state" to "failed","reason" to (error.message ?: "Media library unavailable")
                ),replyTo = requestId,capability = "files")
            }
            engine.send(connection.peer.id,response)
        }
    }

    fun thumbnail(connection: MacConnection, requestId: String, mediaId: String) {
        engine.scope.launch {
            val response = runCatching {
                check(available) { "Media access is unavailable." }
                val bitmap = resolver.loadThumbnail(uri(mediaId),Size(320,320),null)
                val bytes = compressedThumbnail(bitmap)
                Wire("gallery.thumbnail.result",obj(
                    "requestId" to requestId,"mediaId" to mediaId,"mime" to "image/jpeg",
                    "data" to Base64.encodeToString(bytes,Base64.NO_WRAP),"state" to "accepted"
                ),replyTo = requestId,capability = "files")
            }.getOrElse { error ->
                Wire("gallery.thumbnail.result",obj(
                    "requestId" to requestId,"mediaId" to mediaId,"state" to "failed",
                    "reason" to (error.message ?: "Thumbnail unavailable")
                ),replyTo = requestId,capability = "files")
            }
            engine.send(connection.peer.id,response)
        }
    }

    fun download(connection: MacConnection, requestId: String, mediaIds: List<String>) {
        if (!available) {
            engine.send(connection.peer.id,Wire("gallery.download.result",obj("requestId" to requestId,"state" to "failed","reason" to "Allow All files access on Android first."),capability = "files"))
            return
        }
        engine.scope.launch {
            runCatching {
                require(mediaIds.isNotEmpty() && mediaIds.size <= 100) { "Choose between 1 and 100 photos or videos." }
                val offer = engine.fileManager.prepareUris(mediaIds.distinct().map(::uri),connection.peer.id,announce = false)
                engine.send(connection.peer.id,Wire("gallery.download.result",obj("requestId" to requestId,"state" to "accepted","transferId" to offer.id),capability = "files"))
                engine.send(connection.peer.id,Wire("file.offer",offer.json(),capability = "files"))
            }.onFailure { error ->
                engine.send(connection.peer.id,Wire("gallery.download.result",obj("requestId" to requestId,"state" to "failed","reason" to (error.message ?: "Could not prepare media.")),capability = "files"))
            }
        }
    }

    private fun query(offset: Int, limit: Int): List<MediaEntry> {
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.Video.VideoColumns.DURATION
        )
        val arguments = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION,"${MediaStore.Files.FileColumns.MEDIA_TYPE}=? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE}=?")
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()))
            putString(
                ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                "${MediaStore.MediaColumns.DATE_MODIFIED} DESC, ${MediaStore.Files.FileColumns._ID} DESC"
            )
            putInt(ContentResolver.QUERY_ARG_LIMIT,limit)
            putInt(ContentResolver.QUERY_ARG_OFFSET,offset)
        }
        return resolver.query(collection,projection,arguments,null)?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val typeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val widthColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val heightColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Video.VideoColumns.DURATION)
            buildList {
                while (cursor.moveToNext()) {
                    val type = cursor.getInt(typeColumn)
                    val prefix = if (type == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) "video" else "image"
                    add(MediaEntry(
                        id = "$prefix:${cursor.getLong(idColumn)}",
                        name = cursor.getString(nameColumn) ?: "Media",
                        size = cursor.getLong(sizeColumn).coerceAtLeast(0),
                        modified = cursor.getLong(modifiedColumn).coerceAtLeast(0) * 1000,
                        mime = cursor.getString(mimeColumn) ?: if (prefix == "video") "video/*" else "image/*",
                        width = cursor.getInt(widthColumn).coerceAtLeast(0),
                        height = cursor.getInt(heightColumn).coerceAtLeast(0),
                        duration = if (prefix == "video") cursor.getLong(durationColumn).coerceAtLeast(0) else 0
                    ))
                }
            }
        } ?: emptyList()
    }

    private fun uri(mediaId: String): android.net.Uri {
        val pieces = mediaId.split(':',limit = 2)
        require(pieces.size == 2) { "Invalid media identifier." }
        val id = pieces[1].toLong().also { require(it >= 0) }
        val collection = when (pieces[0]) {
            "image" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            else -> error("Invalid media identifier.")
        }
        return ContentUris.withAppendedId(collection,id)
    }

    private fun compressedThumbnail(source: Bitmap): ByteArray {
        val scaled = if (maxOf(source.width,source.height) > 320) {
            val scale = 320.0 / maxOf(source.width,source.height)
            Bitmap.createScaledBitmap(source,(source.width * scale).toInt().coerceAtLeast(1),(source.height * scale).toInt().coerceAtLeast(1),true)
        } else source
        var quality = 76
        var bytes: ByteArray
        do {
            bytes = ByteArrayOutputStream().use { output -> scaled.compress(Bitmap.CompressFormat.JPEG,quality,output); output.toByteArray() }
            quality -= 12
        } while (bytes.size > 96 * 1024 && quality >= 28)
        if (scaled !== source) scaled.recycle()
        require(bytes.isNotEmpty() && bytes.size <= 128 * 1024) { "Thumbnail is too large." }
        return bytes
    }
}
