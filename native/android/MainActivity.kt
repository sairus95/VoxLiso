package com.voxliso.voxliso

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Activité Flutter + canaux vers le service de lecture de l'écran du téléphone.
 *  - « voxliso/screen » : start / stop / isRunning
 *  - « voxliso/screen/lines » : lignes de texte lues à l'écran
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val REQUEST_CAPTURE = 4242
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
