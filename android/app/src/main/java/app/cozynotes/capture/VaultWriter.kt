package app.cozynotes.capture

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.UUID

internal data class CaptureRequest(val root: Uri, val text: String, val attachments: List<Uri>)
internal data class CaptureResult(val path: String)

/** SAF only: no raw filesystem paths, storage permission, network, or altered attachment bytes. */
internal class VaultWriter(private val context: Context) {
    private val resolver = context.contentResolver
    private data class Entry(val uri: Uri, val name: String, val mime: String, val flags: Int)

    fun capture(request: CaptureRequest): CaptureResult {
        require(request.text.isNotBlank() || request.attachments.isNotEmpty()) { "Add text or an attachment first." }
        val root = DocumentsContract.buildDocumentUriUsingTree(request.root, DocumentsContract.getTreeDocumentId(request.root))
        val id = UUID.randomUUID().toString()
        val timestamp = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmssSSS").withZone(ZoneOffset.UTC).format(Instant.now())
        val noteName = "$timestamp-$id.md"
        val created = mutableListOf<Uri>()
        var committed = false
        try {
            ensureInstructions(root)
            val inbox = directory(root, "Inbox")
            val links = mutableListOf<String>()
            val names = mutableListOf<String>()
            if (request.attachments.isNotEmpty()) {
                val attachments = directory(root, "Attachments")
                val bucket = create(attachments, DocumentsContract.Document.MIME_TYPE_DIR, id)
                created.add(bucket)
                val used = mutableSetOf<String>()
                request.attachments.forEachIndexed { index, source ->
                    require(source.scheme == "content") { "Only content-provider attachments can be captured." }
                    val originalName = displayName(source) ?: "attachment-${index + 1}"
                    val base = sanitize(originalName)
                    var filename = base
                    var suffix = 2
                    while (!used.add(filename.lowercase(java.util.Locale.ROOT))) {
                        val dot = base.lastIndexOf('.').takeIf { it > 0 } ?: base.length
                        filename = base.substring(0, dot) + "-${suffix++}" + base.substring(dot)
                    }
                    val mime = resolver.getType(source) ?: "application/octet-stream"
                    val target = create(bucket, "application/octet-stream", filename)
                    created.add(target)
                    resolver.openInputStream(source).use { input ->
                        if (input == null) throw IOException("Cannot read attachment: $originalName")
                        resolver.openOutputStream(target, "w").use { output ->
                            if (output == null) throw IOException("Cannot write attachment: $filename")
                            input.copyTo(output)
                            output.flush()
                        }
                    }
                    names.add(filename)
                    val image = mime.startsWith("image/") || filename.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) in setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg")
                    val label = filename.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
                    val encoded = java.net.URLEncoder.encode(filename, StandardCharsets.UTF_8.name()).replace("+", "%20").replace("*", "%2A")
                    links.add((if (image) "!" else "") + "[$label](../Attachments/$id/$encoded)")
                }
            }
            val markdown = buildString {
                if (request.text.isNotBlank()) append(request.text)
                else append("# ").append(names.firstOrNull() ?: "Untitled capture").append("\n")
                if (links.isNotEmpty()) {
                    if (!endsWith("\n")) append("\n")
                    if (!endsWith("\n\n")) append("\n")
                    append(links.joinToString("\n\n")).append("\n")
                }
            }
            // A non-.md temporary name keeps partial captures out of every notes browser.
            val staging = create(inbox, "application/octet-stream", ".$noteName.pending")
            created.add(staging)
            val flags = entry(staging).flags
            if (flags and DocumentsContract.Document.FLAG_SUPPORTS_RENAME == 0) {
                throw IOException("This folder provider cannot commit notes by rename. Select a local writable folder instead.")
            }
            writeUtf8(staging, markdown)
            val finalUri = DocumentsContract.renameDocument(resolver, staging, noteName)
                ?: throw IOException("The folder provider could not commit the capture.")
            created.remove(staging)
            created.add(finalUri)
            if (entry(finalUri).name != noteName) throw IOException("The folder provider changed the note filename.")
            committed = true
            return CaptureResult("Inbox/$noteName")
        } catch (error: Exception) {
            if (!committed) {
                val failed = created.asReversed().filter { uri ->
                    try { !DocumentsContract.deleteDocument(resolver, uri) } catch (_: Exception) { true }
                }
                if (failed.isNotEmpty()) throw IOException("${error.message ?: "Capture failed"} Some partial files could not be removed; inspect the vault before retrying.", error)
            }
            throw error
        }
    }

    private fun children(parent: Uri): List<Entry> {
        val query = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        return resolver.query(query, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(Entry(DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(0)), cursor.getString(1), cursor.getString(2), cursor.getInt(3)))
            }
        } ?: throw IOException("Cannot list the selected folder. Please choose it again.")
    }

    private fun entry(uri: Uri): Entry = resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
        if (!it.moveToFirst()) throw IOException("The folder provider lost a newly created file.")
        Entry(uri, it.getString(0), it.getString(1), it.getInt(2))
    } ?: throw IOException("Cannot inspect the selected folder.")

    private fun directory(parent: Uri, name: String): Uri {
        val existing = children(parent).firstOrNull { it.name == name }
        if (existing != null) {
            if (existing.mime != DocumentsContract.Document.MIME_TYPE_DIR) throw IOException("$name already exists but is not a folder.")
            return existing.uri
        }
        return create(parent, DocumentsContract.Document.MIME_TYPE_DIR, name)
    }

    private fun create(parent: Uri, mime: String, name: String): Uri {
        val uri = DocumentsContract.createDocument(resolver, parent, mime, name)
            ?: throw IOException("Cannot create $name in this folder.")
        try {
            if (entry(uri).name != name) throw IOException("The folder provider changed the filename $name. Use a local folder supporting original names.")
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(resolver, uri) } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
        return uri
    }

    private fun writeUtf8(uri: Uri, value: String) {
        resolver.openOutputStream(uri, "wt").use {
            if (it == null) throw IOException("Cannot write to the selected folder.")
            it.write(value.toByteArray(StandardCharsets.UTF_8))
            it.flush()
        }
    }

    private fun ensureInstructions(root: Uri) {
        if (children(root).any { it.name == "AGENTS.md" }) return
        val uri = create(root, "text/markdown", "AGENTS.md")
        try {
            writeUtf8(uri, """
                # Cozy Notes vault

                This is a local Markdown vault synced externally with Syncthing. Perform housekeeping only when the user requests it. You may rename, group, link, merge, and rewrite related notes to improve their usefulness, preserving their meaning, details, and original attachments.

                - Keep original attachment files and their bytes intact. Update relative Markdown links when moving notes.
                - Create Markdown companion descriptions or transcriptions for images where useful; be honest about uncertain or unreadable content. No OCR service is configured.
                - Never overwrite or discard Syncthing conflict files. Surface conflicts for the user to resolve.
                - Include affected vault-relative paths in responses.
                - Cloud CLI agents may send note contents and attachments to their providers. Ask the user before exposing private material; follow the selected provider's privacy and retention terms.
            """.trimIndent() + "\n")
        } catch (error: Exception) {
            try { DocumentsContract.deleteDocument(resolver, uri) } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    private fun displayName(uri: Uri): String? = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
    }

    private fun sanitize(name: String): String {
        val clean = name.replace(Regex("[\\p{Cntrl}/\\\\:*?\"<>|]"), "_").trim().trim('.')
        var end = 0
        var bytes = 0
        while (end < clean.length) {
            val point = clean.codePointAt(end)
            val width = when { point <= 0x7f -> 1; point <= 0x7ff -> 2; point <= 0xffff -> 3; else -> 4 }
            if (bytes + width > 180) break
            bytes += width
            end += Character.charCount(point)
        }
        return clean.substring(0, end).ifBlank { "attachment" }
    }
}
