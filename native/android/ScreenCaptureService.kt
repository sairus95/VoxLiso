package com.voxliso.voxliso

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlin.math.max
import kotlin.math.min

/**
 * Capture l'écran du téléphone (MediaProjection) et y lit le texte (ML Kit),
 * pour les vidéos regardées sur le téléphone lui-même (YouTube, navigateur…).
 *
 * Les applications protégées (Netflix, Disney+, Prime Video…) apparaissent en
 * noir dans la capture : leurs sous-titres ne peuvent pas être lus.
 */
class ScreenCaptureService : Service() {

    companion object {
        const val ACTION_START = "com.voxliso.voxliso.START"
        const val ACTION_STOP = "com.voxliso.voxliso.STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "voxliso_capture"
        private const val NOTIFICATION_ID = 7
        private const val INTERVAL_MS = 400L
        private const val MAX_SIDE = 1600f

        @Volatile var running = false

        /** Vrai quand VoxLiso est au premier plan : on ne lit pas son propre écran. */
        @Volatile var appVisible = false

        /** Reçoit les lignes lues (appelé sur le fil principal). */
        var listener: ((Map<String, Any>) -> Unit)? = null

        /** Prévenu quand la capture s'arrête (bouton « Arrêter », fin d'autorisation…). */
        var onStopped: (() -> Unit)? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var worker: HandlerThread? = null
    private var bg: Handler? = null
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    @Volatile private var busy = false
    private var stopping = false
    private var width = 0
    private var height = 0
    private var density = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCapture()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                // Android 14+ : passer au premier plan AVANT d'obtenir la projection.
                startInForeground()
                val code = intent.getIntExtra(EXTRA_CODE, 0)
                val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_DATA)
                }
                if (data == null) {
                    stopCapture()
                } else {
                    startCapture(code, data)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Lecture de l'écran", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val stop = PendingIntent.getService(
            this, 1, Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP), flags
        )
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("VoxLiso lit les sous-titres de l'écran")
            .setContentText("Touchez pour revenir à VoxLiso")
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Arrêter", stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startCapture(code: Int, data: Intent) {
        val manager = getSystemService(MediaProjectionManager::class.java)
        val mp = try {
            manager.getMediaProjection(code, data)
        } catch (e: Exception) {
            null
        }
        if (mp == null) {
            stopCapture()
            return
        }
        projection = mp
        // Android 14+ : le rappel doit être enregistré avant createVirtualDisplay.
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                main.post { stopCapture() }
            }
        }, main)

        val thread = HandlerThread("voxliso-capture").also { it.start() }
        worker = thread
        val handler = Handler(thread.looper)
        bg = handler

        computeSize()
        val r = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        reader = r
        display = mp.createVirtualDisplay(
            "VoxLiso", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            r.surface, null, handler
        )
        running = true
        handler.postDelayed(tick, INTERVAL_MS)
    }

    /** Taille de la capture : celle de l'écran, réduite à 1600 px de grand côté. */
    private fun computeSize() {
        val wm = getSystemService(WindowManager::class.java)
        val w: Int
        val h: Int
        if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds
            w = b.width()
            h = b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            w = m.widthPixels
            h = m.heightPixels
        }
        val scale = min(1f, MAX_SIDE / max(w, h).toFloat())
        width = max(2, (w * scale).toInt() / 2 * 2)
        height = max(2, (h * scale).toInt() / 2 * 2)
        density = resources.displayMetrics.densityDpi
    }

    /** Toutes les 400 ms : dernière image de l'écran, si elle a changé. */
    private val tick: Runnable = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                analyzeLatest()
            } catch (_: Exception) {
            }
            bg?.postDelayed(this, INTERVAL_MS)
        }
    }

    private fun analyzeLatest() {
        if (busy) return
        val r = reader ?: return
        val image = try {
            r.acquireLatestImage()
        } catch (_: Exception) {
            null
        } ?: return // écran inchangé depuis la dernière analyse
        val bitmap = try {
            if (appVisible) null else toBitmap(image)
        } finally {
            image.close()
        } ?: return

        busy = true
        val w = bitmap.width.toFloat()
        val h = bitmap.height.toFloat()
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                val lines = ArrayList<Map<String, Any>>()
                for (block in text.textBlocks) {
                    for (line in block.lines) {
                        val b = line.boundingBox ?: continue
                        lines.add(
                            mapOf(
                                "text" to line.text,
                                "l" to (b.left / w).toDouble(),
                                "t" to (b.top / h).toDouble(),
                                "r" to (b.right / w).toDouble(),
                                "b" to (b.bottom / h).toDouble(),
                            )
                        )
                    }
                }
                val payload = mapOf<String, Any>(
                    "lines" to lines,
                    "w" to w.toDouble(),
                    "h" to h.toDouble(),
                )
                main.post { listener?.invoke(payload) }
            }
            .addOnCompleteListener { busy = false }
    }

    private fun toBitmap(image: android.media.Image): Bitmap {
        val plane = image.planes[0]
        val pixelStride = plane.pixelStride
        val rowPadding = plane.rowStride - pixelStride * image.width
        val full = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride, image.height, Bitmap.Config.ARGB_8888
        )
        full.copyPixelsFromBuffer(plane.buffer)
        return if (rowPadding != 0) Bitmap.createBitmap(full, 0, 0, image.width, image.height) else full
    }

    /** L'écran a tourné (vidéo en plein écran) : on adapte la capture. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val handler = bg ?: return
        handler.post {
            val vd = display ?: return@post
            val oldW = width
            val oldH = height
            computeSize()
            if (oldW == width && oldH == height) return@post
            val newReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
            vd.resize(width, height, density)
            vd.surface = newReader.surface
            reader?.close()
            reader = newReader
        }
    }

    private fun stopCapture() {
        if (stopping) return
        stopping = true
        running = false
        bg?.removeCallbacksAndMessages(null)
        try {
            display?.release()
        } catch (_: Exception) {
        }
        display = null
        try {
            reader?.close()
        } catch (_: Exception) {
        }
        reader = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null
        worker?.quitSafely()
        worker = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        main.post { onStopped?.invoke() }
        stopSelf()
    }

    override fun onDestroy() {
        stopCapture()
        recognizer.close()
        super.onDestroy()
    }
}
