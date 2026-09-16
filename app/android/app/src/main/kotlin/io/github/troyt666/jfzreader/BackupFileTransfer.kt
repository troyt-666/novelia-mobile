package io.github.troyt666.jfzreader

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream

/** SAF handles grant access to one user-selected document, without storage permissions. */
class BackupFileTransfer(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var exportFile: File? = null
    private val requestCode = 8402
    private val maxBytes = 128L * 1024 * 1024

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pickBackup" && call.method != "saveBackup") {
            result.notImplemented(); return
        }
        if (pending != null) {
            result.error("BUSY", "A document picker is already open.", null); return
        }
        try {
            val saving = call.method == "saveBackup"
            exportFile = if (saving) File(call.arguments as String) else null
            val intent = Intent(if (saving) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(if (saving) "application/octet-stream" else "*/*")
            if (saving) intent.putExtra(Intent.EXTRA_TITLE, exportFile!!.name)
            pending = result
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, requestCode)
        } catch (_: Exception) {
            pending = null; exportFile = null
            result.error("FILE_PICKER", "Unable to open the document picker.", null)
        }
    }

    fun onResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending ?: return true
        val source = exportFile
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null; exportFile = null
            result.success(if (source == null) null else false)
            return true
        }
        Thread {
            var temporary: File? = null
            try {
                if (source != null) {
                    require(source.length() <= maxBytes)
                    activity.contentResolver.openOutputStream(uri, "wt")!!.use { output ->
                        source.inputStream().use { input -> copyBounded(input, output) }
                    }
                } else {
                    temporary = File.createTempFile("jfz-backup-import-", ".jfzbackup", activity.cacheDir)
                    activity.contentResolver.openInputStream(uri)!!.use { input ->
                        temporary.outputStream().use { output -> copyBounded(input, output) }
                    }
                }
                val path = temporary?.absolutePath
                activity.runOnUiThread {
                    pending = null; exportFile = null
                    result.success(if (source == null) path else true)
                }
            } catch (_: Exception) {
                temporary?.delete()
                activity.runOnUiThread {
                    pending = null; exportFile = null
                    result.error("FILE_COPY", "Unable to copy backup (limit 128 MB).", null)
                }
            }
        }.start()
        return true
    }

    private fun copyBounded(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            require(total <= maxBytes)
            output.write(buffer, 0, count)
        }
        output.flush()
    }
}
