package com.voxliso.voxliso

import android.app.Activity
import android.app.DownloadManager
import android.app.PendingIntent
import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.content.pm.PackageInstaller
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
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
        private const val REQUEST_NOTIFICATIONS = 4343
        private const val ACTION_INSTALL_STATUS = "com.voxliso.voxliso.INSTALL_STATUS"

        /** Boutons de la notification de lecture : extra « do » = pause, resume, stop. */
        const val ACTION_READING = "com.voxliso.voxliso.READING"
        private const val READING_CHANNEL = "voxliso_reading"
        private const val READING_NOTIFICATION_ID = 8

        private fun readingIntent(context: Context, what: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(ACTION_READING).setPackage(context.packageName).putExtra("do", what),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

        /** Bouton « Pause » ou « Reprendre » (notification de la caméra ou de l'écran). */
        fun pauseAction(context: Context, paused: Boolean): Notification.Action =
            if (paused) {
                Notification.Action.Builder(null, "Reprendre", readingIntent(context, "resume", 11)).build()
            } else {
                Notification.Action.Builder(null, "Pause", readingIntent(context, "pause", 10)).build()
            }
    }

    private var systemChannel: MethodChannel? = null
    private var readingReceiver: BroadcastReceiver? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var notificationsAsked = false

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

        val system = MethodChannel(messenger, "voxliso/system")
        systemChannel = system
        listenReadingButtons()
        listenHeadphones()
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                // Lecture : « reading », « paused » ou « off » (notification avec Pause / Reprendre).
                "setReadingState" -> {
                    applyReadingState(
                        call.argument<String>("state") ?: "off",
                        call.argument<Boolean>("screen") ?: false
                    )
                    result.success(true)
                }
                // Écouteurs (Bluetooth, filaires, USB, appareil auditif) branchés ?
                "headphones" -> result.success(headphonesConnected())
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
                // Bip de cadrage (réglage « Bips pour cadrer la télé »).
                "beep" -> {
                    val hz = call.argument<Double>("hz") ?: 880.0
                    val ms = call.argument<Int>("ms") ?: 80
                    playBeep(hz, ms.coerceIn(20, 500))
                    result.success(true)
                }
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


    /**
     * Son pur de [hz] Hz pendant [ms] ms (fondu de 5 ms au début et à la fin
     * pour éviter les claquements), au volume des médias, comme la voix.
     */
    private fun playBeep(hz: Double, ms: Int) {
        Thread {
            try {
                val rate = 22050
                val n = rate * ms / 1000
                val fade = minOf(n / 4, rate / 200)
                val buf = ShortArray(n)
                for (i in 0 until n) {
                    var amp = 0.35
                    if (i < fade) amp *= i.toDouble() / fade
                    if (i > n - fade) amp *= (n - i).toDouble() / fade
                    buf[i] = (Math.sin(2.0 * Math.PI * hz * i / rate) * amp * Short.MAX_VALUE)
                        .toInt().toShort()
                }
                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .setBufferSizeInBytes(n * 2)
                    .build()
                track.write(buf, 0, n)
                track.play()
                Thread.sleep(ms + 60L)
                track.release()
            } catch (e: Exception) {
                // Pas de son : tant pis, rien d'autre ne dépend du bip.
            }
        }.start()
    }

    // ------------------------------------------------ notification de lecture

    /** Boutons Pause / Reprendre / Arrêter des notifications -> VoxLiso (Dart). */
    private fun listenReadingButtons() {
        if (readingReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val what = intent.getStringExtra("do") ?: return
                systemChannel?.invokeMethod("readingAction", what)
            }
        }
        readingReceiver = r
        val filter = IntentFilter(ACTION_READING)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(r, filter)
        }
    }

    /**
     * Lecture « reading », « paused » ou « off ». Mode écran : la notification du
     * service est mise à jour (et l'analyse suspendue en pause). Mode caméra :
     * VoxLiso affiche sa propre notification avec Pause / Reprendre / Arrêter.
     */
    private fun applyReadingState(state: String, screen: Boolean) {
        val nm = getSystemService(NotificationManager::class.java)
        val paused = state == "paused"
        if (screen) {
            ScreenCaptureService.paused = paused
            ScreenCaptureService.instance?.refreshNotification()
            nm.cancel(READING_NOTIFICATION_ID)
            return
        }
        if (state == "off") {
            nm.cancel(READING_NOTIFICATION_ID)
            return
        }
        askNotificationsOnce()
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(READING_CHANNEL, "Lecture des sous-titres", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, READING_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val n = builder
            .setContentTitle(if (paused) "VoxLiso en pause" else "VoxLiso lit les sous-titres")
            .setContentText("Touchez pour revenir à VoxLiso")
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(pauseAction(this, paused))
            .addAction(Notification.Action.Builder(null, "Arrêter", readingIntent(this, "stop", 12)).build())
            .build()
        try {
            nm.notify(READING_NOTIFICATION_ID, n)
        } catch (e: SecurityException) {
            // Notifications refusées : la lecture continue sans.
        }
    }

    /** Android 13+ : les notifications demandent une autorisation (une fois par lancement). */
    private fun askNotificationsOnce() {
        if (Build.VERSION.SDK_INT < 33 || notificationsAsked) return
        notificationsAsked = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
    }

    // ------------------------------------------------------------ écouteurs

    private val headphoneTypes = buildSet {
        add(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)
        add(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        add(AudioDeviceInfo.TYPE_WIRED_HEADSET)
        add(AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
        add(AudioDeviceInfo.TYPE_USB_HEADSET)
        if (Build.VERSION.SDK_INT >= 28) add(AudioDeviceInfo.TYPE_HEARING_AID)
        if (Build.VERSION.SDK_INT >= 31) add(AudioDeviceInfo.TYPE_BLE_HEADSET)
    }

    private fun headphonesConnected(): Boolean {
        val am = getSystemService(AudioManager::class.java)
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in headphoneTypes }
    }

    /** Écouteurs branchés ou débranchés -> VoxLiso (Dart), pour couper la voix. */
    private fun listenHeadphones() {
        if (deviceCallback != null) return
        val am = getSystemService(AudioManager::class.java)
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = notifyHeadphones()
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = notifyHeadphones()
        }
        deviceCallback = cb
        am.registerAudioDeviceCallback(cb, android.os.Handler(mainLooper))
    }

    private fun notifyHeadphones() {
        systemChannel?.invokeMethod("headphonesChanged", headphonesConnected())
    }

    override fun onDestroy() {
        readingReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        readingReceiver = null
        deviceCallback?.let { getSystemService(AudioManager::class.java).unregisterAudioDeviceCallback(it) }
        deviceCallback = null
        getSystemService(NotificationManager::class.java).cancel(READING_NOTIFICATION_ID)
        if (isFinishing && ScreenCaptureService.running) {
            startService(
                Intent(this, ScreenCaptureService::class.java).setAction(ScreenCaptureService.ACTION_STOP)
            )
        }
        super.onDestroy()
    }
}
