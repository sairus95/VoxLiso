package com.voxliso.voxliso

import android.app.Activity
import android.app.DownloadManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.speech.tts.TextToSpeech
import android.view.WindowManager
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Activité Flutter + canaux vers le service de lecture de l'écran du téléphone.
 *  - « voxliso/screen » : start / stop / isRunning
 *  - « voxliso/screen/lines » : lignes de texte lues à l'écran
 *  - « voxliso/system » : moteurs de voix, réglages de synthèse vocale
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val REQUEST_CAPTURE = 4242
        private const val ACTION_INSTALL_STATUS = "com.voxliso.voxliso.INSTALL_STATUS"
    }

    private var pendingStart: MethodChannel.Result? = null
    private var sink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "voxliso/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= 24)
                "isRunning" -> result.success(ScreenCaptureService.running)
                "setScript" -> {
                    ScreenCaptureService.script = call.argument<String>("script") ?: "latin"
                    result.success(true)
                }
                "start" -> {
                    if (ScreenCaptureService.running) {
                        result.success(true)
                    } else {
                        pendingStart?.success(false)
                        pendingStart = result
                        val manager = getSystemService(MediaProjectionManager::class.java)
                        try {
                            startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE)
                        } catch (e: Exception) {
                            pendingStart = null
                            result.success(false)
                        }
                    }
                }
                "stop" -> {
                    if (ScreenCaptureService.running) {
                        startService(
                            Intent(this, ScreenCaptureService::class.java)
                                .setAction(ScreenCaptureService.ACTION_STOP)
                        )
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "voxliso/system").setMethodCallHandler { call, result ->
            when (call.method) {
                // Moteurs de synthèse vocale installés : [{name, label}].
                "ttsEngines" -> {
                    var tts: TextToSpeech? = null
                    try {
                        tts = TextToSpeech(applicationContext) { }
                        val list = tts.engines.map { mapOf("name" to it.name, "label" to it.label) }
                        result.success(list)
                    } catch (e: Exception) {
                        result.success(emptyList<Map<String, String>>())
                    } finally {
                        try {
                            tts?.shutdown()
                        } catch (_: Exception) {
                        }
                    }
                }
                // Écran du téléphone pour télécharger d'autres voix.
                "installVoices" -> {
                    val engine = call.argument<String>("engine")
                    val install = Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (!engine.isNullOrEmpty()) install.setPackage(engine)
                    val settings = Intent("com.android.settings.TTS_SETTINGS")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    result.success(
                        listOf(install, settings).any { intent ->
                            try {
                                startActivity(intent)
                                true
                            } catch (_: Exception) {
                                false
                            }
                        }
                    )
                }
                // Traducteur du téléphone : réseau sans limite (Wi-Fi) pour
                // télécharger les langues, et dossier privé des modèles.
                "isUnmetered" -> {
                    val cm = getSystemService(ConnectivityManager::class.java)
                    val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
                    result.success(
                        caps != null &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                    )
                }
                "filesDir" -> result.success(filesDir.absolutePath)
                // Luminosité de l'écran pour VoxLiso seulement (-1 = celle du téléphone).
                "setBrightness" -> {
                    val value = call.argument<Double>("value") ?: -1.0
                    val lp = window.attributes
                    lp.screenBrightness = if (value < 0) {
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    } else {
                        value.toFloat().coerceIn(0.01f, 1f)
                    }
                    window.attributes = lp
                    result.success(true)
                }
                // Mise à jour : téléchargement confié au gestionnaire de téléchargements
                // d'Android (continue écran éteint, reprend après une coupure de réseau).
                "startDownload" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name") ?: "VoxLiso.apk"
                    val title = call.argument<String>("title") ?: "VoxLiso"
                    result.success(if (url == null) -1L else startDownload(url, name, title))
                }
                "downloadStatus" -> {
                    val id = call.argument<Number>("id")?.toLong() ?: -1L
                    result.success(downloadStatus(id))
                }
                "removeDownload" -> {
                    val id = call.argument<Number>("id")?.toLong() ?: -1L
                    result.success(
                        try {
                            if (id >= 0) downloads().remove(id)
                            true
                        } catch (_: Exception) {
                            false
                        }
                    )
                }
                // Mise à jour : installe l'APK téléchargé (Android demande confirmation).
                "installApk" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && installApk(File(path)))
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    result.success(
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            true
                        } catch (_: Exception) {
                            false
                        }
                    )
                }
                // Réglages de synthèse vocale d'Android (moteur par défaut, voix).
                "openTtsSettings" -> {
                    result.success(
                        try {
                            startActivity(
                                Intent("com.android.settings.TTS_SETTINGS")
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            true
                        } catch (_: Exception) {
                            false
                        }
                    )
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "voxliso/screen/lines").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    ScreenCaptureService.listener = { payload -> sink?.success(payload) }
                    ScreenCaptureService.onStopped = { sink?.success(mapOf("stopped" to true)) }
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    ScreenCaptureService.listener = null
                    ScreenCaptureService.onStopped = null
                }
            }
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CAPTURE) return
        val result = pendingStart
        pendingStart = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            val intent = Intent(this, ScreenCaptureService::class.java)
                .setAction(ScreenCaptureService.ACTION_START)
                .putExtra(ScreenCaptureService.EXTRA_CODE, resultCode)
                .putExtra(ScreenCaptureService.EXTRA_DATA, data)
            try {
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                result?.success(true)
            } catch (e: Exception) {
                result?.success(false)
            }
        } else {
            result?.success(false)
        }
    }

    private fun downloads() = getSystemService(DOWNLOAD_SERVICE) as DownloadManager

    /**
     * Lance le téléchargement de l'APK dans le dossier de l'application
     * (Android/data/…/files/Download), avec une notification de progression.
     * Renvoie le numéro du téléchargement, ou -1.
     */
    private fun startDownload(url: String, name: String, title: String): Long {
        return try {
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: return -1L
            // Anciens fichiers de mise à jour : inutile de les garder (≈ 130 Mo chacun).
            dir.listFiles()?.filter { it.name.endsWith(".apk") }?.forEach { it.delete() }
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(title)
                .setDescription("Mise à jour de VoxLiso")
                .setMimeType("application/vnd.android.package-archive")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, name)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(false)
                .addRequestHeader("User-Agent", "VoxLiso")
            downloads().enqueue(request)
        } catch (_: Exception) {
            -1L
        }
    }

    /** État d'un téléchargement : status, octets reçus / total, raison, chemin du fichier. */
    private fun downloadStatus(id: Long): Map<String, Any?> {
        try {
            downloads().query(DownloadManager.Query().setFilterById(id))?.use { c ->
                if (!c.moveToFirst()) return mapOf("status" to "missing")
                val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val local = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                return mapOf(
                    "status" to when (status) {
                        DownloadManager.STATUS_SUCCESSFUL -> "success"
                        DownloadManager.STATUS_FAILED -> "failed"
                        DownloadManager.STATUS_PAUSED -> "paused"
                        DownloadManager.STATUS_PENDING -> "pending"
                        else -> "running"
                    },
                    "downloaded" to c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                    "total" to c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                    "reason" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                    "path" to local?.let { Uri.parse(it).path },
                )
            }
        } catch (_: Exception) {
        }
        return mapOf("status" to "missing")
    }

    /** Installe un APK avec PackageInstaller ; le résultat revient dans onNewIntent. */
    private fun installApk(file: File): Boolean {
        return try {
            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("VoxLiso.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val status = Intent(this, MainActivity::class.java)
                    .setAction(ACTION_INSTALL_STATUS)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val flags = if (Build.VERSION.SDK_INT >= 31) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pending = PendingIntent.getActivity(this, sessionId, status, flags)
                session.commit(pending.intentSender)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != ACTION_INSTALL_STATUS) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // Fenêtre d'Android « Mettre à jour cette application ? ».
            val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            confirm?.let {
                try {
                    startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        ScreenCaptureService.appVisible = true
    }

    override fun onPause() {
        ScreenCaptureService.appVisible = false
        super.onPause()
    }

    override fun onDestroy() {
        if (isFinishing && ScreenCaptureService.running) {
            startService(
                Intent(this, ScreenCaptureService::class.java).setAction(ScreenCaptureService.ACTION_STOP)
            )
        }
        super.onDestroy()
    }
}
