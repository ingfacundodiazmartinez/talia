import 'package:cloud_firestore/cloud_firestore.dart';

/// Estados posibles de un mensaje
enum MessageStatus {
  sending,   // Mensaje siendo enviado (optimistic)
  sent,      // Confirmado en Firestore
  delivered, // Entregado al receptor (confirmación de entrega)
  seen,      // Visto por el receptor (confirmación de lectura)
  error,     // Error al enviar
}

/// Estados de moderación de contenido con IA
enum ModerationStatus {
  approved,  // Mensaje aprobado (puede verse)
  blocked,   // Mensaje bloqueado por contenido inapropiado
  pending,   // En revisión (solo si usamos pending en el futuro)
}

/// Modelo que representa un mensaje de chat
class ChatMessage {
  final String id;
  final String senderId;
  final String? text;
  final String? imageUrl;
  final String? videoUrl;
  final String? audioUrl;
  final Timestamp? timestamp;
  final bool isRead;
  final List<String>? readBy; // ✅ Lista de usuarios que leyeron el mensaje (para unread count)
  final Map<String, dynamic>? replyTo;
  final Map<String, dynamic>? reactions;
  final String? type; // 'text', 'image', 'video', 'audio', 'missed_call', etc.

  // Campos para llamadas
  final String? callType; // 'video' o 'audio'
  final String? callId; // ID de la llamada en Firestore
  final int? callDuration; // Duración de la llamada en segundos (solo para answered_call)

  // Nuevos campos para optimistic updates
  final MessageStatus status;
  final DateTime? localTimestamp;  // Timestamp local para MOSTRAR hora mientras está pending (NO usar para ordenar)
  final int? retryCount;           // Contador de reintentos
  final String? localPath;         // Path local del archivo (para preview mientras se sube)

  // Campos para moderación con IA
  final ModerationStatus? moderationStatus;  // Estado de moderación
  final String? moderationReason;            // Razón del bloqueo/alerta
  final String? moderationSeverity;          // Severidad: none, low, medium, high
  final String? originalText;                // Texto original antes de ser bloqueado

  // Campos para audio
  final List<double>? waveformData;          // Datos de forma de onda para audio
  final String? transcription;               // Transcripción de audio (de moderación con Whisper)

  // Campos para mensajes reenviados
  final bool isForwarded;                    // Indica si el mensaje fue reenviado
  final String? originalSenderId;            // ID del remitente original
  final String? originalChatId;              // ID del chat original
  final String? originalContactName;         // Nombre del contacto original

  // ✅ Campo para matching de mensajes optimistas
  final String? localId;                     // ID temporal del mensaje optimista (para reemplazo)

  // ✅ Campo para eliminación
  final bool isDeletedForEveryone;           // Mensaje eliminado para todos

  // ✅ Visibilidad por destinatario.
  // Si es null, el mensaje es visible para todos los participantes (backwards compat
  // con mensajes pre-migración).
  // Si tiene valor, solo los UIDs listados pueden ver el mensaje. Casos típicos:
  // - [senderId]: mensaje silenciado por bloqueo del destinatario, o pendiente de
  //   moderación (la CF expande la lista al aprobar).
  // - [senderId, receiverId]: mensaje normal, visible para ambos.
  final List<String>? visibleTo;

  ChatMessage({
    required this.id,
    required this.senderId,
    this.text,
    this.imageUrl,
    this.videoUrl,
    this.audioUrl,
    this.timestamp,
    this.isRead = false,
    this.readBy, // ✅ Lista de usuarios que leyeron
    this.replyTo,
    this.reactions,
    this.type,
    this.callType,
    this.callId,
    this.callDuration,
    this.status = MessageStatus.sent,  // Por defecto "sent" para mensajes existentes
    this.localTimestamp,
    this.retryCount = 0,
    this.localPath,
    this.moderationStatus,
    this.moderationReason,
    this.moderationSeverity,
    this.originalText,
    this.waveformData,
    this.transcription,
    this.isForwarded = false,
    this.originalSenderId,
    this.originalChatId,
    this.originalContactName,
    this.localId, // ✅ Agregar localId
    this.isDeletedForEveryone = false, // ✅ Agregar isDeletedForEveryone
    this.visibleTo,
  });

