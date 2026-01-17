package com.talia.chat

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import ai.deepar.ar.CameraResolutionPreset
import ai.deepar.ar.DeepAR
import ai.deepar.ar.DeepARImageFormat
import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import java.io.ByteArrayOutputStream
import java.io.File
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * Plugin Android para DeepAR
 * Maneja la integración con el SDK de DeepAR para filtros AR en tiempo real
 */
class ArFiltersPlugin : FlutterPlugin, MethodCallHandler, StreamHandler, ActivityAware {
    companion object {
        private const val TAG = "ArFiltersPlugin"
        private const val METHOD_CHANNEL = "talia.deepar/ar_filters"
        private const val EVENT_CHANNEL = "talia.deepar/ar_events"
    }

    internal lateinit var context: Context
    internal var activity: Activity? = null
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Estado del plugin
    private var isInitialized = false
    private var currentFilter: String? = null
    private var isRecording = false
    internal var isCaptureStarted = false

    // DeepAR instance
    internal var deepAR: DeepAR? = null

    // ARView instance (mantener una sola instancia como en iOS)
    internal var currentARView: SurfaceView? = null

    // Camera controller (similar a iOS)
    internal var cameraController: DeepARCameraController? = null

    // Camera settings
    private var defaultLensFacing = CameraResolutionPreset.P1280x720

    // Pending screenshot result
    private var pendingScreenshotResult: Result? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext

