package com.bluebubbles.messaging.services.filesystem

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.graphics.BitmapFactory
import android.provider.DocumentsContract
import android.os.CancellationSignal
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Read-only SAF access. Only explicitly selected files enter the app cache. */
class StickerFolderAccess(private val activity: Activity) {
    companion object {
        const val REQUEST_CODE = 8619
        const val CHANNEL = "com.bluebubbles.messaging/sticker-folder"
        const val MAX_BYTES = 500 * 1024
        private val extensions = setOf("png", "apng", "gif", "jpg", "jpeg")
    }

    private val prefs = activity.getSharedPreferences("sticker-folder", Activity.MODE_PRIVATE)
    private val executor = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(4))
    private val thumbnails = ThreadPoolExecutor(2, 2, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(16))
    private val closed = AtomicBoolean(false)
    private val pending = ConcurrentHashMap<MethodChannel.Result, Boolean>()
    private val readJobs = ConcurrentHashMap<String, Pair<Runnable, MethodChannel.Result>>()
    private val signals = ConcurrentHashMap<MethodChannel.Result, CancellationSignal>()
    private val streams = ConcurrentHashMap<MethodChannel.Result, InputStream>()
    private var pickerResult: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (closed.get()) {
            result.error("closed", "Sticker folder browser closed.", null)
            return
        }
        if (call.method == "cancel-read") {
            call.argument<String>("requestId")?.let { id ->
                readJobs.remove(id)?.let { (job, reply) ->
                    thumbnails.remove(job)
                    signals.remove(reply)?.cancel()
                    try { streams.remove(reply)?.close() } catch (_: Exception) { }
                    if (pending.remove(reply) != null) reply.error("cancelled", "Thumbnail no longer visible.", null)
                }
            }
            result.success(null)
            return
        }
        if (call.method == "choose-folder") {
            if (pickerResult != null) {
                result.error("busy", "Folder picker is already open.", null)
                return
            }
            pickerResult = result
            try {
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }, REQUEST_CODE)
            } catch (e: Exception) {
                pickerResult = null
                result.error("picker", "Could not open the folder picker.", null)
            }
            return
        }
        if (call.method !in setOf("get-folder", "list-folder", "read-sticker", "stage-sticker")) {
            result.notImplemented()
            return
        }
        pending[result] = true
        signals[result] = CancellationSignal()
        val requestId = call.argument<String>("requestId")
        val job = Runnable {
            try {
                check(!closed.get() && pending.containsKey(result))
                val output: Any? = when (call.method) {
                    "get-folder" -> prefs.getString("tree", null)?.let { checkedTree().toString() }
                    "list-folder" -> list(call.argument<String>("uri"), call.argument<Int>("offset") ?: 0, result)
                    "read-sticker" -> read(checkedDocument(call.argument<String>("uri")), result) {
                        !closed.get() && pending.containsKey(result)
                    }
                    else -> stage(checkedDocument(call.argument<String>("uri")), result)
                }
                activity.runOnUiThread {
                    if (requestId != null) readJobs.remove(requestId)
                    signals.remove(result)
                    if (pending.remove(result) != null && !closed.get()) {
                        result.success(output)
                    } else if (call.method == "stage-sticker" && output is Map<*, *>) {
                        (output["path"] as? String)?.let { File(it).delete() }
                    }
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    if (requestId != null) readJobs.remove(requestId)
                    signals.remove(result)
                    if (pending.remove(result) != null) {
                        if (e is IllegalArgumentException) {
                            result.error("invalid-sticker", "Use PNG, APNG, GIF or JPEG up to 500 KiB and 618 × 618, with a safe filename up to 255 characters.", null)
                        } else {
                            result.error("folder-access", "Cannot read this sticker folder. Choose it again if access was revoked.", null)
                        }
                    }
                }
            }
        }
        if (call.method == "read-sticker" && requestId != null) readJobs[requestId] = Pair(job, result)
        try {
            if (call.method == "read-sticker") thumbnails.execute(job) else executor.execute(job)
        } catch (e: RejectedExecutionException) {
            if (requestId != null) readJobs.remove(requestId)
            signals.remove(result)
            if (pending.remove(result) != null) result.error("busy", "Folder browser is busy. Try again.", null)
        }
    }

    fun onActivityResult(resultCode: Int, data: Intent?) {
        val result = pickerResult ?: return
        pickerResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
            require((data?.flags ?: 0) and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val previous = prefs.getString("tree", null)
            prefs.edit().putString("tree", uri.toString()).apply()
            if (previous != null && previous != uri.toString()) {
                try {
                    activity.contentResolver.releasePersistableUriPermission(Uri.parse(previous), Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Exception) { }
            }
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("folder-grant", "This provider did not grant lasting read access. Choose a different folder.", null)
        }
    }

    private fun checkedTree(): Uri {
        val tree = Uri.parse(prefs.getString("tree", null) ?: error("No folder selected"))
        require(activity.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission })
        return tree
    }

    private fun checkedDocument(raw: String?): Uri {
        val tree = checkedTree()
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        if (raw == null || raw == tree.toString()) return root
        val uri = Uri.parse(raw)
        require(uri.scheme == "content" && uri.authority == tree.authority && DocumentsContract.isTreeUri(uri))
        require(DocumentsContract.getTreeDocumentId(uri) == DocumentsContract.getTreeDocumentId(tree))
        require(uri == root || DocumentsContract.isChildDocument(activity.contentResolver, root, uri))
        return uri
    }

    private fun list(raw: String?, offset: Int, owner: MethodChannel.Result): Map<String, Any> {
        require(offset >= 0)
        val parent = checkedDocument(raw)
        val tree = checkedTree()
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        val entries = mutableListOf<Map<String, Any>>()
        var nextOffset = offset
        var hasMore = false
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE)
        activity.contentResolver.query(children, columns, null, null, null, signal(owner))?.use { cursor ->
            cursor.moveToPosition(offset - 1)
            var scanned = 0
            while (scanned < 200 && entries.size < 60 && cursor.moveToNext()) {
                scanned++
                val name = cursor.getString(1) ?: continue
                val directory = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                if (!directory && name.substringAfterLast('.', "").lowercase() !in extensions) continue
                if (!safeName(name)) continue
                entries.add(mapOf("uri" to DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)).toString(),
                    "name" to name, "directory" to directory, "size" to cursor.getLong(3)))
            }
            nextOffset = cursor.position.coerceAtMost(cursor.count) + if (cursor.position < cursor.count) 1 else 0
            hasMore = nextOffset < cursor.count
        } ?: error("Folder unavailable")
        return mapOf("entries" to entries, "nextOffset" to nextOffset, "hasMore" to hasMore)
    }

    private fun read(uri: Uri, owner: MethodChannel.Result, active: () -> Boolean = { !closed.get() }): ByteArray {
        val output = ByteArrayOutputStream()
        activity.contentResolver.openAssetFileDescriptor(uri, "r", signal(owner))?.use { descriptor ->
            descriptor.createInputStream().use { input ->
                streams[owner] = input
                try {
                    val buffer = ByteArray(8192)
                    while (true) {
                        check(active())
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= MAX_BYTES) { "Sticker exceeds 500 KiB" }
                        output.write(buffer, 0, count)
                    }
                } finally {
                    streams.remove(owner)
                }
            }
        } ?: error("File unavailable")
        val bytes = output.toByteArray()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth in 1..618 && bounds.outHeight in 1..618) { "Invalid or oversized sticker canvas" }
        return bytes
    }

    private fun stage(uri: Uri, owner: MethodChannel.Result): Map<String, Any> {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val name = activity.contentResolver.query(uri, columns, null, null, null, signal(owner))?.use {
            require(it.moveToFirst())
            it.getString(0)
        } ?: error("File unavailable")
        val extension = name.substringAfterLast('.', "").lowercase()
        require(extension in extensions && safeName(name))
        val bytes = read(uri, owner)
        check(!closed.get())
        val directory = File(activity.cacheDir, "selected-stickers").apply { mkdirs() }
        // Only files created by this feature are eligible for stale-cache cleanup.
        Files.newDirectoryStream(directory.toPath()).use { stream ->
            var removed = 0
            for (path in stream) {
                val stale = path.toFile()
                if (stale.isFile && stale.name.startsWith("sticker-") &&
                    stale.lastModified() < System.currentTimeMillis() - 86400000L && stale.delete()) {
                    if (++removed >= 100) break
                }
            }
        }
        val file = File.createTempFile("sticker-", ".$extension", directory)
        try {
            file.writeBytes(bytes)
            check(!closed.get())
            return mapOf("path" to file.absolutePath, "name" to name, "size" to bytes.size)
        } catch (e: Exception) {
            file.delete()
            throw e
        }
    }

    fun close() {
        closed.set(true)
        pickerResult?.success(null)
        pickerResult = null
        executor.shutdownNow()
        thumbnails.shutdownNow()
        readJobs.clear()
        signals.values.forEach { it.cancel() }
        signals.clear()
        streams.values.forEach { try { it.close() } catch (_: Exception) { } }
        streams.clear()
        pending.keys.toList().forEach { result ->
            if (pending.remove(result) != null) result.error("closed", "Sticker folder browser closed.", null)
        }
    }

    private fun safeName(name: String): Boolean = name.length in 1..255 &&
        name !in setOf(".", "..") && name.none { it == '/' || it == '\\' || it.code < 32 || it.code in 127..159 }

    private fun signal(owner: MethodChannel.Result): CancellationSignal =
        signals[owner] ?: CancellationSignal().apply { cancel() }
}
