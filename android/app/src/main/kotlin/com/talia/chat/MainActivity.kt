package com.talia.chat

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private val arFiltersPlugin = ArFiltersPlugin()
    private val CHANNEL = "com.talia.chat/notifications"
    private var startIntent: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Cambiar el tema ANTES de llamar a super.onCreate()
        // Esto determina qué splash se muestra (con imagen o sin imagen)
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val hasSeenSplash = prefs.getBoolean("flutter.has_seen_splash", false)

        if (hasSeenSplash) {
            // Ya vio el splash - usar tema sin splash
            setTheme(R.style.LaunchThemeNoSplash)
            Log.d("MainActivity", "🚫 Splash deshabilitado - no es primera vez")
        } else {
            // Primera vez - usar tema con splash
            setTheme(R.style.LaunchTheme)
            Log.d("MainActivity", "🎬 Splash habilitado - primera vez")
        }

        super.onCreate(savedInstanceState)

        // ✅ Guardar intent inicial para procesarlo cuando Flutter esté listo
        startIntent = intent
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // ✅ Manejar intent cuando la app ya está abierta
        handleIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        Log.d("MainActivity", "🔧 Configurando ArFiltersPlugin manualmente...")

        // Configurar Method Channel
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "talia.deepar/ar_filters")
        methodChannel.setMethodCallHandler(arFiltersPlugin)

        // Configurar Event Channel
        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "talia.deepar/ar_events")
        eventChannel.setStreamHandler(arFiltersPlugin)

        // Registrar Platform View Factory directamente
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "talia.deepar/ar_preview",
            DeepARPreviewFactory(arFiltersPlugin)
        )

        // Configurar context y activity en el plugin
        arFiltersPlugin.context = applicationContext
        arFiltersPlugin.activity = this

        Log.d("MainActivity", "✅ ArFiltersPlugin configurado")

        // ✅ Configurar MethodChannel para notificaciones
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialNotification" -> {
                    val data = extractIntentData(startIntent)
                    if (data != null) {
                        Log.d("MainActivity", "📦 Enviando datos iniciales a Flutter: $data")
                        result.success(data)
                        // Limpiar para no enviar múltiples veces
                        startIntent = null
                    } else {
                        Log.d("MainActivity", "ℹ️ No hay datos iniciales de notificación")
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ✅ Procesar intent inicial si existe
        startIntent?.let { intent ->
            handleIntent(intent)
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return

        val data = extractIntentData(intent)
        if (data != null) {
            Log.d("MainActivity", "📨 Intent con datos de notificación recibido: $data")
            // Los datos se enviarán cuando Flutter llame a getInitialNotification
        }
    }

    private fun extractIntentData(intent: Intent?): Map<String, String>? {
        if (intent == null || !intent.hasExtra("chatId")) {
            return null
        }

        val data = mutableMapOf<String, String>()
        intent.extras?.keySet()?.forEach { key ->
            val value = intent.getStringExtra(key)
            if (value != null) {
                data[key] = value
            }
        }

        return if (data.isNotEmpty()) data else null
    }
}