        // Configurar method channel
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        // Configurar event channel
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)

        // Registrar el factory para la vista nativa DeepARPreview
        Log.d(TAG, "🔧 Registrando factory DeepARPreview...")
        flutterPluginBinding
            .platformViewRegistry
            .registerViewFactory("talia.deepar/ar_preview", DeepARPreviewFactory(this))
        Log.d(TAG, "✅ Factory DeepARPreview registrado")

        Log.d(TAG, "✅ ArFiltersPlugin registrado en Android")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        Log.d(TAG, "📞 Método llamado: ${call.method}")

        when (call.method) {
            "initialize" -> handleInitialize(call, result)
            "switchFilter" -> handleSwitchFilter(call, result)
            "startRecording" -> handleStartRecording(call, result)
            "stopRecording" -> handleStopRecording(call, result)
            "takeScreenshot" -> handleTakeScreenshot(call, result)
            "switchCamera" -> handleSwitchCamera(call, result)
            "getAvailableFilters" -> handleGetAvailableFilters(call, result)
            "pause" -> handlePause(call, result)
            "resume" -> handleResume(call, result)
            "startCamera" -> handleStartCamera(call, result)
            "stopCamera" -> handleStopCamera(call, result)
            "dispose" -> handleDispose(call, result)
            else -> {
                Log.w(TAG, "⚠️ Método no implementado: ${call.method}")
                result.notImplemented()
            }
        }
    }

    // MARK: - Method Implementations
    private fun handleInitialize(call: MethodCall, result: Result) {
        val licenseKey = call.argument<String>("licenseKey")

        if (licenseKey.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENTS", "License key es requerida", null)
            return
        }

        Log.d(TAG, "🎭 Inicializando DeepAR con license key: ${licenseKey.take(10)}...")

        try {
            // ✅ FIX: Si DeepAR ya está inicializado, solo despausarlo
            // No crear nueva instancia porque el SDK no se reinicializa correctamente
            if (deepAR != null && isInitialized) {
                Log.d(TAG, "♻️ DeepAR ya inicializado, reutilizando instancia existente")
                deepAR?.setPaused(false)
                Log.d(TAG, "▶️ DeepAR despausado")

                // Limpiar filtro actual para empezar limpio
                deepAR?.switchEffect("effect", "")
                currentFilter = null
                Log.d(TAG, "🧹 Filtro actual limpiado")

                // Enviar evento de inicialización
                sendEvent("initialized", mapOf("success" to true, "reused" to true))
                result.success(true)
                return
            }

            // Crear instancia de DeepAR si no existe
            if (deepAR == null) {
                deepAR = DeepAR(context)
                Log.d(TAG, "✅ DeepAR instance creada (nueva)")
            }

            deepAR?.setLicenseKey(licenseKey)
            Log.d(TAG, "✅ License key configurada")

            // CRÍTICO: Inicializar DeepAR para que configure su Handler interno
            // Sin esto, startCapture() falla con NullPointerException
            // IMPORTANTE: Usar Activity context, no Application context
            val activityContext = activity ?: context
            deepAR?.initialize(activityContext, null)
            Log.d(TAG, "✅ DeepAR initialize() llamado con ${if (activity != null) "Activity" else "Application"} context")

            // Ocultar logo/watermark de DeepAR
            deepAR?.showStats(false)
            Log.d(TAG, "✅ Logo de DeepAR ocultado")

            // Configurar listeners usando helper de Java
            DeepARHelper.setAREventListener(deepAR) { event, data ->
                when (event) {
                    "screenshotTaken" -> {
                        Log.d(TAG, "📸 Screenshot tomado en callback")
                        // Obtener bitmap del callback
                        val bitmap = data["bitmap"] as? Bitmap
                        if (bitmap != null && pendingScreenshotResult != null) {
                            Log.d(TAG, "✅ Screenshot recibido, convirtiendo a bytes...")
                            try {
                                // Convertir bitmap a byte array
                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                                val byteArray = stream.toByteArray()
                                stream.close()

                                Log.d(TAG, "✅ Screenshot convertido: ${byteArray.size} bytes")
                                pendingScreenshotResult?.success(byteArray)
                                pendingScreenshotResult = null
                            } catch (e: Exception) {
                                Log.e(TAG, "❌ Error procesando screenshot: ${e.message}", e)
                                pendingScreenshotResult?.error("SCREENSHOT_ERROR", "Error procesando screenshot: ${e.message}", null)
                                pendingScreenshotResult = null
                            }
                        } else {
                            Log.w(TAG, "⚠️ Screenshot callback sin bitmap o sin result pendiente")
                            pendingScreenshotResult?.error("SCREENSHOT_ERROR", "No se recibió bitmap", null)
                            pendingScreenshotResult = null
                        }
                    }
                    "recordingStarted" -> {
                        Log.d(TAG, "🎬 Grabación iniciada")
                        isRecording = true
                    }
                    "recordingStopped" -> {
                        Log.d(TAG, "⏹️ Grabación finalizada")
                        isRecording = false
                    }
                    "initialized" -> {
                        Log.d(TAG, "✅ DeepAR inicializado (callback)")
                        isInitialized = true
                        // No reiniciar la cámara aquí - surfaceCreated se encargará de eso
                    }
                    "filterChanged" -> {
                        Log.d(TAG, "🔄 Efecto cambiado: ${data["filterPath"]}")
                        currentFilter = data["filterPath"] as? String
                    }
                    "error" -> {
                        Log.e(TAG, "❌ Error DeepAR: ${data["type"]} - ${data["message"]}")
                        if (data["message"] == "Video recording failed") {
                            isRecording = false
                        }
                    }
                }
                sendEvent(event, data.toMap())
            }

            // Marcar como inicializado inmediatamente
            isInitialized = true
            Log.d(TAG, "⚡ isInitialized establecido a true")

            // Enviar evento
            sendEvent("initialized", mapOf("success" to true))

            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error inicializando DeepAR: ${e.message}", e)
            result.error("DEEPAR_INIT_ERROR", "Error inicializando DeepAR: ${e.message}", null)
        }
    }

    private fun handleSwitchFilter(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null) {
            result.error("NOT_INITIALIZED", "DeepAR no está inicializado", null)
            return
        }

        val filterPath = call.argument<String>("filterPath") ?: ""

        try {
            Log.d(TAG, "🔄 Cambiando filtro: $filterPath")

            if (filterPath.isEmpty()) {
                // Remover filtro actual
                deepAR?.switchEffect("effect", "")
                currentFilter = null
                Log.d(TAG, "✅ Filtro removido")
            } else {
                // Aplicar filtro desde assets
                val fullPath = "file:///android_asset/$filterPath"
                deepAR?.switchEffect("effect", fullPath)
                currentFilter = filterPath
                Log.d(TAG, "✅ Filtro aplicado: $filterPath")
            }

            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error cambiando filtro: ${e.message}", e)
            result.error("FILTER_ERROR", "Error cambiando filtro: ${e.message}", null)
        }
    }

    private fun handleStartRecording(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null) {
            result.error("NOT_INITIALIZED", "DeepAR no está inicializado", null)
            return
        }

        val outputPath = call.argument<String>("outputPath")
        val width = call.argument<Int>("width") ?: 1280
        val height = call.argument<Int>("height") ?: 720
        val bitRate = call.argument<Int>("bitRate") ?: 4000000

        if (outputPath.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENTS", "outputPath es requerido", null)
            return
        }

        try {
            Log.d(TAG, "🎬 Iniciando grabación: $outputPath")

            // ✅ CRÍTICO: Verificar permiso de audio antes de iniciar grabación
            // DeepAR requiere RECORD_AUDIO para video recording y falla con AudioRecord errors si no está disponible
            val hasAudioPermission = ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED

            if (!hasAudioPermission) {
                Log.e(TAG, "❌ Permiso RECORD_AUDIO no otorgado - DeepAR fallará con AudioRecord errors")
                result.error("AUDIO_PERMISSION_DENIED",
                    "Permiso de micrófono requerido para grabar video con DeepAR. " +
                    "Por favor otorga el permiso en configuración de la app.", null)
                return
            }

            Log.d(TAG, "✅ Permiso RECORD_AUDIO verificado - procediendo con grabación")

            val outputFile = File(outputPath)
            outputFile.parentFile?.mkdirs()

            deepAR?.startVideoRecording(outputPath, width, height)

            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error iniciando grabación: ${e.message}", e)
            result.error("RECORDING_ERROR", "Error iniciando grabación: ${e.message}", null)
        }
    }

    private fun handleStopRecording(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null || !isRecording) {
            result.error("NOT_RECORDING", "No hay grabación en progreso", null)
            return
        }

        try {
            Log.d(TAG, "⏹️ Deteniendo grabación")
            deepAR?.stopVideoRecording()
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error deteniendo grabación: ${e.message}", e)
            result.error("RECORDING_ERROR", "Error deteniendo grabación: ${e.message}", null)
        }
    }

    private fun handleTakeScreenshot(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null) {
            result.error("NOT_INITIALIZED", "DeepAR no está inicializado", null)
            return
        }

        try {
            Log.d(TAG, "📸 Solicitando screenshot de DeepAR...")

            // Guardar el result para usar en el callback
            pendingScreenshotResult = result

            // Llamar a takeScreenshot - el resultado llegará en el callback screenshotTaken
            deepAR?.takeScreenshot()

            Log.d(TAG, "📸 Esperando callback de screenshot...")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error tomando screenshot: ${e.message}", e)
            pendingScreenshotResult = null
            result.error("SCREENSHOT_ERROR", "Error tomando screenshot: ${e.message}", null)
        }
    }

    private fun handleSwitchCamera(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null) {
            result.error("NOT_INITIALIZED", "DeepAR no está inicializado", null)
            return
        }

        try {
            Log.d(TAG, "🔄 Cambiando cámara")

            if (cameraController == null) {
                Log.e(TAG, "❌ CameraController es null, no se puede cambiar cámara")
                result.error("CAMERA_ERROR", "CameraController no inicializado", null)
                return
            }

            // Usar camera controller para cambiar cámara
            cameraController?.switchCamera()
            Log.d(TAG, "✅ Cámara cambiada exitosamente")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error cambiando cámara: ${e.message}", e)
            result.error("CAMERA_ERROR", "Error cambiando cámara: ${e.message}", null)
        }
    }

    private fun handleGetAvailableFilters(call: MethodCall, result: Result) {
        // Retornar lista de filtros disponibles en assets
        val filters = listOf<String>() // TODO: Leer de assets
        result.success(filters)
    }

    private fun handlePause(call: MethodCall, result: Result) {
        if (deepAR != null) {
            Log.d(TAG, "⏸️ Pausando DeepAR")
            deepAR?.setPaused(true)
        }
        result.success(null)
    }

    private fun handleResume(call: MethodCall, result: Result) {
        if (deepAR != null) {
            Log.d(TAG, "▶️ Reanudando DeepAR")
            deepAR?.setPaused(false)
        }
        result.success(null)
    }

    private fun handleStartCamera(call: MethodCall, result: Result) {
        if (!isInitialized || deepAR == null) {
            result.error("NOT_INITIALIZED", "DeepAR no está inicializado", null)
            return
        }

        try {
            Log.d(TAG, "▶️ startCamera llamado")

            // Despausar DeepAR si estaba pausado
            deepAR?.setPaused(false)

            // Si el camera controller existe y no está capturando, reiniciar
            if (cameraController != null && !isCaptureStarted) {
                Log.d(TAG, "🔄 Reiniciando camera controller...")
                cameraController?.startCamera()
                isCaptureStarted = true
            } else if (isCaptureStarted) {
                Log.d(TAG, "✅ Cámara ya estaba iniciada, solo despausada")
            } else {
                Log.d(TAG, "ℹ️ Esperando a que la superficie esté lista...")
            }

            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error iniciando cámara: ${e.message}", e)
            result.error("CAMERA_ERROR", "Error iniciando cámara: ${e.message}", null)
        }
    }

    private fun handleStopCamera(call: MethodCall, result: Result) {
        if (deepAR != null) {
            Log.d(TAG, "⏹️ Deteniendo cámara DeepAR")
            deepAR?.setPaused(true)
            // Detener el camera controller
            cameraController?.stopCamera()
            // CRÍTICO: Resetear flag para permitir reiniciar la cámara
            isCaptureStarted = false
            Log.d(TAG, "🔄 isCaptureStarted reseteado a false")
        }
        result.success(null)
    }

    private fun handleDispose(call: MethodCall, result: Result) {
        try {
            Log.d(TAG, "🗑️ Disposing DeepAR resources (manteniendo SDK vivo)")

            if (isRecording) {
                deepAR?.stopVideoRecording()
                isRecording = false
            }

            // ✅ FIX: Detener la cámara pero NO liberar DeepAR
            // El SDK de DeepAR no se reinicializa correctamente después de release()
            // Mantenerlo vivo permite reutilizarlo en la próxima sesión
            cameraController?.stopCamera()
            cameraController = null
            Log.d(TAG, "⏹️ Camera controller detenido y limpiado")

            // Pausar DeepAR pero NO liberarlo
            deepAR?.setPaused(true)
            Log.d(TAG, "⏸️ DeepAR pausado (NO liberado)")

            // Limpiar la superficie de renderizado actual
            try {
                deepAR?.setRenderSurface(null, 0, 0)
                Log.d(TAG, "🧹 Superficie de renderizado limpiada")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error limpiando superficie: ${e.message}")
            }

            // NO liberar DeepAR - mantenerlo para reutilización
            // deepAR?.release()  // ❌ COMENTADO
            // deepAR = null      // ❌ COMENTADO

            currentARView = null
            // isInitialized = false  // ❌ MANTENER true para reutilización
            currentFilter = null
            isCaptureStarted = false

            Log.d(TAG, "✅ Dispose completado (DeepAR sigue vivo, isInitialized=$isInitialized)")
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error disposing: ${e.message}", e)
            result.error("DISPOSE_ERROR", "Error disposing: ${e.message}", null)
        }
    }

    // MARK: - Event Channel
    override fun onListen(arguments: Any?, events: EventSink?) {
        eventSink = events
        Log.d(TAG, "📡 Event stream iniciado")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        Log.d(TAG, "📡 Event stream cancelado")
    }

    private fun sendEvent(type: String, data: Map<String, Any>) {
        // Filtrar el bitmap del mapa de datos si existe
        // Flutter no puede serializar objetos Bitmap
        val filteredData = data.filterKeys { key ->
            val value = data[key]
            value !is Bitmap && value !is android.graphics.Bitmap
        }

        val event = mapOf(
            "type" to type,
            "data" to filteredData,
            "timestamp" to System.currentTimeMillis()
        )

        // CRÍTICO: Enviar eventos desde el main thread
        // DeepAR callbacks pueden venir de threads background
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    // MARK: - ActivityAware Implementation
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        Log.d(TAG, "✅ Activity attached to plugin")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}

