import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Estados posibles de una llamada desde la perspectiva del usuario actual
enum CallState {
  connecting,
  incomingVideo,
  incomingAudio,
  activeVideo,
  activeAudio,
  ended,
  error,
}

/// Helper function para manejar tanto Timestamp como String de Firestore
DateTime _parseDateTime(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  } else if (value is String) {
    return DateTime.parse(value);
  } else {
    throw ArgumentError('Expected Timestamp or String, got ${value.runtimeType}');
  }
}

/// Helper function para manejar fechas opcionales
DateTime? _parseOptionalDateTime(dynamic value) {
  if (value == null) return null;
  return _parseDateTime(value);
}

/// Modelo para la nueva arquitectura de calls unificada
///
/// Esta clase reemplaza video_calls para manejar tanto llamadas 1-1 como grupales
/// con estados sincronizados en tiempo real para todos los participantes
class Call {
  final String id;
  final String type; // 'video' | 'audio'
  final String channelName;
  final String? token;
  final String createdBy;
  final DateTime createdAt;
  final Map<String, CallParticipant> participants;
  final DateTime? endedAt;

  const Call({
    required this.id,
    required this.type,
    required this.channelName,
    this.token,
    required this.createdBy,
    required this.createdAt,
    required this.participants,
    this.endedAt,
  });

  /// Crear desde documento Firestore
  /// ✅ FIXED: Maneja tanto Timestamp como String de Firestore
  /// ✅ UPDATED: Usa participantDetails (mapa) en lugar de participants (array)
  factory Call.fromFirestore(String id, Map<String, dynamic> data) {
    // ✅ FIX ÍNDICE FIRESTORE: Usar participantDetails para estados individuales
    // participants ahora es un array para consultas, participantDetails contiene los estados
    final participantsData = data['participantDetails'] as Map<String, dynamic>;
    final participants = <String, CallParticipant>{};

    for (final entry in participantsData.entries) {
      participants[entry.key] = CallParticipant.fromMap(entry.value as Map<String, dynamic>);
    }

    return Call(
      id: id,
      type: data['type'] as String,
      channelName: data['channelName'] as String,
      token: data['token'] as String?,
      createdBy: data['createdBy'] as String,
      createdAt: _parseDateTime(data['createdAt']), // ✅ Handles Timestamp/String
      participants: participants,
      endedAt: _parseOptionalDateTime(data['endedAt']), // ✅ Handles Timestamp/String/null
    );
  }

  /// Convertir a mapa para Firestore
  /// ✅ UPDATED: Usa modelo híbrido (array + mapa) para resolver índice Firestore
  Map<String, dynamic> toFirestore() {
    final participantsMap = <String, dynamic>{};
    for (final entry in participants.entries) {
      participantsMap[entry.key] = entry.value.toMap();
    }

    return {
      'type': type,
      'channelName': channelName,
      'token': token,
      'createdBy': createdBy,
      'createdAt': createdAt.toIso8601String(),
      'participants': participants.keys.toList(), // ✅ Array para consultas eficientes
      'participantDetails': participantsMap,       // ✅ Mapa para estados individuales
      'endedAt': endedAt?.toIso8601String(),
    };
  }

  /// Obtener participantes activos (waiting o joined)
  List<String> get activeParticipantIds {
    return participants.entries
        .where((entry) => ['waiting', 'joined'].contains(entry.value.status))
        .map((entry) => entry.key)
        .toList();
  }

  /// Obtener participantes unidos
  List<String> get joinedParticipantIds {
    return participants.entries
        .where((entry) => entry.value.status == 'joined')
        .map((entry) => entry.key)
        .toList();
  }

  /// Verificar si la llamada está activa
  bool get isActive {
    return activeParticipantIds.length >= 2 && endedAt == null;
  }

  /// Verificar si la llamada debe terminarse automáticamente
  bool get shouldEnd {
    // Si quedan menos de 2 participantes activos O algún participante ya terminó
    return activeParticipantIds.length < 2 ||
           participants.values.any((p) => p.status == 'ended');
  }