  /// Factory constructor desde Firestore DocumentSnapshot
  factory ChatMessage.fromFirestore(DocumentSnapshot doc, {String? currentUserId}) {
    final data = doc.data() as Map<String, dynamic>;
    return ChatMessage.fromMap(doc.id, data, currentUserId: currentUserId);
  }

  /// Factory constructor desde Map
  factory ChatMessage.fromMap(String id, Map<String, dynamic> data, {String? currentUserId}) {
    // Debug forwarding fields
    _debugForwardingFields(id, data);

    // Parse moderation status from string
    ModerationStatus? moderationStatus;
    final modStatusString = data['moderationStatus'] as String?;
    if (modStatusString != null) {
      switch (modStatusString) {
        case 'approved':
          moderationStatus = ModerationStatus.approved;
          break;
        case 'blocked':
          moderationStatus = ModerationStatus.blocked;
          break;
        case 'pending':
          moderationStatus = ModerationStatus.pending;
          break;
      }
    }

    // ✅ V2 ARCHITECTURE: Calcular status basado SOLO en presencia de timestamp
    // El controller recalculará a seen/delivered usando lastOpenedAt del chat doc
    //
    // NOTA: Se elimina el sistema legacy (readBy) para chats 1-1 porque:
    // 1. Causaba inconsistencias (último mensaje seen, penúltimo no)
    // 2. V2 usa timestamps del chat doc para calcular read status
    // 3. readBy[] se mantiene para grupos (tienen su propio modelo GroupMessage)
    MessageStatus status;
    if (data['timestamp'] == null) {
      // Sin timestamp del servidor = aún enviando
      status = MessageStatus.sending;
    } else {
      // Con timestamp = enviado al servidor
      // El controller actualizará a seen/delivered según lastOpenedAt_{recipient}
      status = MessageStatus.sent;
    }

    return ChatMessage(
      id: id,
      senderId: data['senderId'] ?? '',
      text: data['text'],
      imageUrl: data['imageUrl'],
      videoUrl: data['videoUrl'],
      audioUrl: data['audioUrl'],
      timestamp: data['timestamp'] as Timestamp?,
      isRead: data['isRead'] ?? false,
      readBy: data['readBy'] != null ? List<String>.from(data['readBy']) : null, // ✅ Parsear readBy
      // ✅ Defensive parsing: handle corrupted data where replyTo/reactions might be List instead of Map
      replyTo: data['replyTo'] is Map ? data['replyTo'] as Map<String, dynamic>? : null,
      reactions: data['reactions'] is Map ? data['reactions'] as Map<String, dynamic>? : null,
      type: data['type'],
      callType: data['callType'],
      callId: data['callId'],
      callDuration: data['callDuration'] as int?,
      status: status,
      moderationStatus: moderationStatus,
      moderationReason: data['moderationReason'] as String?,
      moderationSeverity: data['moderationSeverity'] as String?,
      originalText: data['originalText'] as String?,
      waveformData: data['waveformData'] != null
          ? (data['waveformData'] as List).map((e) => (e as num).toDouble()).toList()
          : null,
      transcription: data['transcription'] as String?,
      isForwarded: data['isForwarded'] ?? false,
      originalSenderId: data['originalSenderId'] as String?,
      originalChatId: data['originalChatId'] as String?,
      originalContactName: data['originalContactName'] as String?,
      localId: data['localId'] as String?, // ✅ Parse localId desde Firestore
      isDeletedForEveryone: data['isDeletedForEveryone'] ?? data['isDeleted'] ?? false, // ✅ Parse deletion flag
      visibleTo: data['visibleTo'] != null
          ? List<String>.from(data['visibleTo'] as List)
          : null,
    );
  }

