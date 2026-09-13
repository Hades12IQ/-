package com.firas.ai.documents

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

object DocumentFiles {
    fun uri(context: Context, file: File): Uri {
        val target = file.canonicalFile
        val roots = listOf(File(context.cacheDir, "exports").canonicalFile, File(context.filesDir, "exports").canonicalFile)
        require(roots.any { target.path.startsWith(it.path + File.separator) }) { "Only prepared export files can be shared." }
        return FileProvider.getUriForFile(context, context.packageName + ".files", target)
    }
    fun open(context: Context, file: File) {
        val uri = uri(context, file)
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/pdf").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri(file.name, uri) })
    }
    fun share(context: Context, file: File) {
        val uri = uri(context, file)
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri(file.name, uri) }, file.name))
    }
}
