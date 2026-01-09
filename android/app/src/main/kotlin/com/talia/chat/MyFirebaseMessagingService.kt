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
        // ✅ 4 canales para todas las combinaciones de sonido/vibración
        private const val CHANNEL_SOUND_VIBRATION = "talia_sound_vibration"      // Sound + Vibration
        private const val CHANNEL_SOUND_ONLY = "talia_sound_only"                // Sound only
        private const val CHANNEL_VIBRATION_ONLY = "talia_vibration_only"        // Vibration only
        private const val CHANNEL_SILENT = "talia_silent"                        // No sound, no vibration

        // Legacy channels (mantener para compatibilidad)
        private const val CHANNEL_ID = "high_importance_channel"
        private const val CHANNEL_ID_SILENT = "silent_channel"
        private const val CHANNEL_NAME = "Notificaciones Importantes"
        private const val CHANNEL_NAME_SILENT = "Notificaciones Silenciosas"
        private const val PHOTO_CACHE_CHANNEL = "com.talia.chat/photo_cache"

        // ✅ Keys de SharedPreferences (sincronizadas con Flutter)
        private const val SOUND_ENABLED_KEY = "flutter.notification_sound_enabled"
        private const val VIBRATION_ENABLED_KEY = "flutter.notification_vibration_enabled"

        /**
         * ✅ UNIFIED: Mostrar notificación usando cache de fotos proactivo
         *
         * Intenta usar cache primero, si no hay descarga de URL.
         */
        fun showNotificationFromForeground(
            context: Context,
            title: String,
            body: String,
            senderName: String,
            senderId: String,
            senderPhotoUrl: String?,
            chatId: String,
            notificationId: Int = 0 // ✅ ID consistente para poder cancelar después
        ) {
            Log.d(TAG, "📨 [Foreground] Creando notificación desde MainActivity (id=$notificationId)")

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

            // ✅ Calcular ID final: usar el pasado o generar uno basado en chatId
            val finalNotificationId = if (notificationId != 0) notificationId else chatId.hashCode()

            // ✅ Try to get cached photo: Flutter cache first, then local file cache
            var cachedPhoto = getCachedPhoto(senderId)
            if (cachedPhoto == null) {
                cachedPhoto = getFromLocalCacheStatic(context, senderId)
            }

            // Si no hay cache y hay URL, descargar la foto en background thread
            if (cachedPhoto == null && !senderPhotoUrl.isNullOrEmpty()) {
                Log.d(TAG, "📥 [Foreground] Descargando foto desde URL: ${senderPhotoUrl.take(50)}...")
                thread {
                    val downloadedBytes = downloadPhotoStatic(senderPhotoUrl, senderId, context)
                    buildAndShowNotification(
                        context = context,
                        body = body,
                        senderName = senderName,
                        senderId = senderId,
                        cachedPhotoBytes = downloadedBytes,
                        intent = intent,
                        pendingIntent = pendingIntent,
                        notificationId = finalNotificationId
                    )
                }
                return // La notificación se mostrará cuando termine la descarga
            }

            buildAndShowNotification(
                context = context,
                body = body,
                senderName = senderName,
                senderId = senderId,
                cachedPhotoBytes = cachedPhoto,
                intent = intent,
                pendingIntent = pendingIntent,
                notificationId = finalNotificationId
            )
        }

        /**
         * ✅ Download photo from URL and save to cache
         */
        private fun downloadPhotoStatic(photoUrl: String, senderId: String, context: Context): ByteArray? {
            return try {
                val url = java.net.URL(photoUrl)
                val connection = url.openConnection() as java.net.HttpURLConnection
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.doInput = true
                connection.connect()

                if (connection.responseCode == java.net.HttpURLConnection.HTTP_OK) {
                    val inputStream = connection.inputStream
                    val bytes = inputStream.readBytes()
                    inputStream.close()
                    Log.d(TAG, "✅ [Foreground] Foto descargada: ${bytes.size} bytes")

                    // ✅ Guardar en cache para próximas notificaciones
                    saveToCacheStatic(context, senderId, bytes)

                    bytes
                } else {
                    Log.e(TAG, "❌ [Foreground] Error HTTP: ${connection.responseCode}")
                    null
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ [Foreground] Error descargando foto: ${e.message}", e)
                null
            }
        }

        /**
         * ✅ Save photo to local cache (static version)
         */
        private fun saveToCacheStatic(context: Context, senderId: String, bytes: ByteArray) {
            try {
                val cacheDir = java.io.File(context.cacheDir, "photo_cache")
                if (!cacheDir.exists()) {
                    cacheDir.mkdirs()
                }
                val cacheFile = java.io.File(cacheDir, "$senderId.jpg")
                cacheFile.writeBytes(bytes)
                Log.d(TAG, "✅ [Cache] Foto guardada en cache: ${cacheFile.absolutePath}")
            } catch (e: Exception) {
                Log.e(TAG, "❌ [Cache] Error guardando en cache: ${e.message}", e)
            }
        }

        /**
         * ✅ Get photo from local cache (static version, for when FlutterEngine not available)
         */
        private fun getFromLocalCacheStatic(context: Context, senderId: String): ByteArray? {
            return try {
                val cacheFile = java.io.File(context.cacheDir, "photo_cache/$senderId.jpg")
                if (cacheFile.exists()) {
                    val bytes = cacheFile.readBytes()
                    Log.d(TAG, "✅ [LocalCache] Cache HIT para $senderId (${bytes.size} bytes)")
                    bytes
                } else {
                    Log.d(TAG, "⚠️ [LocalCache] Cache MISS para $senderId")
                    null
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ [LocalCache] Error leyendo cache: ${e.message}", e)
                null
            }
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
         * Respeta las preferencias de sonido/vibración del usuario
         */
        private fun buildAndShowNotification(
            context: Context,
            body: String,
            senderName: String,
            senderId: String,
            cachedPhotoBytes: ByteArray?,
            intent: Intent,
            pendingIntent: PendingIntent,
            notificationId: Int = 0
        ) {
            // ✅ Leer preferencias de sonido/vibración desde SharedPreferences
            val sharedPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val soundEnabled = sharedPrefs.getBoolean(SOUND_ENABLED_KEY, true)
            val vibrationEnabled = sharedPrefs.getBoolean(VIBRATION_ENABLED_KEY, true)
            Log.d(TAG, "🔔 [Prefs] sound=$soundEnabled, vibration=$vibrationEnabled")

            // ✅ Crear canales apropiados
            createNotificationChannelsStatic(context)

            // ✅ Seleccionar canal basado en la COMBINACIÓN de preferencias
            val channelId = when {
                soundEnabled && vibrationEnabled -> CHANNEL_SOUND_VIBRATION
                soundEnabled && !vibrationEnabled -> CHANNEL_SOUND_ONLY
                !soundEnabled && vibrationEnabled -> CHANNEL_VIBRATION_ONLY
                else -> CHANNEL_SILENT
            }
            Log.d(TAG, "🔔 [Channel] Usando canal: $channelId")

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

            // Create notification con el canal seleccionado
            val notificationBuilder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setShortcutId(shortcutId)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setStyle(messagingStyle)

            // ✅ Aplicar configuración de sonido/vibración individualmente
            if (!soundEnabled) {
                notificationBuilder.setSound(null)
            }
            if (!vibrationEnabled) {
                notificationBuilder.setVibrate(null)
            }

            // Add large icon if photo is available
            if (circularBitmap != null) {
                notificationBuilder.setLargeIcon(circularBitmap)
                Log.d(TAG, "✅ Notificación con avatar desde cache")
            } else {
                Log.d(TAG, "ℹ️ Notificación sin avatar (no cached)")
            }

            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // ✅ Usar ID consistente para poder cancelar después (auto-dismiss cuando usuario entra al chat)
            val finalId = if (notificationId != 0) notificationId else System.currentTimeMillis().toInt()
            notificationManager.notify(finalId, notificationBuilder.build())
            Log.d(TAG, "✅ Notificación mostrada con id=$finalId (canal=$channelId)")
        }

        /**
         * ✅ Crear todos los canales de notificación necesarios
         * 4 canales para todas las combinaciones de sonido/vibración
         */
        private fun createNotificationChannelsStatic(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

                // ═══════════════════════════════════════════════════════════════
                // 4 CANALES PARA COMBINACIONES DE SONIDO/VIBRACIÓN
                // ═══════════════════════════════════════════════════════════════

                // 1. Canal con sonido Y vibración
                val channelSoundVibration = NotificationChannel(
                    CHANNEL_SOUND_VIBRATION,
                    "Mensajes (Sonido y Vibración)",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones con sonido y vibración"
                    enableVibration(true)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelSoundVibration)

                // 2. Canal solo con sonido (sin vibración)
                val channelSoundOnly = NotificationChannel(
                    CHANNEL_SOUND_ONLY,
                    "Mensajes (Solo Sonido)",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones con sonido pero sin vibración"
                    enableVibration(false)
                    vibrationPattern = null
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelSoundOnly)

                // 3. Canal solo con vibración (sin sonido)
                val channelVibrationOnly = NotificationChannel(
                    CHANNEL_VIBRATION_ONLY,
                    "Mensajes (Solo Vibración)",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones con vibración pero sin sonido"
                    enableVibration(true)
                    setSound(null, null)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelVibrationOnly)

                // 4. Canal silencioso (sin sonido ni vibración)
                val channelSilent = NotificationChannel(
                    CHANNEL_SILENT,
                    "Mensajes Silenciosos",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones sin sonido ni vibración"
                    enableVibration(false)
                    vibrationPattern = null
                    setSound(null, null)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelSilent)

                // ═══════════════════════════════════════════════════════════════
                // LEGACY CHANNELS (para compatibilidad)
                // ═══════════════════════════════════════════════════════════════

                val channelLegacy = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones con sonido y vibración (legacy)"
                    enableVibration(true)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelLegacy)

                val channelLegacySilent = NotificationChannel(
                    CHANNEL_ID_SILENT,
                    CHANNEL_NAME_SILENT,
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones sin sonido ni vibración (legacy)"
                    enableVibration(false)
                    setSound(null, null)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelLegacySilent)

                // Canal de mensajes con sonido (Cloud Functions legacy)
                val channelTaliaMessages = NotificationChannel(
                    "talia_messages",
                    "Mensajes de Talia",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notificaciones de mensajes con sonido (legacy)"
                    enableVibration(true)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channelTaliaMessages)

                Log.d(TAG, "✅ Canales de notificación creados: $CHANNEL_SOUND_VIBRATION, $CHANNEL_SOUND_ONLY, $CHANNEL_VIBRATION_ONLY, $CHANNEL_SILENT + legacy")
            }
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
            // ✅ Delegar al método unificado que crea ambos canales
            createNotificationChannelsStatic(context)
        }

        /**
         * ✅ Hash djb2 cross-platform - produce el mismo resultado en Dart y Kotlin
         * Esto es necesario porque Dart's String.hashCode != Kotlin's String.hashCode()
         */
        private fun crossPlatformHash(input: String): Int {
            var hash: Long = 5381
            for (c in input) {
                hash = ((hash shl 5) + hash) + c.code
                // Mantener en rango de 32 bits para compatibilidad con Dart
                hash = hash and 0xFFFFFFFFL
            }
            // Asegurar positivo y en rango de int32 Android
            return (hash and 0x7FFFFFFFL).toInt()
        }
    }

    init {
        Log.e(TAG, "🏗️ MyFirebaseMessagingService INICIALIZADO")
    }

    /**
     * ✅ Detectar si la app está en foreground
     * Usa ActivityManager para verificar si la app está visible
     */
    private fun isAppInForeground(): Boolean {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val appProcesses = activityManager.runningAppProcesses ?: return false
        val packageName = packageName

        for (appProcess in appProcesses) {
            if (appProcess.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
                && appProcess.processName == packageName) {
                Log.d(TAG, "✅ App detectada en FOREGROUND")
                return true
            }
        }
        Log.d(TAG, "✅ App detectada en BACKGROUND")
        return false
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        Log.e(TAG, "═══════════════════════════════════════════════════")
        Log.e(TAG, "📩 SERVICIO NATIVO: Mensaje FCM recibido desde: ${remoteMessage.from}")
        Log.e(TAG, "═══════════════════════════════════════════════════")

        // ✅ FILTRO FOREGROUND: Si la app está en foreground, Flutter ya maneja la notificación
        // Evita duplicados cuando tanto Flutter como Native reciben el mismo FCM
        if (isAppInForeground()) {
            Log.e(TAG, "📱 App en FOREGROUND - Flutter manejará la notificación, SKIP nativo")
            return
        }

        // Extraer datos del payload
        val data = remoteMessage.data

        Log.e(TAG, "📦 Data: $data")

        // Extraer información del campo data (ya no hay notification)
        val title = data["title"] ?: data["senderName"] ?: "Talia"
        val body = data["body"] ?: data["messagePreview"] ?: ""
        val senderPhotoUrl = data["senderPhotoUrl"]
        val groupPhotoUrl = data["groupPhotoUrl"] // ✅ Foto del grupo
        val isGroup = data["isGroup"] == "true"
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
        Log.e(TAG, "   Foto sender: $senderPhotoUrl")
        Log.e(TAG, "   Foto grupo: $groupPhotoUrl")
        Log.e(TAG, "   Es grupo: $isGroup")
        Log.e(TAG, "   ChatId: $chatId")
        Log.e(TAG, "   Type: $type")

        // ✅ FILTRAR LLAMADAS: No mostrar notificación para llamadas
        // Las llamadas son manejadas por el background handler de Flutter que muestra CallKit
        val isCall = type == "audio_call" ||
                     type == "video_call" ||
                     type == "emergency_call" ||
                     type == "incoming_call" ||          // V2 call system
                     type == "group_video_call" ||
                     type == "group_audio_call" ||
                     type == "call_cancelled"            // ✅ FIX: También filtrar cancelaciones

        if (isCall) {
            Log.e(TAG, "📞 Llamada detectada ($type) - delegando a Flutter background handler")
            Log.e(TAG, "   (El servicio nativo NO mostrará notificación)")
            return
        }

        // ✅ FILTRAR LOCATION REQUEST: No mostrar notificación para solicitudes de ubicación
        // Es una operación silenciosa manejada por Flutter background handler
        if (type == "location_request") {
            Log.e(TAG, "📍 Solicitud de ubicación detectada - delegando a Flutter background handler")
            Log.e(TAG, "   (El servicio nativo NO mostrará notificación - operación silenciosa)")
            return
        }

        // ✅ MENSAJES DE CHAT: El servicio nativo muestra la notificación con MessagingStyle
        // Flutter background handler no puede usar Platform Channel en background isolate
        // Por lo tanto, el servicio nativo es responsable de mostrar notificaciones en background

        // ✅ FILTRO MUTE: Verificar si el chat está silenciado
        val messageChatIdMute = data["chatId"]
        if (messageChatIdMute != null && isChatMuted(messageChatIdMute)) {
            Log.e(TAG, "🔇 [FILTRO MUTE] Chat $messageChatIdMute está silenciado - NO mostrar notificación")
            return
        }

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
        // ✅ Para grupos usar foto del grupo, para chats 1-1 usar foto del sender
        val photoUrlToUse = if (isGroup && !groupPhotoUrl.isNullOrEmpty()) groupPhotoUrl else senderPhotoUrl
        showNotification(title, body, photoUrlToUse, data)
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
        val chatId = data["chatId"] ?: ""
        val messageId = data["messageId"]

        // ✅ Generar ID consistente para auto-dismiss usando djb2 hash (coincide con Dart)
        val contextKey = if (messageId != null) "chat_${chatId}_$messageId" else "chat_$chatId"
        val consistentNotificationId = crossPlatformHash(contextKey)

        Log.d(TAG, "📥 [Background] notificationId consistente=$consistentNotificationId para chat=$chatId")

        // ✅ SIEMPRE descargar foto fresca si hay URL (evita mostrar foto vieja del cache)
        if (!photoUrl.isNullOrEmpty()) {
            Log.d(TAG, "📥 [Background] Descargando foto fresca desde URL...")
            thread {
                val downloadedBytes = downloadPhoto(photoUrl, senderId)
                // Si falla descarga, usar cache local como fallback
                val finalBytes = downloadedBytes ?: getFromLocalCache(senderId)
                buildAndShowNotification(
                    context = this,
                    body = body,
                    senderName = senderName,
                    senderId = senderId,
                    cachedPhotoBytes = finalBytes,
                    intent = intent,
                    pendingIntent = pendingIntent,
                    notificationId = consistentNotificationId
                )
            }
            return
        }

        // Sin URL, usar cache local
        val photoBytes = getFromLocalCache(senderId)
        buildAndShowNotification(
            context = this,
            body = body,
            senderName = senderName,
            senderId = senderId,
            cachedPhotoBytes = photoBytes,
            intent = intent,
            pendingIntent = pendingIntent,
            notificationId = consistentNotificationId
        )
    }

    /**
     * ✅ Get photo from local file cache (instance method)
     */
    private fun getFromLocalCache(senderId: String): ByteArray? {
        return try {
            val cacheFile = java.io.File(cacheDir, "photo_cache/$senderId.jpg")
            if (cacheFile.exists()) {
                val bytes = cacheFile.readBytes()
                Log.d(TAG, "✅ [LocalCache] Cache HIT para $senderId (${bytes.size} bytes)")
                bytes
            } else {
                Log.d(TAG, "⚠️ [LocalCache] Cache MISS para $senderId")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ [LocalCache] Error leyendo cache: ${e.message}", e)
            null
        }
    }

    /**
     * ✅ Download photo from URL and save to cache (instance method)
     */
    private fun downloadPhoto(photoUrl: String, senderId: String): ByteArray? {
        return try {
            val url = java.net.URL(photoUrl)
            val connection = url.openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.doInput = true
            connection.connect()

            if (connection.responseCode == java.net.HttpURLConnection.HTTP_OK) {
                val inputStream = connection.inputStream
                val bytes = inputStream.readBytes()
                inputStream.close()
                Log.d(TAG, "✅ [Background] Foto descargada: ${bytes.size} bytes")

                // ✅ Guardar en cache para próximas notificaciones
                saveToCache(senderId, bytes)

                bytes
            } else {
                Log.e(TAG, "❌ [Background] Error HTTP: ${connection.responseCode}")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ [Background] Error descargando foto: ${e.message}", e)
            null
        }
    }

    /**
     * ✅ Save photo to local cache (instance method)
     */
    private fun saveToCache(senderId: String, bytes: ByteArray) {
        try {
            val cacheDir = java.io.File(cacheDir, "photo_cache")
            if (!cacheDir.exists()) {
                cacheDir.mkdirs()
            }
            val cacheFile = java.io.File(cacheDir, "$senderId.jpg")
            cacheFile.writeBytes(bytes)
            Log.d(TAG, "✅ [Cache] Foto guardada en cache: ${cacheFile.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ [Cache] Error guardando en cache: ${e.message}", e)
        }
    }

    private fun createNotificationChannel() {
        // ✅ Delegar al método estático unificado que crea ambos canales
        createNotificationChannelsStatic(this)
    }

    /**
     * ✅ CHECK MUTED: Verificar si el chat está silenciado
     *
     * Lee la lista de chats silenciados desde SharedPreferences.
     * Flutter sincroniza esta lista cada vez que se silencia/desilencia un chat.
     *
     * @param chatId El ID del chat a verificar
     * @return `true` si el chat está silenciado, `false` en caso contrario
     */
    private fun isChatMuted(chatId: String): Boolean {
        val sharedPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val mutedChatsString = sharedPrefs.getString("flutter.muted_chat_ids", "") ?: ""

        if (mutedChatsString.isEmpty()) {
            return false
        }

        val mutedChatIds = mutedChatsString.split(",")
        val isMuted = mutedChatIds.contains(chatId)

        Log.d(TAG, "🔇 [MUTE CHECK] Chat $chatId silenciado: $isMuted (lista: $mutedChatsString)")
        return isMuted
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
