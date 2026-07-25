package com.pulsegpx.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.UriMatcher
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * ContentProvider exposé par l'ANCIENNE app (com.example.booking_gpx).
 * PulseGpx l'interroge pour récupérer gpx_sessions.json.
 *
 * Ce fichier doit être AUSSI copié dans l'ancien projet booking_gpx
 * avec le package com.example.booking_gpx pour fonctionner.
 */
class MigrationProvider : ContentProvider() {

    companion object {
        const val AUTHORITY = "com.example.booking_gpx.migration"
        private const val CODE_SESSIONS = 1
        private val matcher = UriMatcher(UriMatcher.NO_MATCH).apply {
            addURI(AUTHORITY, "sessions", CODE_SESSIONS)
        }
    }

    override fun onCreate() = true

    override fun query(
        uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?
    ): Cursor? {
        if (matcher.match(uri) != CODE_SESSIONS) return null
        val file = File(context!!.filesDir, "gpx_sessions.json")
        if (!file.exists()) return null
        val cursor = MatrixCursor(arrayOf("json"))
        cursor.addRow(arrayOf(file.readText()))
        return cursor
    }

    override fun getType(uri: Uri) = "application/json"
    override fun insert(uri: Uri, values: ContentValues?) = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
}
