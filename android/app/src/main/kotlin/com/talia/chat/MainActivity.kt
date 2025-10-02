package com.talia.chat

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private val arFiltersPlugin = ArFiltersPlugin()

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
    }
}
