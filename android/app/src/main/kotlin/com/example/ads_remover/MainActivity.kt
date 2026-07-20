package com.example.ads_remover

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.HashMap

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.example.ads_remover/native"
        private const val RC_PICK_VIDEO = 1002
    }

    private var pendingPickVideoResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == RC_PICK_VIDEO) {
            pendingPickVideoResult?.let { result ->
                pendingPickVideoResult = null
                if (resultCode == Activity.RESULT_OK && data?.data != null) {
                    val uri = data.data!!
                    val realPath = resolveContentUri(uri.toString())
                    val map = HashMap<String, String>()
                    map["path"] = realPath
                    result.success(map)
                } else {
                    result.success(null)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> {
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        true
                    }
                    result.success(ok)
                }
                "openAllFilesAccessSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                    }
                    result.success(true)
                }
                "resolveVideoPath" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr == null) { result.success(null); return@setMethodCallHandler }
                    val resolved = resolveContentUri(uriStr)
                    result.success(resolved)
                }
                "pickVideo" -> {
                    pendingPickVideoResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "video/*"
                    }
                    startActivityForResult(intent, RC_PICK_VIDEO)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resolveContentUri(uriStr: String): String {
        // Already a real file path
        if (uriStr.startsWith("/")) return uriStr
        if (uriStr.startsWith("file://")) return uriStr.removePrefix("file://")

        try {
            val uri = Uri.parse(uriStr)
            if (uri.scheme == "content") {
                // Try DocumentsContract (external storage documents provider)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                    try {
                        val docId = DocumentsContract.getDocumentId(uri)
                        val parts = docId.split(":")
                        if (parts.size >= 2) {
                            val type = parts[0]
                            val path = parts.drop(1).joinToString(":")
                            if (type == "primary") return "/storage/emulated/0/$path"
                            else return "/storage/$type/$path"
                        }
                    } catch (_: Exception) {}
                }
                // Fallback: query MediaStore
                try {
                    val cursor = contentResolver.query(uri, null, null, null, null)
                    cursor?.use {
                        if (it.moveToFirst()) {
                            val idx = it.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)
                            if (idx >= 0) {
                                val data = it.getString(idx)
                                if (data != null) return data
                            }
                        }
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}

        // Return original if nothing worked
        return uriStr
    }
}
