package com.talia.chat

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import ai.deepar.ar.DeepAR
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Controlador de cámara para Android que alimenta frames a DeepAR
 * Similar al CameraController de iOS
 */
class DeepARCameraController(
    private val context: Context,
    private val deepAR: DeepAR,
    private val lifecycleOwner: LifecycleOwner
) {
    companion object {
        private const val TAG = "DeepARCameraController"
    }

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageAnalyzer: ImageAnalysis? = null
    private var cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Intentar cámara frontal por defecto, pero será ajustado según disponibilidad
    private var lensFacing = CameraSelector.LENS_FACING_FRONT
    private var hasDetectedCameras = false

    // Bandera para controlar si debemos procesar frames
    @Volatile
    private var isProcessing = false

    fun startCamera() {
        Log.d(TAG, "📷 Iniciando CameraX...")
        Log.i("flutter", "📱 [ANDROID] 📷 DeepARCameraController.startCamera() llamado")

        // Activar procesamiento de frames
        isProcessing = true

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()
                Log.i("flutter", "📱 [ANDROID] ✅ CameraProvider obtenido, llamando bindCamera()")
                bindCamera()
                Log.d(TAG, "✅ CameraX iniciado correctamente")
                Log.i("flutter", "📱 [ANDROID] ✅ CameraX iniciado correctamente")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error iniciando CameraX", e)
                Log.e("flutter", "📱 [ANDROID] ❌ Error iniciando CameraX: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun bindCamera() {
        val cameraProvider = this.cameraProvider ?: run {
            Log.e("flutter", "📱 [ANDROID] ❌ bindCamera: cameraProvider es null")
            return
        }

        Log.i("flutter", "📱 [ANDROID] 🔍 bindCamera: Detectando cámaras disponibles...")

        // Detectar qué cámaras están disponibles si aún no lo hemos hecho
        if (!hasDetectedCameras) {
            val hasFrontCamera = cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)
            val hasBackCamera = cameraProvider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)

            Log.d(TAG, "📋 Cámaras disponibles:")
            Log.d(TAG, "   Frontal: $hasFrontCamera")
            Log.d(TAG, "   Trasera: $hasBackCamera")
            Log.i("flutter", "📱 [ANDROID] 📋 Cámaras - Frontal: $hasFrontCamera, Trasera: $hasBackCamera")

            // Usar cámara frontal si está disponible, sino usar trasera
            lensFacing = if (hasFrontCamera) {
                Log.d(TAG, "✅ Usando cámara FRONTAL")
                Log.i("flutter", "📱 [ANDROID] ✅ Usando cámara FRONTAL")
                CameraSelector.LENS_FACING_FRONT
            } else if (hasBackCamera) {
                Log.d(TAG, "✅ Usando cámara TRASERA (frontal no disponible)")
                Log.i("flutter", "📱 [ANDROID] ✅ Usando cámara TRASERA")
                CameraSelector.LENS_FACING_BACK
            } else {
                Log.e(TAG, "❌ No hay cámaras disponibles")
                Log.e("flutter", "📱 [ANDROID] ❌ No hay cámaras disponibles")
                return
            }

            hasDetectedCameras = true
        }

        // Configurar análisis de imagen para procesar frames
        // Usar AspectRatio 4:3 que es más común en cámaras móviles y evita crop/zoom excesivo
        imageAnalyzer = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .setTargetAspectRatio(AspectRatio.RATIO_4_3)
            .build()
            .also { analysis ->
                analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                    processImageProxy(imageProxy)
                }
            }

        // Selector de cámara
        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()

        try {
            // Desvincular todos los use cases antes de vincular nuevos
            cameraProvider.unbindAll()
            Log.i("flutter", "📱 [ANDROID] 🔄 Use cases desvinculados")

            // Vincular use cases a la cámara
            camera = cameraProvider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                imageAnalyzer
            )
            Log.i("flutter", "📱 [ANDROID] ✅ Cámara vinculada al lifecycle")

            // ✅ IMPORTANTE: Configurar zoom inicial a 1.0 (sin zoom) para Android
            camera?.cameraControl?.setZoomRatio(1.0f)
            Log.d(TAG, "✅ Zoom configurado a 1.0 (sin zoom)")
            Log.i("flutter", "📱 [ANDROID] ✅ Zoom configurado a 1.0")

            Log.d(TAG, "✅ Cámara vinculada y capturando frames")
            Log.i("flutter", "📱 [ANDROID] ✅ ¡Cámara iniciada! Esperando frames...")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error vinculando cámara", e)
            Log.e("flutter", "📱 [ANDROID] ❌ Error vinculando cámara: ${e.message}")
            e.printStackTrace()
        }
    }

    private var frameCount = 0
    private var lastLogTime = System.currentTimeMillis()

    @SuppressLint("UnsafeOptInUsageError")
    private fun processImageProxy(imageProxy: ImageProxy) {
        try {
            // Si no estamos procesando, cerrar el frame y salir
            if (!isProcessing) {
                imageProxy.close()
                return
            }

            val image = imageProxy.image ?: run {
                imageProxy.close()
                return
            }

            val width = imageProxy.width
            val height = imageProxy.height

            // Log cada 30 frames (aprox. 1 segundo a 30fps)
            frameCount++
            val currentTime = System.currentTimeMillis()
            if (frameCount % 30 == 0 || currentTime - lastLogTime > 2000) {
                Log.d(TAG, "📹 Frame #$frameCount procesado: ${width}x${height}")
                Log.i("flutter", "📱 [ANDROID] 📹 Frame #$frameCount procesado: ${width}x${height}")
                lastLogTime = currentTime
            }

            // Obtener planes
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]

            val yBuffer = yPlane.buffer
            val uBuffer = uPlane.buffer
            val vBuffer = vPlane.buffer

            val yRowStride = yPlane.rowStride
            val uvRowStride = uPlane.rowStride
            val uvPixelStride = uPlane.pixelStride

            // Calcular tamaño NV21
            val nv21Size = width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
            val nv21 = ByteArray(nv21Size)

            // Copiar plano Y
            var pos = 0
            if (yRowStride == width) {
                // Copiar directo si no hay padding
                yBuffer.get(nv21, 0, width * height)
                pos = width * height
            } else {
                // Copiar fila por fila si hay padding
                for (row in 0 until height) {
                    yBuffer.position(row * yRowStride)
                    yBuffer.get(nv21, pos, width)
                    pos += width
                }
            }

            // Copiar planos UV en formato NV21 (VUVUVU...)
            val uvWidth = (width + 1) / 2
            val uvHeight = (height + 1) / 2

            // Copiar manualmente intercalando V y U para garantizar formato correcto
            for (row in 0 until uvHeight) {
                for (col in 0 until uvWidth) {
                    val uvIndex = row * uvRowStride + col * uvPixelStride
                    // NV21 es VUVUVU...
                    nv21[pos++] = vBuffer.get(uvIndex)
                    nv21[pos++] = uBuffer.get(uvIndex)
                }
            }

            // Convertir a ByteBuffer para DeepAR
            val buffer = ByteBuffer.allocateDirect(nv21.size)
            buffer.put(nv21)
            buffer.rewind()

            val rotation = imageProxy.imageInfo.rotationDegrees
            val mirror = lensFacing == CameraSelector.LENS_FACING_FRONT

            // Enviar frame a DeepAR en el thread principal
            // Nota: Aunque convertimos los datos a formato NV21, el SDK usa el enum YUV_420_888
            // ya que NV21 no existe como constante en DeepARImageFormat
            mainHandler.post {
                try {
                    deepAR.receiveFrame(
                        buffer,
                        width,
                        height,
                        rotation,
                        mirror,
                        ai.deepar.ar.DeepARImageFormat.YUV_420_888,
                        nv21.size
                    )

                    // Log cada 30 frames
                    if (frameCount % 30 == 0) {
                        Log.d(TAG, "✅ Frame #$frameCount enviado a DeepAR (${width}x${height}, rot=$rotation, mirror=$mirror)")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error enviando frame a DeepAR", e)
                }
            }

        } catch (e: Exception) {
            Log.e(TAG, "❌ Error procesando frame", e)
        } finally {
            imageProxy.close()
        }
    }

    fun switchCamera() {
        Log.d(TAG, "🔄 Cambiando cámara...")

        val provider = cameraProvider ?: run {
            Log.e(TAG, "❌ CameraProvider es null, no se puede cambiar cámara")
            return
        }

        // Primero desvincular la cámara actual
        provider.unbindAll()

        // Determinar la nueva cámara a usar
        val newLensFacing = if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            CameraSelector.LENS_FACING_BACK
        } else {
            CameraSelector.LENS_FACING_FRONT
        }

        // Verificar que la nueva cámara esté disponible
        val newCameraSelector = if (newLensFacing == CameraSelector.LENS_FACING_FRONT) {
            CameraSelector.DEFAULT_FRONT_CAMERA
        } else {
            CameraSelector.DEFAULT_BACK_CAMERA
        }

        if (!provider.hasCamera(newCameraSelector)) {
            Log.e(TAG, "❌ La cámara ${if (newLensFacing == CameraSelector.LENS_FACING_FRONT) "frontal" else "trasera"} no está disponible")
            // Revincular la cámara actual
            bindCamera()
            return
        }

        // Cambiar dirección de la cámara
        lensFacing = newLensFacing

        // Vincular la nueva cámara
        bindCamera()
        Log.d(TAG, "✅ Cámara cambiada a ${if (lensFacing == CameraSelector.LENS_FACING_FRONT) "frontal" else "trasera"}")
    }

    fun stopCamera() {
        try {
            // Desactivar procesamiento de frames PRIMERO para evitar race conditions
            isProcessing = false
            Log.d(TAG, "🛑 Procesamiento de frames desactivado")

            // Limpiar callbacks pendientes del mainHandler
            mainHandler.removeCallbacksAndMessages(null)
            Log.d(TAG, "🧹 Callbacks de mainHandler limpiados")

            // Desvincular todos los use cases
            cameraProvider?.unbindAll()
            Log.d(TAG, "⏹️ Cámara desvinculada (listo para reabrir)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error deteniendo cámara", e)
        }
    }
}