/**
 * Factory para crear la vista nativa DeepARPreview
 */
class DeepARPreviewFactory(private val plugin: ArFiltersPlugin) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        Log.d("DeepARPreviewFactory", "🏭 create() llamado - creando DeepARPlatformView con viewId: $viewId")
        return DeepARPlatformView(context, viewId, plugin)
    }
}

/**
 * Vista nativa para mostrar el preview de DeepAR
 */
class DeepARPlatformView(
    private val context: Context,
    private val viewId: Int,
    private val plugin: ArFiltersPlugin
) : PlatformView {

    private val TAG = "DeepARPlatformView"
    private var container: FrameLayout
    private var surfaceView: SurfaceView? = null

    private var retryCount = 0
    private val maxRetries = 10  // Aumentado de 3 a 10 para dispositivos lentos
    private var initializationHandler: Handler? = null

    init {
        Log.d(TAG, "🎯 Configurando DeepAR view (viewId: $viewId)")
        Log.i("flutter", "📱 [ANDROID] DeepARPlatformView init - viewId: $viewId")
        container = FrameLayout(context)
        container.setBackgroundColor(android.graphics.Color.BLACK)  // Fondo negro mientras carga

        val deepAR = plugin.deepAR
        if (deepAR == null) {
            Log.e(TAG, "❌ DeepAR no está disponible")
            Log.e("flutter", "📱 [ANDROID] ERROR: DeepAR no disponible")
            showErrorView("DeepAR no disponible.\nReintentando...")
        } else {
            // En Android, siempre crear nuevo SurfaceView para evitar problemas con surfaces inválidos
            // (iOS puede reutilizar porque UIView funciona diferente)
            Log.d(TAG, "🎭 Creando SurfaceView nuevo...")
            Log.i("flutter", "📱 [ANDROID] Creando SurfaceView para DeepAR")
            val arView = SurfaceView(context)

            // Configurar surface holder
            arView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    val width = holder.surfaceFrame.width()
                    val height = holder.surfaceFrame.height()
                    Log.d(TAG, "✅ Surface creada: ${width}x${height}")
                    Log.i("flutter", "📱 [ANDROID] ✅ Surface creada: ${width}x${height}")

                    try {
                        // CRÍTICO: Verificar que las dimensiones son válidas
                        if (width <= 0 || height <= 0) {
                            Log.e(TAG, "❌ Dimensiones de surface inválidas: ${width}x${height}")
                            Log.e("flutter", "📱 [ANDROID] ❌ Dimensiones inválidas: ${width}x${height}")
                            Log.e(TAG, "   → Esperando dimensiones válidas...")
                            return
                        }

                        // CRÍTICO: Configurar la superficie de renderizado
                        deepAR.setRenderSurface(holder.surface, width, height)
                        Log.d(TAG, "✅ Superficie de renderizado configurada: ${width}x${height}")
                        Log.i("flutter", "📱 [ANDROID] ✅ Superficie configurada: ${width}x${height}")

                        // CRÍTICO: Despausar DeepAR cuando se recrea la superficie
                        deepAR.setPaused(false)
                        Log.d(TAG, "▶️ DeepAR despausado")
                        Log.i("flutter", "📱 [ANDROID] ▶️ DeepAR despausado")

                        // CRÍTICO: Iniciar la cámara con reintentos
                        initializeCameraWithRetry(deepAR)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error configurando surface: ${e.message}", e)
                        Log.e("flutter", "📱 [ANDROID] ❌ Error configurando surface: ${e.message}")
                        e.printStackTrace()
                    }
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    Log.d(TAG, "🔄 Surface cambió: ${width}x${height}")
                    Log.i("flutter", "📱 [ANDROID] 🔄 Surface cambió: ${width}x${height}")
                    try {
                        deepAR.setRenderSurface(holder.surface, width, height)
                        // CRÍTICO: Despausar DeepAR también cuando cambia la superficie
                        deepAR.setPaused(false)
                        Log.d(TAG, "▶️ DeepAR despausado después de cambio de superficie")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error actualizando surface: ${e.message}", e)
                        Log.e("flutter", "📱 [ANDROID] ❌ Error actualizando surface: ${e.message}")
                    }
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    Log.d(TAG, "⏹️ Surface destruida")
                    Log.i("flutter", "📱 [ANDROID] ⏹️ Surface destruida")
                    try {
                        // Cancelar cualquier reintento pendiente
                        initializationHandler?.removeCallbacksAndMessages(null)
                        initializationHandler = null
                        retryCount = 0

                        // CRÍTICO: Limpiar la superficie de renderizado de DeepAR
                        deepAR.setRenderSurface(null, 0, 0)
                        Log.d(TAG, "🧹 Superficie de renderizado limpiada")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error limpiando superficie: ${e.message}", e)
                        Log.e("flutter", "📱 [ANDROID] ❌ Error limpiando superficie: ${e.message}")
                    }
                    // CRÍTICO: Resetear flag para permitir reiniciar cuando se recree la superficie
                    plugin.isCaptureStarted = false
                    Log.d(TAG, "🔄 isCaptureStarted reseteado a false por destrucción de superficie")
                    Log.i("flutter", "📱 [ANDROID] 🔄 isCaptureStarted = false")
                }
            })

            surfaceView = arView
            plugin.currentARView = arView
            Log.d(TAG, "✅ Vista de DeepAR creada")
            Log.i("flutter", "📱 [ANDROID] ✅ Vista de DeepAR creada")

            // Agregar al contenedor
            val layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            container.addView(arView, layoutParams)
            Log.d(TAG, "✅ SurfaceView configurado en contenedor")
            Log.i("flutter", "📱 [ANDROID] ✅ SurfaceView agregado al contenedor")
        }
    }

    private fun initializeCameraWithRetry(deepAR: DeepAR) {
        Log.i("flutter", "📱 [ANDROID] 📷 initializeCameraWithRetry - intento ${retryCount + 1}/$maxRetries")

        if (initializationHandler == null) {
            initializationHandler = Handler(Looper.getMainLooper())
        }

        // Incrementar delay con cada reintento: 500ms, 1000ms, 1500ms
        val delayMs = 500L + (retryCount * 500L)

        initializationHandler?.postDelayed({
            try {
                if (plugin.isCaptureStarted) {
                    Log.i("flutter", "📱 [ANDROID] ✅ Cámara ya iniciada, saltando")
                    return@postDelayed
                }

                Log.i("flutter", "📱 [ANDROID] 🔍 Verificando Activity (delay: ${delayMs}ms)...")

                val activity = plugin.activity
                if (activity == null) {
                    Log.e("flutter", "📱 [ANDROID] ❌ Activity es null (intento ${retryCount + 1}/$maxRetries)")

                    if (retryCount < maxRetries) {
                        retryCount++
                        Log.i("flutter", "📱 [ANDROID] 🔄 Reintentando inicialización de cámara en ${500L + (retryCount * 500L)}ms...")
                        initializeCameraWithRetry(deepAR)
                    } else {
                        Log.e("flutter", "📱 [ANDROID] ❌ Máximo de reintentos alcanzado - Activity sigue null")
                        Handler(Looper.getMainLooper()).post {
                            showErrorView("Error: No se pudo acceder a la cámara.\nPor favor, reinicia la aplicación.\n\n(Activity no disponible)")
                        }
                    }
                    return@postDelayed
                }

                if (activity !is androidx.lifecycle.LifecycleOwner) {
                    Log.e("flutter", "📱 [ANDROID] ❌ Activity no implementa LifecycleOwner")
                    Handler(Looper.getMainLooper()).post {
                        showErrorView("Error: Activity no compatible.\nPor favor, reinicia la aplicación.")
                    }
                    return@postDelayed
                }

                Log.i("flutter", "📱 [ANDROID] ✅ Activity disponible, creando CameraController...")

                // Crear camera controller si no existe
                if (plugin.cameraController == null) {
                    Log.i("flutter", "📱 [ANDROID] 🎥 Creando nuevo CameraController...")
                    plugin.cameraController = DeepARCameraController(
                        context,
                        deepAR,
                        activity
                    )
                }

                // Iniciar cámara
                Log.i("flutter", "📱 [ANDROID] 🚀 Llamando a cameraController.startCamera()...")
                plugin.cameraController?.startCamera()
                plugin.isCaptureStarted = true
                retryCount = 0  // Reset en caso de éxito
                Log.i("flutter", "📱 [ANDROID] ✅ CameraController iniciado exitosamente")
                Log.d(TAG, "✅ CameraController iniciado - frames siendo enviados a DeepAR")
            } catch (e: Exception) {
                Log.e("flutter", "📱 [ANDROID] ❌ Error inicializando cámara: ${e.message}")
                Log.e(TAG, "❌ Error en initializeCameraWithRetry: ${e.message}", e)

                if (retryCount < maxRetries) {
                    retryCount++
                    Log.i("flutter", "📱 [ANDROID] 🔄 Reintentando después de error...")
                    initializeCameraWithRetry(deepAR)
                }
            }
        }, delayMs)
    }

    private fun showErrorView(message: String) {
        // Limpiar contenedor primero
        container.removeAllViews()

        val textView = android.widget.TextView(context)
        textView.text = message
        textView.setTextColor(android.graphics.Color.WHITE)
        textView.setBackgroundColor(android.graphics.Color.parseColor("#CC000000"))  // Fondo negro semi-transparente
        textView.gravity = android.view.Gravity.CENTER
        textView.textSize = 16f
        textView.setPadding(40, 40, 40, 40)

        container.addView(textView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        Log.e(TAG, "💥 Error mostrado al usuario: $message")
    }

    override fun getView(): android.view.View = container

    override fun dispose() {
        Log.d(TAG, "🗑️ DeepARPlatformView dispose")
        try {
            // Remover SurfaceView del contenedor para evitar race conditions con Flutter
            surfaceView?.let { sv ->
                container.removeView(sv)
                Log.d(TAG, "✅ SurfaceView removido del contenedor")
            }
            surfaceView = null
        } catch (e: Exception) {
            Log.e(TAG, "⚠️ Error en dispose: ${e.message}", e)
        }
    }
}
