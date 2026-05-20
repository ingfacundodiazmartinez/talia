package com.talia.chat

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
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
            notificationId: Int = 0, // ✅ ID consistente para poder cancelar después
            isGroup: Boolean = false, // ✅ FIX: Support group notifications
            groupName: String? = null // ✅ FIX: Group name for title
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
                        notificationId = finalNotificationId,
                        isGroup = isGroup,
                        groupName = groupName
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
                notificationId = finalNotificationId,
                isGroup = isGroup,
                groupName = groupName
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
            notificationId: Int = 0,
            isGroup: Boolean = false,
            groupName: String? = null
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

            // ✅ FIX: Use appropriate shortcut name based on chat type
            val shortcutName = if (isGroup && !groupName.isNullOrEmpty()) groupName else senderName
            val shortcutId = "chat_$senderId"

            // 🔍 DEBUG: Log what we're using for the notification
            Log.e(TAG, "🔍 [buildAndShowNotification] isGroup=$isGroup, groupName=$groupName, shortcutName=$shortcutName")

            // Create Person (for the sender of this message)
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
            // ✅ FIX: Use group name for shortcuts when it's a group chat
            val shortcutBuilder = ShortcutInfoCompat.Builder(context, shortcutId)
                .setShortLabel(shortcutName)
                .setLongLabel(shortcutName)
                .setPerson(sender)
                .setLongLived(true)
                .setLocusId(LocusIdCompat(shortcutId))
                .setIntent(intent)

            if (circularBitmap != null) {
                shortcutBuilder.setIcon(IconCompat.createWithBitmap(circularBitmap))
            }

            ShortcutManagerCompat.pushDynamicShortcut(context, shortcutBuilder.build())

            // ✅ FIX: For groups, strip sender prefix from body (MessagingStyle adds it via Person)
            // Flutter sends "Facu: Mensaje" but MessagingStyle shows "Facu: body"
            // Result without fix: "Facu: Facu: Mensaje" (duplicated)
            val messageBody = if (isGroup && body.startsWith("$senderName: ")) {
                body.removePrefix("$senderName: ")
            } else {
                body
            }

            // Create MessagingStyle
            val user = Person.Builder().setName("Yo").build()
            val messagingStyle = NotificationCompat.MessagingStyle(user)
                .setGroupConversation(isGroup)
                .addMessage(messageBody, System.currentTimeMillis(), sender)

            // ✅ FIX: Set conversation title to group name for group messages
            if (isGroup && !groupName.isNullOrEmpty()) {
                messagingStyle.conversationTitle = groupName
            }

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

        // ✅ DELIVERY RECEIPT (server-confirmed): cuando llega un mensaje de chat
        // 1-1 vía FCM al device, marcar `lastReceivedAt_{me}` en el chat doc.
        // Esto le da el ✓✓ gris al sender. Se hace acá (nativo) porque cuando
        // la app está totalmente cerrada, el handler de Dart no siempre corre
        // pero este servicio nativo sí. Para grupos no aplica.
        if (type == "chat_message" && !chatId.isNullOrEmpty() && !isGroup) {
            try {
                val uid = FirebaseAuth.getInstance().currentUser?.uid
                if (uid != null) {
                    FirebaseFirestore.getInstance()
                        .collection("chats")
                        .document(chatId)
                        .update("lastReceivedAt_$uid", FieldValue.serverTimestamp())
                        .addOnSuccessListener {
                            Log.e(TAG, "📬 [DeliveryReceipt] lastReceivedAt_$uid actualizado para $chatId")
                        }
                        .addOnFailureListener { e ->
                            Log.e(TAG, "⚠️ [DeliveryReceipt] Error (no crítico): ${e.message}")
                        }
                }
            } catch (e: Exception) {
                Log.e(TAG, "⚠️ [DeliveryReceipt] Exception (no crítico): ${e.message}")
            }
        }

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

        // ✅ NUDGE: Mostrar notificación con foto circular del sender
        if (type == "nudge") {
            Log.e(TAG, "📳 Nudge detectado - mostrando notificación nativa con foto circular")
            val nudgeTitle = data["title"] ?: "📳 Nudge"
            val nudgeBody = data["body"] ?: "Te envió un nudge"
            val nudgeSenderId = data["senderId"] ?: "unknown"
            val nudgeSenderName = data["senderName"] ?: "Alguien"
            val nudgeSenderPhotoUrl = data["senderPhotoUrl"]

            showNudgeNotification(
                title = nudgeTitle,
                body = nudgeBody,
                senderId = nudgeSenderId,
                senderName = nudgeSenderName,
                photoUrl = nudgeSenderPhotoUrl
            )
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
        // ✅ FIX: Extract group info for proper notification formatting
        val isGroup = data["isGroup"] == "true"
        val groupName = data["groupName"]

        // 🔍 DEBUG: Log group notification data
        Log.e(TAG, "🔍 [DEBUG] isGroup=$isGroup, groupName=$groupName, senderName=$senderName")

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
                    notificationId = consistentNotificationId,
                    isGroup = isGroup,
                    groupName = groupName
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
            notificationId = consistentNotificationId,
            isGroup = isGroup,
            groupName = groupName
        )
    }

    /**
     * ✅ NUDGE: Mostrar notificación de nudge con foto circular
     * Similar a chat pero sin MessagingStyle, solo BigTextStyle con largeIcon circular
     */
    private fun showNudgeNotification(
        title: String,
        body: String,
        senderId: String,
        senderName: String,
        photoUrl: String?
    ) {
        createNotificationChannel()

        val intent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("type", "nudge")
            putExtra("senderId", senderId)
            putExtra("senderName", senderName)
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // ✅ Generar ID único para este nudge
        val notificationId = "nudge_${senderId}_${System.currentTimeMillis()}".hashCode()

        // ✅ Leer preferencias de sonido/vibración desde SharedPreferences
        val sharedPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val soundEnabled = sharedPrefs.getBoolean(SOUND_ENABLED_KEY, true)
        val vibrationEnabled = sharedPrefs.getBoolean(VIBRATION_ENABLED_KEY, true)

        // ✅ Crear canales apropiados
        createNotificationChannelsStatic(this)

        // ✅ Seleccionar canal basado en preferencias
        val channelId = when {
            soundEnabled && vibrationEnabled -> CHANNEL_SOUND_VIBRATION
            soundEnabled && !vibrationEnabled -> CHANNEL_SOUND_ONLY
            !soundEnabled && vibrationEnabled -> CHANNEL_VIBRATION_ONLY
            else -> CHANNEL_SILENT
        }

        // ✅ Descargar foto si hay URL
        if (!photoUrl.isNullOrEmpty()) {
            Log.d(TAG, "📳 [Nudge] Descargando foto del sender...")
            thread {
                val downloadedBytes = downloadPhoto(photoUrl, senderId)
                val finalBytes = downloadedBytes ?: getFromLocalCache(senderId)
                buildNudgeNotification(
                    title = title,
                    body = body,
                    senderName = senderName,
                    photoBytes = finalBytes,
                    pendingIntent = pendingIntent,
                    notificationId = notificationId,
                    channelId = channelId
                )
            }
            return
        }

        // Sin URL, usar cache local
        val photoBytes = getFromLocalCache(senderId)
        buildNudgeNotification(
            title = title,
            body = body,
            senderName = senderName,
            photoBytes = photoBytes,
            pendingIntent = pendingIntent,
            notificationId = notificationId,
            channelId = channelId
        )
    }

    /**
     * ✅ Build and show nudge notification with circular photo
     */
    private fun buildNudgeNotification(
        title: String,
        body: String,
        senderName: String,
        photoBytes: ByteArray?,
        pendingIntent: PendingIntent,
        notificationId: Int,
        channelId: String
    ) {
        // ✅ Crear bitmap circular si hay foto
        val circularBitmap = photoBytes?.let { bytes ->
            try {
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
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
                output
            } catch (e: Exception) {
                Log.e(TAG, "❌ [Nudge] Error creando bitmap circular: ${e.message}", e)
                null
            }
        }

        // ✅ Construir notificación
        val notificationBuilder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)

        // ✅ Agregar foto circular como largeIcon
        if (circularBitmap != null) {
            notificationBuilder.setLargeIcon(circularBitmap)
            Log.d(TAG, "📳 [Nudge] Notificación con foto circular del sender")
        } else {
            Log.d(TAG, "📳 [Nudge] Notificación sin foto (no disponible)")
        }

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(notificationId, notificationBuilder.build())
        Log.d(TAG, "📳 [Nudge] Notificación mostrada con id=$notificationId")
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

        // ✅ Audit #7: barrer keys viejas (> 1 hora) antes de escribir una nueva.
        // Sin esto, SharedPreferences crecía indefinidamente — 1000 msg/día →
        // ~30k entradas/mes que nunca se borraban.
        cleanupOldInstantNotificationKeys(sharedPrefs)

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

    /**
     * Audit #7: limpia keys `flutter.instant_notification_*` con timestamp > 1h.
     * Se ejecuta opcionalmente cuando hay muchas keys para evitar costo en cada call.
     */
    private fun cleanupOldInstantNotificationKeys(sharedPrefs: android.content.SharedPreferences) {
        try {
            val all = sharedPrefs.all
            // Solo barrer si hay muchas keys (evita costo en cada llamada).
            val instantKeys = all.keys.filter { it.startsWith("flutter.instant_notification_") }
            if (instantKeys.size < 100) return

            val cutoffMs = System.currentTimeMillis() - 60 * 60 * 1000L  // 1 hora atrás
            val editor = sharedPrefs.edit()
            var removed = 0
            for (key in instantKeys) {
                val ts = all[key] as? Long ?: continue
                if (ts < cutoffMs) {
                    editor.remove(key)
                    removed++
                }
            }
            if (removed > 0) {
                editor.apply()
                Log.e(TAG, "🧹 [Cleanup] Removidas $removed keys instant_notification antiguas")
            }
        } catch (e: Exception) {
            Log.e(TAG, "⚠️ [Cleanup] Error limpiando instant keys: ${e.message}")
        }
    }

    override fun onNewToken(token: String) {
        Log.d(TAG, "🔄 Nuevo FCM token: ${token.take(20)}...")
        // Flutter manejará la actualización del token en Firestore
    }
}
