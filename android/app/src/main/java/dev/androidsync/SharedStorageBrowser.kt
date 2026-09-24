package dev.androidsync

import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.Settings
import android.webkit.MimeTypeMap
import kotlinx.coroutines.launch
import java.io.File

/** Read-only shared-storage browsing for the private localFull build. */
class SharedStorageBrowser(private val engine: SyncEngine) {
    private val root: File get() = Environment.getExternalStorageDirectory().canonicalFile

    val available: Boolean
        get() = BuildConfig.LOCAL_FULL && Environment.isExternalStorageManager()

    fun openPermissionSettings() {
        if (!BuildConfig.LOCAL_FULL) {
            engine.fail("Shared-storage browsing is available only in the private localFull build.")
            return
        }
        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${engine.context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { engine.context.startActivity(intent) }
            .recoverCatching { engine.context.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onFailure { engine.fail("Open Android Settings → Special app access → All files access.") }
    }

    fun list(connection: MacConnection, requestId: String, relativePath: String, offset: Int, requestedLimit: Int) {
        engine.scope.launch {
            val response = runCatching {
                check(available) { "Allow All files access on Android to browse shared storage." }
                require(offset >= 0) { "Invalid storage page." }
                val limit = requestedLimit.coerceIn(1,100)
                val folder = resolve(relativePath)
                require(folder.isDirectory) { "The selected folder is unavailable." }
                val allEntries = folder.listFiles().orEmpty()
                    .asSequence()
                    .filter { !blocked(it) }
                    .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
                    .toList()
                val entries = allEntries.asSequence()
                    .drop(offset)
                    .take(limit)
                    .map { file ->
                        StorageEntry(
                            path = relative(file),
                            name = file.name,
                            directory = file.isDirectory,
                            size = if (file.isFile) file.length() else 0,
                            modified = file.lastModified(),
                            mime = if (file.isDirectory) "inode/directory" else mime(file)
                        ).json()
                    }.toList()
                Wire("storage.list.result",obj(
                    "requestId" to requestId,
                    "path" to relative(folder),
                    "parent" to folder.parentFile?.takeIf { inside(it) }?.let(::relative),
                    "entries" to array(entries),
                    "offset" to offset,
                    "nextOffset" to (offset + entries.size),
                    "hasMore" to (offset + entries.size < allEntries.size),
                    "state" to "accepted"
                ),replyTo = requestId,capability = "files")
            }.getOrElse { error ->
                Wire("storage.list.result",obj("requestId" to requestId,"path" to relativePath,"entries" to array(emptyList<Any>()),"state" to "failed","reason" to (error.message ?: "Storage unavailable")),replyTo = requestId,capability = "files")
            }
            engine.send(connection.peer.id,response)
        }
    }

    fun download(connection: MacConnection, requestId: String, paths: List<String>) {
        if (!available) { engine.send(connection.peer.id,Wire("storage.download.result",obj("requestId" to requestId,"state" to "failed","reason" to "Allow All files access on Android first."),capability = "files")); return }
        engine.scope.launch {
            runCatching {
                require(paths.isNotEmpty() && paths.size <= 100) { "Choose between 1 and 100 files or folders." }
                val selected = paths.distinct().map(::resolve)
                val expanded = mutableListOf<Pair<File,String>>()
                selected.forEach { source ->
                    if (source.isFile) expanded += source to source.name
                    else {
                        require(source.isDirectory) { "A selected item is unavailable." }
                        val rootName = source.name
                        source.walkTopDown().filter { it.isFile }.forEach { child ->
                            val canonical = child.canonicalFile
                            require(inside(canonical) && !blocked(canonical)) { "A folder contains unavailable content." }
                            val childPath = source.toPath().relativize(canonical.toPath()).toString().replace(File.separatorChar,'/')
                            expanded += canonical to "$rootName/$childPath"
                            require(expanded.size <= 100) { "This selection contains more than 100 files. Choose a smaller batch." }
                        }
                    }
                }
                require(expanded.isNotEmpty()) { "The selected folders do not contain downloadable files." }
                val offer = engine.fileManager.prepareFiles(
                    expanded.map { it.first },connection.peer.id,announce = false,
                    relativePaths = expanded.associate { it.first.canonicalPath to it.second }
                )
                engine.send(connection.peer.id,Wire("storage.download.result",obj("requestId" to requestId,"state" to "accepted","transferId" to offer.id),capability = "files"))
                engine.send(connection.peer.id,Wire("file.offer",offer.json(),capability = "files"))
            }.onFailure { engine.send(connection.peer.id,Wire("storage.download.result",obj("requestId" to requestId,"state" to "failed","reason" to (it.message ?: "Could not prepare files.")),capability = "files")) }
        }
    }

    fun resolve(relativePath: String): File {
        val clean = normalizeSharedStoragePath(relativePath)
        val candidate = if (clean.isBlank()) root else File(root,clean).canonicalFile
        require(inside(candidate) && !blocked(candidate)) { "That Android folder is private or unavailable." }
        return candidate
    }

    fun uniqueFile(folder: File, requestedName: String): File {
        val safe = requestedName.replace('/','_').replace('\\','_').replace('\u0000','_').take(240).ifBlank { "Received file" }
        var candidate = File(folder,safe)
        if (!candidate.exists()) return candidate
        val dot = safe.lastIndexOf('.').takeIf { it > 0 } ?: safe.length
        val stem = safe.substring(0,dot); val suffix = safe.substring(dot)
        var index = 2
        while (candidate.exists()) { candidate = File(folder,"$stem ($index)$suffix"); index++ }
        return candidate
    }

    private fun inside(file: File): Boolean = file.path == root.path || file.path.startsWith(root.path + File.separator)
    private fun blocked(file: File): Boolean {
        val relative = runCatching { relative(file).lowercase() }.getOrDefault("")
        return relative == "android/data" || relative.startsWith("android/data/") || relative == "android/obb" || relative.startsWith("android/obb/")
    }
    private fun relative(file: File): String = if (file.canonicalPath == root.path) "" else file.canonicalPath.removePrefix(root.path + File.separator).replace(File.separatorChar,'/')
    private fun mime(file: File): String = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
}
