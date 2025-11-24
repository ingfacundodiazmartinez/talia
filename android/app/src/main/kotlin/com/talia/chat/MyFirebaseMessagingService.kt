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
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.content.LocusIdCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MyFirebaseMessagingService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "FCMService"
        private const val CHANNEL_ID = "high_importance_channel"
        private const val CHANNEL_NAME = "Notificaciones Importantes"
        private const val PHOTO_CACHE_CHANNEL = "com.talia.chat/photo_cache"

        /**
         * ✅ UNIFIED: Mostrar notificación usando cache de fotos proactivo
         *
         * Elimina 200+ líneas de código duplicado de descarga HTTP.
         * Usa ContactPhotoCacheService vía MethodChannel (0ms latency).
         */
        fun showNotificationFromForeground(
            context: Context,
            title: String,
            body: String,
            senderName: String,
            senderId: String,
            senderPhotoUrl: String?,
            chatId: String
        ) {
            Log.d(TAG, "📨 [Foreground] Creando notificación desde MainActivity")

            createNotificationChannelStatic(context)

            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("chatId", chatId)
                putExtra("senderId", senderId)
                putExtra("senderName", senderName)
            }

            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            // ✅ Try to get cached photo via MethodChannel (instant, no HTTP)
            val cachedPhoto = getCachedPhoto(senderId)

            buildAndShowNotification(
                context = context,
                body = body,
                senderName = senderName,
                senderId = senderId,
                cachedPhotoBytes = cachedPhoto,
                intent = intent,
                pendingIntent = pendingIntent
            )
        }

        /**
         * ✅ Get cached photo from ContactPhotoCacheService via MethodChannel
         * Returns ByteArray if cached, null otherwise (0ms lookup)
         */
        private fun getCachedPhoto(senderId: String): ByteArray? {
            return try {
                // Access Flutter's MethodChannel to get cached photo
                val flutterEngine = (MainActivity.flutterEngineInstance as? FlutterEngine)
                if (flutterEngine == null) {
                    Log.w(TAG, "⚠️ FlutterEngine not available, can't access photo cache")
                    return null
                }

                val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHOTO_CACHE_CHANNEL)

                // Synchronous call to Dart (blocking, but instant from memory)
                val result = channel.invokeMethod("getCachedPhoto", senderId)

                if (result is ByteArray && result.isNotEmpty()) {
                    Log.d(TAG, "✅ [PhotoCache] Cache HIT for $senderId (${result.size} bytes)")
                    result
                } else {
                    Log.d(TAG, "⚠️ [PhotoCache] Cache MISS for $senderId")
                    null
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ [PhotoCache] Error accessing cache: ${e.message}", e)
                null
            }
        }

        /**
         * ✅ UNIFIED: Build and show notification (used by both foreground and background)
         * Eliminates duplication between showNotificationFromForeground() and onMessageReceived()
         */
        private fun buildAndShowNotification(
            context: Context,
            body: String,
            senderName: String,
            senderId: String,
            cachedPhotoBytes: ByteArray?,
            intent: Intent,
            pendingIntent: PendingIntent
        ) {
            val shortcutId = "chat_$senderId"

            // Create Person
            val sender = Person.Builder()
                .setName(senderName)
                .build()

            // Create circular bitmap if photo is cached
            val circularBitmap = cachedPhotoBytes?.let { bytes ->
                try {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    createCircularBitmap(bitmap)
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error decoding cached photo: ${e.message}", e)
                    null
                }
            }

            // Create ShortcutInfo (with or without icon)
            val shortcutBuilder = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(senderName)
                .setLongLabel(senderName)
                .setPerson(sender)
                .setLongLived(true)
                .setLocusId(LocusIdCompat(shortcutId))
                .setIntent(intent)

            if (circularBitmap != null) {
                shortcutBuilder.setIcon(IconCompat.createWithBitmap(circularBitmap))
            }

            ShortcutManagerCompat.pushDynamicShortcut(context, shortcutBuilder.build())

            // Create MessagingStyle
            val user = Person.Builder().setName("Yo").build()
            val messagingStyle = NotificationCompat.MessagingStyle(user)
                .setGroupConversation(false)
                .addMessage(body, System.currentTimeMillis(), sender)

            // Create notification
            val notificationBuilder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setShortcutId(shortcutId)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setStyle(messagingStyle)

            // Add large icon if photo is available
            if (circularBitmap != null) {
                notificationBuilder.setLargeIcon(circularBitmap)
                Log.d(TAG, "✅ Notificación con avatar desde cache")
            } else {
                Log.d(TAG, "ℹ️ Notificación sin avatar (no cached)")
            }

            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(System.currentTimeMillis().toInt(), notificationBuilder.build())
        }

        /**
         * Create circular bitmap (192x192, optimized for notifications)
         */
        private fun createCircularBitmap(bitmap: Bitmap): Bitmap {
            val size = 192
            val scaledBitmap = Bitmap.createScaledBitmap(bitmap, size, size, true)
            val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint().apply {
                isAntiAlias = true
            }
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(scaledBitmap, 0f, 0f, paint)
            return output
        }

        private fun createNotificationChannelStatic(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_HIGH
                )
                val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                notificationManager.createNotificationChannel(channel)
            }
        }
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

        Log.e(TAG, "✅ Datos del mensaje:")
        Log.e(TAG, "   Título: $title")
        Log.e(TAG, "   Cuerpo: $body")
        Log.e(TAG, "   Foto: $senderPhotoUrl")
        Log.e(TAG, "   ChatId: $chatId")
        Log.e(TAG, "   Type: $type")

        // ✅ FILTRAR LLAMADAS: No mostrar notificación para llamadas
        // Las llamadas son manejadas por el background handler de Flutter que muestra CallKit
        val isCall = type == "audio_call" ||
                     type == "video_call" ||
                     type == "emergency_call" ||
                     type == "incoming_call" ||          // V2 call system
                     type == "group_video_call" ||
                     type == "group_audio_call"

        if (isCall) {
            Log.e(TAG, "📞 Llamada detectada ($type) - delegando a Flutter background handler")
            Log.e(TAG, "   (El servicio nativo NO mostrará notificación)")
            return
        }

        // ⚠️ TEMPORALMENTE DESACTIVADO: Anti-duplicados causa que NO se muestren notificaciones
        // El Stream Detector marca mensajes como "ya mostrados" ANTES de que llegue FCM,
        // causando que FCM las rechace como duplicadas.
        /*
        // ✅ FILTRO ANTI-DUPLICADO: Verificar si Stream Detector ya mostró esta notificación
        val messageId = data["messageId"]
        Log.e(TAG, "🔍 [ANTI-DUPLICADO] Message ID: $messageId")

        if (messageId != null) {
            val sharedPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            // Buscar con diferentes formatos de clave (igual que en Flutter)
            val timestampKey1 = "flutter.instant_notification_$messageId"
            val timestampKey2 = "instant_notification_$messageId"

            // ✅ FIX: Usar getLong() en lugar de getString() porque Flutter guarda timestamps como Long
            val existingTimestamp1 = if (sharedPrefs.contains(timestampKey1)) sharedPrefs.getLong(timestampKey1, 0) else null
            val existingTimestamp2 = if (sharedPrefs.contains(timestampKey2)) sharedPrefs.getLong(timestampKey2, 0) else null

            val existingTimestamp = existingTimestamp1 ?: existingTimestamp2

            if (existingTimestamp != null && existingTimestamp > 0) {
                val now = System.currentTimeMillis()
                val age = now - existingTimestamp

                // Si la notificación instantánea se mostró hace menos de 10 segundos, es duplicado
                if (age < 10000) {
                    Log.e(TAG, "🚫 [ANTI-DUPLICADO] Stream Detector ya mostró esta notificación hace ${age}ms - SKIP")
                    return
                } else {
                    Log.e(TAG, "⏳ [ANTI-DUPLICADO] Notificación antigua (${age}ms) - permitiendo FCM push")
                }
            } else {
                Log.e(TAG, "✅ [ANTI-DUPLICADO] Primera notificación para este mensaje - permitida")
            }
        }
        */

        // ✅ FILTRO CHAT ACTUAL: Verificar si el usuario está viendo este chat
        Log.e(TAG, "🔍 [FILTRO] Iniciando verificación de chat actual...")
        val messageChatId = data["chatId"]
        Log.e(TAG, "🔍 [FILTRO] Chat ID del mensaje: $messageChatId")

        if (messageChatId != null) {
            val sharedPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            Log.e(TAG, "🔍 [FILTRO] SharedPreferences obtenidas")

            // Intentar diferentes formatos de clave
            val currentChatId1 = sharedPrefs.getString("flutter.current_chat_id", null)
            val currentChatId2 = sharedPrefs.getString("current_chat_id", null)

            Log.e(TAG, "🔍 [FILTRO] current_chat_id (flutter.): $currentChatId1")
            Log.e(TAG, "🔍 [FILTRO] current_chat_id (directo): $currentChatId2")

            val currentChatId = currentChatId1 ?: currentChatId2

            if (currentChatId != null && currentChatId == messageChatId) {
                Log.e(TAG, "🚫 [FILTRO] Usuario está viendo chat $messageChatId - NO mostrar notificación nativa")
                return
            } else if (currentChatId != null) {
                Log.e(TAG, "📱 [FILTRO] Usuario en chat $currentChatId, notificación de chat $messageChatId - permitida")
            } else {
                Log.e(TAG, "📱 [FILTRO] No hay chat actual - notificación permitida")
            }
        } else {
            Log.e(TAG, "⚠️ [FILTRO] No hay chatId en los datos - permitiendo notificación")
        }

        // ✅ ATOMIC ANTI-DUPLICADOS: Verificar y marcar en operación atómica
        val messageId = data["messageId"]
        Log.e(TAG, "🔍 [ANTI-DUPLICADO ATOMIC] Message ID: $messageId")

        if (messageId != null) {
            // ✅ ATOMIC CHECK-AND-SET: Solo UNA operación puede adquirir el "derecho" a mostrar
            if (!tryAcquireNotificationRight(messageId)) {
                Log.e(TAG, "🚫 [ANTI-DUPLICADO ATOMIC] Otro listener ya mostró $messageId - SKIP")
                return
            }
            Log.e(TAG, "✅ [ANTI-DUPLICADO ATOMIC] Adquirido derecho para mostrar $messageId")
        }

        // Solo mostrar notificaciones para mensajes de chat
        Log.e(TAG, "💬 Mensaje de chat - mostrando notificación nativa")
        showNotification(title, body, senderPhotoUrl, data)
    }

    private fun showNotification(
        title: String,
        body: String,
        photoUrl: String?,
        data: Map<String, String>
    ) {
        createNotificationChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data.forEach { (key, value) ->
                putExtra(key, value)
            }
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val senderName = data["senderName"] ?: "Usuario"
        val senderId = data["senderId"] ?: (data["chatId"] ?: "unknown")

        // ✅ UNIFIED: Use the same logic as foreground - get cached photo
        val cachedPhoto = getCachedPhoto(senderId)

        buildAndShowNotification(
            context = this,
            body = body,
            senderName = senderName,
            senderId = senderId,
            cachedPhotoBytes = cachedPhoto,
            intent = intent,
            pendingIntent = pendingIntent
        )
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

    /**
     * ✅ ATOMIC: Try to acquire the "right" to show this notification
     *
     * This is an atomic check-and-set operation that prevents race conditions
     * between Dart listeners and Native FCM Service.
     *
     * Only ONE caller (ChatDocsListener, StreamDetector, or Native Service) will get `true`,
     * all others get `false`.
     *
     * @param messageId The unique message identifier
     * @return `true` if this is the FIRST caller (show notification), `false` otherwise
     */
    @Synchronized
    private fun tryAcquireNotificationRight(messageId: String): Boolean {
        val sharedPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val messageKey = "flutter.instant_notification_$messageId"

        // ✅ ATOMIC CHECK: If already exists, another listener acquired it first
        if (sharedPrefs.contains(messageKey)) {
            Log.e(TAG, "🔒 [ATOMIC] Message $messageId already acquired by another listener")
            return false
        }

        // ✅ ATOMIC SET: Mark as shown IMMEDIATELY (before any other operation)
        sharedPrefs.edit().putLong(messageKey, System.currentTimeMillis()).apply()

        Log.e(TAG, "🎯 [ATOMIC] Successfully acquired notification right for $messageId")
        return true
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "🔄 Nuevo FCM token: ${token.take(20)}...")
        // Flutter manejará la actualización del token en Firestore
    }
}
