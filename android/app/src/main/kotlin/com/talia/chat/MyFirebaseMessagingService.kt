package com.talia.chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Matrix
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.content.LocusIdCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.exifinterface.media.ExifInterface
import java.net.HttpURLConnection
import java.net.URL
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.concurrent.thread

class MyFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "FCMService"
        private const val CHANNEL_ID = "high_importance_channel"
        private const val CHANNEL_NAME = "Notificaciones Importantes"
    }

    init {
        Log.e(TAG, "🏗️ MyFirebaseMessagingService INICIALIZADO")
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        Log.e(TAG, "═══════════════════════════════════════════════════")
        Log.e(TAG, "📩 SERVICIO NATIVO: Mensaje FCM recibido desde: ${remoteMessage.from}")
        Log.e(TAG, "═══════════════════════════════════════════════════")

        // Extraer datos del payload
        val data = remoteMessage.data

        Log.e(TAG, "📦 Data: $data")

        // Extraer información del campo data (ya no hay notification)
        val title = data["title"] ?: data["senderName"] ?: "Talia"
        val body = data["body"] ?: data["messagePreview"] ?: ""
        val senderPhotoUrl = data["senderPhotoUrl"]
        val chatId = data["chatId"]
        val type = data["type"]

        // Si no hay datos suficientes, salir
        if (title.isEmpty() && body.isEmpty()) {
            Log.e(TAG, "⚠️ Sin título ni cuerpo en el mensaje")
            return
        }

        Log.e(TAG, "✅ Mostrando notificación nativa con:")
        Log.e(TAG, "   Título: $title")
        Log.e(TAG, "   Cuerpo: $body")
        Log.e(TAG, "   Foto: $senderPhotoUrl")
        Log.e(TAG, "   ChatId: $chatId")
        Log.e(TAG, "   Type: $type")

        // Mostrar notificación
        showNotification(title, body, senderPhotoUrl, data)
    }

    private fun showNotification(
        title: String,
        body: String,
        photoUrl: String?,
        data: Map<String, String>
    ) {
        // Crear canal de notificación (Android 8.0+)
        createNotificationChannel()

        // Intent para abrir la app cuando se toca la notificación
        val intent = Intent(this, MainActivity::class.java)
        intent.action = Intent.ACTION_VIEW  // Requerido para ShortcutInfo
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        // Agregar datos para que Flutter pueda navegar
        data.forEach { (key, value) ->
            intent.putExtra(key, value)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Extraer nombre del sender, senderId y chatId para el shortcut
        val senderName = data["senderName"] ?: "Usuario"
        val senderId = data["senderId"] ?: (data["chatId"] ?: "unknown")
        val shortcutId = "chat_$senderId"

        // Si hay foto de perfil, descargarla en background y mostrar notificación
        if (!photoUrl.isNullOrEmpty() && photoUrl != "null") {
            thread {
                try {
                    Log.e(TAG, "📥 Descargando foto de perfil: $photoUrl")
                    val bitmap = downloadImage(photoUrl)

                    if (bitmap != null) {
                        Log.e(TAG, "✅ Imagen descargada: ${bitmap.width}x${bitmap.height}")

                        // Crear bitmap circular (con corrección de rotación)
                        val circularBitmap = getCircularBitmap(bitmap)
                        Log.e(TAG, "✅ Bitmap circular creado: ${circularBitmap.width}x${circularBitmap.height}")

                        // Crear Person para el sender con la foto
                        val sender = Person.Builder()
                            .setName(senderName)
                            .setIcon(IconCompat.createWithBitmap(circularBitmap))
                            .build()

                        // PASO 1: Crear ShortcutInfo para el chat (CRUCIAL para foto a la izquierda)
                        val shortcut = ShortcutInfoCompat.Builder(this, shortcutId)
                            .setShortLabel(senderName)
                            .setLongLabel(senderName)
                            .setIcon(IconCompat.createWithBitmap(circularBitmap))
                            .setPerson(sender)
                            .setLongLived(true)
                            .setLocusId(LocusIdCompat(shortcutId))
                            .setIntent(intent)
                            .build()

                        // PASO 2: Publicar el shortcut (requerido para Android 11+)
                        ShortcutManagerCompat.pushDynamicShortcut(this, shortcut)
                        Log.e(TAG, "✅ Shortcut publicado con ID: $shortcutId")

                        // Crear Person para el usuario (receptor)
                        val user = Person.Builder()
                            .setName("Yo")
                            .build()

                        // Usar MessagingStyle
                        val messagingStyle = NotificationCompat.MessagingStyle(user)
                            .addMessage(body, System.currentTimeMillis(), sender)

                        // PASO 3: Vincular notificación al shortcut con setShortcutId
                        val notificationBuilder = NotificationCompat.Builder(this, CHANNEL_ID)
                            .setSmallIcon(R.drawable.ic_notification)  // Ícono monocromático blanco
                            .setShortcutId(shortcutId)  // ⭐ CLAVE: vincula shortcut para foto a la izquierda
                            .setPriority(NotificationCompat.PRIORITY_HIGH)
                            .setAutoCancel(true)
                            .setContentIntent(pendingIntent)
                            .setStyle(messagingStyle)

                        Log.e(TAG, "✅ Notificación configurada con ShortcutId (foto a la izquierda)")

                        // Mostrar notificación
                        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        notificationManager.notify(System.currentTimeMillis().toInt(), notificationBuilder.build())
                        Log.e(TAG, "📤 Notificación mostrada con foto del sender a la izquierda")
                    } else {
                        Log.e(TAG, "⚠️ No se pudo descargar la imagen, mostrando sin foto")
                        showBasicNotification(title, body, pendingIntent)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error procesando foto de perfil: ${e.message}", e)
                    showBasicNotification(title, body, pendingIntent)
                }
            }
        } else {
            // Sin foto, mostrar inmediatamente
            showBasicNotification(title, body, pendingIntent)
        }
    }

    private fun showBasicNotification(title: String, body: String, pendingIntent: PendingIntent) {
        val notificationBuilder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(System.currentTimeMillis().toInt(), notificationBuilder.build())
        Log.e(TAG, "📤 Notificación básica mostrada (sin foto)")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Canal para notificaciones importantes de Talia"
                enableVibration(true)
                enableLights(true)
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun downloadImage(urlString: String): Bitmap? {
        return try {
            val url = URL(urlString)
            val connection = url.openConnection() as HttpURLConnection
            connection.doInput = true
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.connect()

            if (connection.responseCode == HttpURLConnection.HTTP_OK) {
                val input = connection.inputStream

                // Leer los bytes para poder procesarlos dos veces (EXIF y Bitmap)
                val bytes = input.readBytes()
                input.close()

                // Decodificar el bitmap
                var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

                // Intentar leer orientación EXIF
                try {
                    val exif = ExifInterface(ByteArrayInputStream(bytes))
                    val orientation = exif.getAttributeInt(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_NORMAL
                    )

                    // Corregir rotación según EXIF
                    val matrix = Matrix()
                    when (orientation) {
                        ExifInterface.ORIENTATION_ROTATE_90 -> {
                            matrix.postRotate(90f)
                            Log.e(TAG, "🔄 Corrigiendo rotación: 90°")
                        }
                        ExifInterface.ORIENTATION_ROTATE_180 -> {
                            matrix.postRotate(180f)
                            Log.e(TAG, "🔄 Corrigiendo rotación: 180°")
                        }
                        ExifInterface.ORIENTATION_ROTATE_270 -> {
                            matrix.postRotate(270f)
                            Log.e(TAG, "🔄 Corrigiendo rotación: 270°")
                        }
                        else -> Log.e(TAG, "✅ Sin necesidad de corregir rotación")
                    }

                    // Aplicar rotación si es necesario
                    if (!matrix.isIdentity) {
                        bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ No se pudo leer EXIF, usando imagen sin rotación")
                }

                // Redimensionar a 192x192 (tamaño óptimo para largeIcon)
                Bitmap.createScaledBitmap(bitmap, 192, 192, true)
            } else {
                Log.w(TAG, "⚠️ HTTP ${connection.responseCode} al descargar imagen")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error descargando imagen: ${e.message}", e)
            null
        }
    }

    private fun getCircularBitmap(bitmap: Bitmap): Bitmap {
        val size = Math.min(bitmap.width, bitmap.height)
        Log.e(TAG, "🎨 Creando bitmap circular - tamaño: $size")

        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)

        // Crear un círculo como máscara
        val paint = Paint().apply {
            isAntiAlias = true
            isFilterBitmap = true
            isDither = true
        }

        // Dibujar la imagen primero (centrada y recortada)
        val srcRect = Rect(
            (bitmap.width - size) / 2,
            (bitmap.height - size) / 2,
            (bitmap.width + size) / 2,
            (bitmap.height + size) / 2
        )
        val dstRect = Rect(0, 0, size, size)
        canvas.drawBitmap(bitmap, srcRect, dstRect, paint)

        Log.e(TAG, "✅ Imagen dibujada en canvas")

        // Aplicar máscara circular usando DST_IN
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)

        Log.e(TAG, "✅ Máscara circular aplicada")

        return output
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "🔄 Nuevo FCM token: ${token.take(20)}...")
        // Flutter manejará la actualización del token en Firestore
    }
}