  /// Debug helper para logging
  static void _debugForwardingFields(String id, Map<String, dynamic> data) {
    // Removed debug logging to reduce noise - only uncomment when debugging forwarding issues
    // final isForwarded = data['isForwarded'] ?? false;
    // final originalContactName = data['originalContactName'] as String?;
    // if (isForwarded) {
    //   if (originalContactName != null) {
    //     ReleaseLogger.log('📥 fromMap: isForwarded=$isForwarded, originalContactName="$originalContactName"', tag: 'ChatMessage');
    //   } else {
    //     ReleaseLogger.warning('fromMap: isForwarded=true pero originalContactName es NULL!', tag: 'ChatMessage');
    //   }
    // }
  }

  /// Factory constructor para mensajes optimistas (pendientes de envío)
  factory ChatMessage.optimistic({
    required String id,
    required String senderId,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    String? localPath,
    Map<String, dynamic>? replyTo,
    String? type,
    List<double>? waveformData,
  }) {
    return ChatMessage(
      id: id,
      localId: id,  // ✅ FIX: Asignar localId para correlacionar con mensaje confirmado
      senderId: senderId,
      text: text,
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      localPath: localPath,
      timestamp: null,  // No tiene timestamp del servidor todavía
      localTimestamp: DateTime.now(),
      isRead: false,
      replyTo: replyTo,
      type: type,
      status: MessageStatus.sending,
      retryCount: 0,
      waveformData: waveformData,
    );
  }

