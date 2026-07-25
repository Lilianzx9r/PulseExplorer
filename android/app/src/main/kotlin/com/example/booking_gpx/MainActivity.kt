package com.example.booking_gpx

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL               = "booking_gpx/capture"
        const val REQUEST_PROJECTION    = 1001
        const val REQUEST_OVERLAY       = 1002
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "hasOverlayPermission" ->
                        result.success(Settings.canDrawOverlays(this))

                    "requestOverlayPermission" -> {
                        if (Settings.canDrawOverlays(this)) {
                            result.success(true)
                        } else {
                            pendingResult = result
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivityForResult(intent, REQUEST_OVERLAY)
                        }
                    }

                    "startCapture" -> {
                        // Évite d'écraser un result en attente
                        pendingResult?.success(null)
                        pendingResult = result
                        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                                as MediaProjectionManager
                        try {
                            startActivityForResult(
                                mgr.createScreenCaptureIntent(),
                                REQUEST_PROJECTION
                            )
                        } catch (e: Exception) {
                            pendingResult = null
                            result.error("START_FAILED", e.message, null)
                        }
                    }

                    "startFloatingService" -> {
                        val resultCode = call.argument<Int>("resultCode") ?: run {
                            result.error("NO_CODE", "Missing resultCode", null)
                            return@setMethodCallHandler
                        }
                        val data = FloatingCaptureService.lastProjectionIntent ?: run {
                            result.error("NO_DATA", "No projection intent saved", null)
                            return@setMethodCallHandler
                        }
                        val svcIntent = Intent(this, FloatingCaptureService::class.java).apply {
                            putExtra("resultCode", resultCode)
                            putExtra("data", data)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(svcIntent)
                        } else {
                            startService(svcIntent)
                        }
                        result.success(true)
                    }

                    "stopFloatingService" -> {
                        stopService(Intent(this, FloatingCaptureService::class.java))
                        result.success(true)
                    }

                    "openApp" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val intent = packageManager.getLaunchIntentForPackage(pkg)
                        if (intent != null) { startActivity(intent); result.success(true) }
                        else result.success(false)
                    }

                    "isAppInstalled" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        result.success(try {
                            packageManager.getPackageInfo(pkg, 0); true
                        } catch (e: Exception) { false })
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {

            REQUEST_PROJECTION -> {
                val pr = pendingResult
                pendingResult = null
                if (resultCode == Activity.RESULT_OK && data != null) {
                    // Sauvegarder pour le service
                    FloatingCaptureService.lastProjectionIntent     = data
                    FloatingCaptureService.lastProjectionResultCode = resultCode
                    pr?.success(resultCode)
                } else {
                    // L'utilisateur a annulé la boîte MediaProjection
                    pr?.success(null)   // null = annulé, pas une erreur
                }
            }

            REQUEST_OVERLAY -> {
                val pr = pendingResult
                pendingResult = null
                pr?.success(Settings.canDrawOverlays(this))
            }
        }
    }
}
