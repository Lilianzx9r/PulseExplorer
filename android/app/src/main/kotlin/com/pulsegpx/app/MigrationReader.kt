package com.pulsegpx.app

import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri

/**
 * Côté PulseGpx : lit les données de l'ancienne app via ContentProvider.
 */
object MigrationReader {

    private const val OLD_PACKAGE   = "com.example.booking_gpx"
    private const val OLD_AUTHORITY = "com.example.booking_gpx.migration"

    /** Vérifie si l'ancienne app est installée */
    fun isOldAppInstalled(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo(OLD_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    fun readSessionsJson(context: Context)    = readJson(context, "sessions")
    fun readPoiLayersJson(context: Context)   = readJson(context, "poi_layers")
    fun readPoiFoldersJson(context: Context)  = readJson(context, "poi_folders")

    private fun readJson(context: Context, path: String): String? {
        return try {
            val uri = Uri.parse("content://$OLD_AUTHORITY/$path")
            val cursor = context.contentResolver.query(
                uri, null, null, null, null
            ) ?: return null
            cursor.use {
                if (!it.moveToFirst()) return null
                it.getString(0).takeIf { s -> s.isNotBlank() && s != "[]" }
            }
        } catch (e: Exception) {
            null
        }
    }
}