  /// Convertir a Map para Firestore
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'senderId': senderId,
      'isRead': isRead,
      'isForwarded': isForwarded,
    };

    if (text != null) map['text'] = text;
    if (imageUrl != null) map['imageUrl'] = imageUrl;
    if (videoUrl != null) map['videoUrl'] = videoUrl;
    if (audioUrl != null) map['audioUrl'] = audioUrl;
    if (timestamp != null) map['timestamp'] = timestamp;
    if (replyTo != null) map['replyTo'] = replyTo;
    if (reactions != null) map['reactions'] = reactions;
    if (type != null) map['type'] = type;

    // Campos de reenvío
    if (originalSenderId != null) map['originalSenderId'] = originalSenderId;
    if (originalChatId != null) map['originalChatId'] = originalChatId;
    if (originalContactName != null) map['originalContactName'] = originalContactName;

    // ✅ FIX: Incluir localId para deduplicación
    if (localId != null) map['localId'] = localId;

    // ✅ FIX: Incluir moderationStatus para evitar race condition con trigger
    if (moderationStatus != null) {
      map['moderationStatus'] = moderationStatus!.name;
    }

    // Transcripción de audio (de moderación con Whisper)
    if (transcription != null) map['transcription'] = transcription;

    // ✅ Visibilidad por destinatario
    if (visibleTo != null) map['visibleTo'] = visibleTo;

    return map;
  }

  /// Getter para obtener el tiempo formateado
  String get formattedTime {
    if (timestamp == null) return '';
    final date = timestamp!.toDate();
    return '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  /// Getter para verificar si el mensaje tiene contenido multimedia
  bool get hasMedia => imageUrl != null || videoUrl != null || audioUrl != null;

  /// Getter para obtener el tipo de contenido
  /// IMPORTANTE: Usa el campo 'type' de Firestore/Hive como fuente primaria
  /// porque las URLs pueden ser null si el archivo fue eliminado por TTL
  String get contentType {
    // 1. Usar type de Firestore/Hive si está disponible (más confiable)
    if (type != null && type!.isNotEmpty) return type!;

    // 2. Fallback: derivar de URLs
    if (imageUrl != null) return 'image';
    if (videoUrl != null) return 'video';
    if (audioUrl != null) return 'audio';

    // 3. Fallback final: texto
    if (text != null && text!.isNotEmpty) return 'text';
    return 'unknown';
  }

  /// Getter para obtener el preview del mensaje (para lista de chats)
  String get preview {
    switch (contentType) {
      case 'image':
        return '📷 Imagen';
      case 'video':
        return '🎥 Video';
      case 'audio':
        return '🎤 Audio';
      case 'text':
        return text ?? '';
      default:
        return '';
    }
  }

  /// Verifica si el mensaje tiene reacciones
  bool get hasReactions => reactions != null && reactions!.isNotEmpty;

  /// Obtiene el total de reacciones
  int get totalReactions {
    if (!hasReactions) return 0;
    return reactions!.values.fold<int>(
      0,
      (total, users) => total + (users as List).length,
    );
  }

  /// Verifica si un usuario ha reaccionado con un emoji específico
  bool hasUserReacted(String userId, String reaction) {
    if (!hasReactions) return false;
    final users = reactions![reaction] as List?;
    return users?.contains(userId) ?? false;
  }

  /// Verifica si el mensaje es del usuario especificado
  bool isFromUser(String userId) => senderId == userId;

  @override
  String toString() {
    return 'ChatMessage(id: $id, senderId: $senderId, type: $contentType, time: $formattedTime)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatMessage && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  /// Copia el mensaje con algunos campos actualizados
  ChatMessage copyWith({
    String? id,
    String? senderId,
    String? text,
    String? imageUrl,
    String? videoUrl,
    String? audioUrl,
    String? localPath,
    Timestamp? timestamp,
    bool? isRead,
    Map<String, dynamic>? replyTo,
    Map<String, dynamic>? reactions,
    String? type,
    String? callType,
    String? callId,
    MessageStatus? status,
    DateTime? localTimestamp,
    int? retryCount,
    ModerationStatus? moderationStatus,
    String? moderationReason,
    String? moderationSeverity,
    String? originalText,
    List<double>? waveformData,
    String? transcription,
    String? localId, // ✅ FIX: Agregar localId como parámetro
    bool? isDeletedForEveryone, // ✅ Agregar isDeletedForEveryone
    List<String>? visibleTo,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      localPath: localPath ?? this.localPath,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      replyTo: replyTo ?? this.replyTo,
      reactions: reactions ?? this.reactions,
      type: type ?? this.type,
      callType: callType ?? this.callType,
      callId: callId ?? this.callId,
      status: status ?? this.status,
      localTimestamp: localTimestamp ?? this.localTimestamp,
      retryCount: retryCount ?? this.retryCount,
      moderationStatus: moderationStatus ?? this.moderationStatus,
      moderationReason: moderationReason ?? this.moderationReason,
      moderationSeverity: moderationSeverity ?? this.moderationSeverity,
      originalText: originalText ?? this.originalText,
      waveformData: waveformData ?? this.waveformData,
      transcription: transcription ?? this.transcription,
      // Preservar campos de reenvío
      isForwarded: isForwarded,
      originalSenderId: originalSenderId,
      originalChatId: originalChatId,
      originalContactName: originalContactName,
      localId: localId ?? this.localId, // ✅ FIX: Usar valor pasado o preservar actual
      isDeletedForEveryone: isDeletedForEveryone ?? this.isDeletedForEveryone,
      visibleTo: visibleTo ?? this.visibleTo,
    );
  }

  /// Indica si este mensaje es visible para el usuario dado.
  /// Si `visibleTo` es null se considera visible para todos (backwards compat).
  bool isVisibleTo(String userId) =>
      visibleTo == null || visibleTo!.contains(userId);

  /// Getter para obtener el timestamp efectivo (servidor o local)
  /// ✅ Devuelve en timezone local del usuario
  DateTime get effectiveTimestamp {
    if (timestamp != null) return timestamp!.toDate().toLocal();
    return localTimestamp?.toLocal() ?? DateTime.now();
  }

  /// Getter para verificar si el mensaje está pendiente
  bool get isPending => status == MessageStatus.sending;

  /// Getter para verificar si el mensaje tiene error
  bool get hasError => status == MessageStatus.error;

  /// Getter para verificar si el mensaje fue enviado
  bool get isSent => status == MessageStatus.sent;

  /// Getter para verificar si el mensaje está bloqueado por moderación
  bool get isBlocked => moderationStatus == ModerationStatus.blocked;

  /// Getter para verificar si el mensaje está aprobado por moderación
  bool get isApproved => moderationStatus == ModerationStatus.approved || moderationStatus == null;

  /// Getter para verificar si el mensaje está en revisión
  bool get isPendingReview => moderationStatus == ModerationStatus.pending;
}
