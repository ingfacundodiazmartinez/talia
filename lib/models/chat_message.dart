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
  final Map<String, dynamic>? replyTo;
  final Map<String, dynamic>? reactions;
  final String? type; // 'text', 'image', 'video', 'audio', 'missed_call', etc.

  // Campos para llamadas
  final String? callType; // 'video' o 'audio'
  final String? callId; // ID de la llamada en Firestore
  final int? callDuration; // Duración de la llamada en segundos (solo para answered_call)

  // Nuevos campos para optimistic updates
  final MessageStatus status;
  final DateTime? localTimestamp;  // Timestamp local para ordenar mientras se envía
  final int? retryCount;           // Contador de reintentos
  final String? localPath;         // Path local del archivo (para preview mientras se sube)

  // Campos para moderación con IA
  final ModerationStatus? moderationStatus;  // Estado de moderación
  final String? moderationReason;            // Razón del bloqueo/alerta
  final String? moderationSeverity;          // Severidad: none, low, medium, high
  final String? originalText;                // Texto original antes de ser bloqueado

  // Campos para audio
  final List<double>? waveformData;          // Datos de forma de onda para audio

  // Campos para mensajes reenviados
  final bool isForwarded;                    // Indica si el mensaje fue reenviado
  final String? originalSenderId;            // ID del remitente original
  final String? originalChatId;              // ID del chat original
  final String? originalContactName;         // Nombre del contacto original

  // ✅ Campo para matching de mensajes optimistas
  final String? localId;                     // ID temporal del mensaje optimista (para reemplazo)

  ChatMessage({
    required this.id,
    required this.senderId,
    this.text,
    this.imageUrl,
    this.videoUrl,
    this.audioUrl,
    this.timestamp,
    this.isRead = false,
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
    this.isForwarded = false,
    this.originalSenderId,
    this.originalChatId,
    this.originalContactName,
    this.localId, // ✅ Agregar localId
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

    // Calcular el status del mensaje basándose en readBy
    MessageStatus status = MessageStatus.sent; // Por defecto

    // Solo calcular status si es un mensaje propio
    if (currentUserId != null && data['senderId'] == currentUserId) {
      final readBy = List<String>.from(data['readBy'] ?? []);

      // Si readBy contiene a otros usuarios (no solo a mí), el mensaje fue visto
      final othersRead = readBy.where((userId) => userId != currentUserId).isNotEmpty;

      if (othersRead) {
        status = MessageStatus.seen;
      } else {
        // Podríamos distinguir entre 'sent' y 'delivered' aquí si tuviéramos ese campo
        status = MessageStatus.sent;
      }
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
      replyTo: data['replyTo'] as Map<String, dynamic>?,
      reactions: data['reactions'] as Map<String, dynamic>?,
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
      isForwarded: data['isForwarded'] ?? false,
      originalSenderId: data['originalSenderId'] as String?,
      originalChatId: data['originalChatId'] as String?,
      originalContactName: data['originalContactName'] as String?,
      localId: data['localId'] as String?, // ✅ Parse localId desde Firestore
    );
  }

  /// Debug helper para logging
  static void _debugForwardingFields(String id, Map<String, dynamic> data) {
    final isForwarded = data['isForwarded'] ?? false;
    final originalContactName = data['originalContactName'] as String?;
    if (isForwarded) {
      if (originalContactName != null) {
        print('📥 fromMap(${id.substring(0, 8)}...): isForwarded=$isForwarded, originalContactName="$originalContactName" ✅');
      } else {
        print('⚠️ fromMap(${id.substring(0, 8)}...): isForwarded=$isForwarded pero originalContactName es NULL!');
      }
    }
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
  String get contentType {
    if (imageUrl != null) return 'image';
    if (videoUrl != null) return 'video';
    if (audioUrl != null) return 'audio';
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
      (sum, users) => sum + (users as List).length,
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
      // Preservar campos de reenvío
      isForwarded: this.isForwarded,
      originalSenderId: this.originalSenderId,
      originalChatId: this.originalChatId,
      originalContactName: this.originalContactName,
      localId: this.localId, // ✅ Preservar localId en copyWith
    );
  }

  /// Getter para obtener el timestamp efectivo (servidor o local)
  DateTime get effectiveTimestamp {
    if (timestamp != null) return timestamp!.toDate();
    return localTimestamp ?? DateTime.now();
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
