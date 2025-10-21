package com.talia.talia

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.talia.chat.ArFiltersPlugin

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.talia.talia/ringer_mode"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ═══════════════════════════════════════════════════════════════
        // REGISTRAR PLUGIN DE DEEPAR
        // ═══════════════════════════════════════════════════════════════
        flutterEngine.plugins.add(ArFiltersPlugin())

        // ═══════════════════════════════════════════════════════════════
        // RINGER MODE CHANNEL
        // ═══════════════════════════════════════════════════════════════
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isPhoneOnSilent") {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val ringerMode = audioManager.ringerMode

                // RINGER_MODE_SILENT (0) = completamente silencioso
                // RINGER_MODE_VIBRATE (1) = solo vibración
                // RINGER_MODE_NORMAL (2) = sonido normal
                val isSilent = ringerMode == AudioManager.RINGER_MODE_SILENT ||
                               ringerMode == AudioManager.RINGER_MODE_VIBRATE

                result.success(isSilent)
            } else {
                result.notImplemented()
            }
        }
    }
}
