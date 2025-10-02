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

    // Cámara frontal por defecto
    private var lensFacing = CameraSelector.LENS_FACING_FRONT

    fun startCamera() {
        Log.d(TAG, "📷 Iniciando CameraX...")

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()
                bindCamera()
                Log.d(TAG, "✅ CameraX iniciado correctamente")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error iniciando CameraX", e)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun bindCamera() {
        val cameraProvider = this.cameraProvider ?: return

        // Configurar análisis de imagen para procesar frames con mayor resolución
        imageAnalyzer = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .setTargetResolution(android.util.Size(1280, 720))  // 720p para mejor calidad
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

            // Vincular use cases a la cámara
            camera = cameraProvider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                imageAnalyzer
            )

            Log.d(TAG, "✅ Cámara vinculada y capturando frames")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error vinculando cámara", e)
        }
    }

    private var frameCount = 0
    private var lastLogTime = System.currentTimeMillis()

    @SuppressLint("UnsafeOptInUsageError")
    private fun processImageProxy(imageProxy: ImageProxy) {
        try {
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

            if (uvPixelStride == 2 && uvRowStride == width) {
                // Caso optimizado: UV ya está entrelazado
                vBuffer.position(0)
                vBuffer.get(nv21, pos, uvWidth * uvHeight * 2)
            } else {
                // Copiar manualmente intercalando V y U
                for (row in 0 until uvHeight) {
                    for (col in 0 until uvWidth) {
                        val vIndex = row * uvRowStride + col * uvPixelStride
                        val uIndex = row * uvRowStride + col * uvPixelStride
                        nv21[pos++] = vBuffer.get(vIndex)
                        nv21[pos++] = uBuffer.get(uIndex)
                    }
                }
            }

            // Convertir a ByteBuffer para DeepAR
            val buffer = ByteBuffer.allocateDirect(nv21.size)
            buffer.put(nv21)
            buffer.rewind()

            val rotation = imageProxy.imageInfo.rotationDegrees
            val mirror = lensFacing == CameraSelector.LENS_FACING_FRONT

            // Enviar frame a DeepAR en el thread principal
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

        // Primero desvincular la cámara actual
        cameraProvider?.unbindAll()

        // Cambiar dirección de la cámara
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            CameraSelector.LENS_FACING_BACK
        } else {
            CameraSelector.LENS_FACING_FRONT
        }

        // Vincular la nueva cámara
        bindCamera()
        Log.d(TAG, "✅ Cámara cambiada a ${if (lensFacing == CameraSelector.LENS_FACING_FRONT) "frontal" else "trasera"}")
    }

    fun stopCamera() {
        try {
            cameraProvider?.unbindAll()
            // NO cerrar el executor, solo desvincular para poder reabrir
            Log.d(TAG, "⏹️ Cámara desvinculada (listo para reabrir)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error deteniendo cámara", e)
        }
    }
}
