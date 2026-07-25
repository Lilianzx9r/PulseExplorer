package com.pulsegpx.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.*
import android.widget.ImageButton
import android.widget.LinearLayout
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class FloatingCaptureService : Service() {

    companion object {
        const val CHANNEL_ID = "floating_capture_channel"
        const val NOTIFICATION_ID = 1
        var lastProjectionIntent: Intent? = null
        var lastProjectionResultCode: Int = 0
        // Callback vers Flutter quand une capture est prête
        var captureCallback: ((ByteArray) -> Unit)? = null
    }

    private var windowManager: WindowManager? = null
    private var floatingView: View? = null
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = intent?.getIntExtra("resultCode", 0) ?: 0
        val data = lastProjectionIntent

        if (resultCode != 0 && data != null) {
            setupMediaProjection(resultCode, data)
        }

        showFloatingButton()
        return START_NOT_STICKY
    }

    private fun setupMediaProjection(resultCode: Int, data: Intent) {
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        mediaProjection = mgr.getMediaProjection(resultCode, data)
    }

    private fun showFloatingButton() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        // Layout du bouton flottant
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(4, 4, 4, 4)
        }

        val btn = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_camera)
            setBackgroundColor(0xFF003580.toInt())
            setPadding(24, 24, 24, 24)
            contentDescription = "Capturer"
        }

        btn.setOnClickListener { captureScreen() }
        layout.addView(btn, LinearLayout.LayoutParams(120, 120))

        floatingView = layout

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.END or Gravity.BOTTOM
            x = 30
            y = 200
        }

        // Drag support
        var initialX = 0; var initialY = 0
        var initialTouchX = 0f; var initialTouchY = 0f
        btn.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params.x; initialY = params.y
                    initialTouchX = event.rawX; initialTouchY = event.rawY
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = initialX + (initialTouchX - event.rawX).toInt()
                    params.y = initialY + (initialTouchY - event.rawY).toInt()
                    windowManager?.updateViewLayout(floatingView, params)
                    true
                }
                else -> false
            }
        }

        windowManager?.addView(floatingView, params)
    }

    private fun captureScreen() {
        val mp = mediaProjection ?: return

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager?.defaultDisplay?.getRealMetrics(metrics)

        val width  = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi

        imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)

        virtualDisplay = mp.createVirtualDisplay(
            "GPXCapture", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, null
        )

        // Petit délai pour laisser le display se stabiliser
        android.os.Handler(mainLooper).postDelayed({
            val image: Image? = imageReader?.acquireLatestImage()
            if (image != null) {
                val bytes = imageToPng(image, width, height)
                image.close()
                captureCallback?.invoke(bytes)
            }
            virtualDisplay?.release()
            imageReader?.close()
            // Ramener notre app au premier plan
            bringAppToFront()
        }, 300)
    }

    private fun imageToPng(image: Image, width: Int, height: Int): ByteArray {
        val planes = image.planes
        val buffer: ByteBuffer = planes[0].buffer
        val pixelStride = planes[0].pixelStride
        val rowStride   = planes[0].rowStride
        val rowPadding  = rowStride - pixelStride * width

        val bitmap = Bitmap.createBitmap(
            width + rowPadding / pixelStride, height, Bitmap.Config.ARGB_8888
        )
        bitmap.copyPixelsFromBuffer(buffer)

        val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)
        bitmap.recycle()

        val out = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.PNG, 100, out)
        cropped.recycle()
        return out.toByteArray()
    }

    private fun bringAppToFront() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("from_capture", true)
        }
        startActivity(intent)
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, "Capture GPX",
            NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Service de capture pour superposition GPX" }
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PulseGpx actif")
            .setContentText("Appuyez sur 📸 pour capturer la carte")
            .setSmallIcon(android.R.drawable.ic_menu_mapmode)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        super.onDestroy()
        floatingView?.let { windowManager?.removeView(it) }
        virtualDisplay?.release()
        mediaProjection?.stop()
        imageReader?.close()
    }
}