  /// Determinar el estado de la llamada para el usuario actual
  CallState getStateForUser(String userId) {
    // Verificar si el usuario está en la llamada
    final participant = participants[userId];
    if (participant == null) {
      return CallState.error;
    }

    // Si la llamada ya terminó
    if (endedAt != null) {
      return CallState.ended;
    }

    final isVideo = type == 'video';
    final isCaller = createdBy == userId;

    // Si es el creador de la llamada, siempre va directo a activa
    if (isCaller) {
      return isVideo ? CallState.activeVideo : CallState.activeAudio;
    }

    // Para receptores, depende del estado del participante
    switch (participant.status) {
      case 'waiting':
        return isVideo ? CallState.incomingVideo : CallState.incomingAudio;
      case 'joined':
        return isVideo ? CallState.activeVideo : CallState.activeAudio;
      case 'declined':
      case 'ended':
      case 'busy':
      default:
        return CallState.ended;
    }
  }

  /// Crear copia con parámetros modificados
  Call copyWith({
    String? id,
    String? type,
    String? channelName,
    String? token,
    String? createdBy,
    DateTime? createdAt,
    Map<String, CallParticipant>? participants,
    DateTime? endedAt,
  }) {
    return Call(
      id: id ?? this.id,
      type: type ?? this.type,
      channelName: channelName ?? this.channelName,
      token: token ?? this.token,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      participants: participants ?? this.participants,
      endedAt: endedAt ?? this.endedAt,
    );
  }

  @override
  String toString() {
    return 'Call(id: $id, type: $type, participants: ${participants.length}, active: $isActive)';
  }
}

/// Modelo para participante en una llamada
class CallParticipant {
  final String status; // 'waiting' | 'joined' | 'declined' | 'ended' | 'busy'
  final DateTime? waitingAt;
  final DateTime? joinedAt;
  final DateTime? declinedAt;
  final DateTime? endedAt;
  final String? declineReason;

  const CallParticipant({
    required this.status,
    this.waitingAt,
    this.joinedAt,
    this.declinedAt,
    this.endedAt,
    this.declineReason,
  });

  /// Crear desde mapa Firestore
  /// ✅ FIXED: Maneja tanto Timestamp como String de Firestore
  factory CallParticipant.fromMap(Map<String, dynamic> data) {
    return CallParticipant(
      status: data['status'] as String,
      waitingAt: _parseOptionalDateTime(data['waitingAt']), // ✅ Handles Timestamp/String/null
      joinedAt: _parseOptionalDateTime(data['joinedAt']), // ✅ Handles Timestamp/String/null
      declinedAt: _parseOptionalDateTime(data['declinedAt']), // ✅ Handles Timestamp/String/null
      endedAt: _parseOptionalDateTime(data['endedAt']), // ✅ Handles Timestamp/String/null
      declineReason: data['declineReason'] as String?,
    );
  }

  /// Convertir a mapa para Firestore
  Map<String, dynamic> toMap() {
    return {
      'status': status,
      'waitingAt': waitingAt?.toIso8601String(),
      'joinedAt': joinedAt?.toIso8601String(),
      'declinedAt': declinedAt?.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'declineReason': declineReason,
    };
  }

  /// Crear participante en estado waiting
  factory CallParticipant.waiting() {
    return CallParticipant(
      status: 'waiting',
      waitingAt: DateTime.now(),
    );
  }

  /// Crear participante en estado joined (creator)
  factory CallParticipant.joined() {
    return CallParticipant(
      status: 'joined',
      joinedAt: DateTime.now(),
    );
  }

  /// Crear copia con nuevo estado
  CallParticipant copyWith({
    String? status,
    DateTime? waitingAt,
    DateTime? joinedAt,
    DateTime? declinedAt,
    DateTime? endedAt,
    String? declineReason,
  }) {
    return CallParticipant(
      status: status ?? this.status,
      waitingAt: waitingAt ?? this.waitingAt,
      joinedAt: joinedAt ?? this.joinedAt,
      declinedAt: declinedAt ?? this.declinedAt,
      endedAt: endedAt ?? this.endedAt,
      declineReason: declineReason ?? this.declineReason,
    );
  }

  /// Transiciones de estado válidas
  CallParticipant accept() {
    return copyWith(
      status: 'joined',
      joinedAt: DateTime.now(),
    );
  }

  CallParticipant decline({String? reason}) {
    return copyWith(
      status: 'declined',
      declinedAt: DateTime.now(),
      declineReason: reason,
    );
  }

  CallParticipant end() {
    return copyWith(
      status: 'ended',
      endedAt: DateTime.now(),
    );
  }

  @override
  String toString() {
    return 'CallParticipant(status: $status)';
  }
}