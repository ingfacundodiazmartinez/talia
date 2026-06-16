import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'location_service.dart';
import 'chats/chat_orchestrator.dart';
import 'chats/services/chat_messaging_service.dart' show MessageType;
import '../utils/release_logger.dart';

/// Servicio de "compartir ubicación" en los chats (tipo WhatsApp).
///
/// Dos modos:
/// - Estático: un único punto (`shareStaticLocation`).
/// - En vivo: la posición se actualiza en tiempo real durante un período
///   (`startLiveShare`) hasta que expira o el usuario la detiene.
///
/// Modelo de datos:
/// - Mensaje `type == 'location'` en `{col}/{chatId}/messages` con lat/lng +
///   (si live) `isLiveLocation` y `liveLocationExpiresAt`.
/// - Sesión en vivo en `{col}/{chatId}/live_locations/{senderId}`:
///   `{ latitude, longitude, heading, updatedAt, expiresAt, active, messageId }`.
///   El sender la actualiza; los participantes la escuchan.
class LiveLocationService {
  static final LiveLocationService _instance = LiveLocationService._internal();
  factory LiveLocationService() => _instance;
  LiveLocationService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final LocationService _locationService = LocationService();
  final ChatOrchestrator _chatOrchestrator = ChatOrchestrator();

  // Sesiones en vivo activas que ESTE dispositivo está emitiendo, por chatId.
  final Map<String, _ActiveLiveShare> _activeShares = {};

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  String _collection(bool isGroup) => isGroup ? 'groups_v2' : 'chats';

  /// ¿Estoy compartiendo en vivo en este chat ahora mismo?
  bool isSharingLive(String chatId) => _activeShares.containsKey(chatId);

  // ═══════════════════════════════════════════════════════════════
  // ENVÍO
  // ═══════════════════════════════════════════════════════════════

  /// Compartir ubicación actual (un punto, sin actualizaciones).
  /// Retorna true si se envió.
  Future<bool> shareStaticLocation({
    required String chatId,
    required bool isGroup,
  }) async {
    final pos = await _locationService.getCurrentLocation();
    if (pos == null) return false;
    return _sendLocationMessage(
      chatId: chatId,
      isGroup: isGroup,
      position: pos,
      isLive: false,
      expiresAt: null,
    );
  }

  /// Empezar a compartir ubicación EN VIVO por [duration].
  /// Envía el mensaje, crea la sesión y arranca el stream de actualización.
  Future<bool> startLiveShare({
    required String chatId,
    required bool isGroup,
    required Duration duration,
  }) async {
    final uid = _uid;
    if (uid == null) return false;

    final pos = await _locationService.getCurrentLocation();
    if (pos == null) return false;

    // serverTimestamp no se puede sumar client-side; usamos el reloj local
    // para expiresAt (suficiente para una ventana de minutos/horas).
    final expiresAt = Timestamp.fromDate(DateTime.now().add(duration));

    final messageId = await _sendLocationMessageReturningId(
      chatId: chatId,
      isGroup: isGroup,
      position: pos,
      isLive: true,
      expiresAt: expiresAt,
    );
    if (messageId == null) return false;

    // Crear/actualizar el doc de sesión en vivo.
    final sessionRef = _firestore
        .collection(_collection(isGroup))
        .doc(chatId)
        .collection('live_locations')
        .doc(uid);

    await sessionRef.set({
      'senderId': uid,
      'latitude': pos.latitude,
      'longitude': pos.longitude,
      'heading': pos.heading,
      'updatedAt': FieldValue.serverTimestamp(),
      'expiresAt': expiresAt,
      'active': true,
      'messageId': messageId,
    });

    // Stream de posición → actualiza el doc de sesión.
    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((p) {
      sessionRef.update({
        'latitude': p.latitude,
        'longitude': p.longitude,
        'heading': p.heading,
        'updatedAt': FieldValue.serverTimestamp(),
      }).catchError((_) {});
    });

    // Auto-stop al expirar.
    final timer = Timer(duration, () => stopLiveShare(chatId: chatId, isGroup: isGroup));

    _activeShares[chatId] = _ActiveLiveShare(
      subscription: sub,
      timer: timer,
      sessionRef: sessionRef,
      isGroup: isGroup,
    );

    ReleaseLogger.log('📍 Live share iniciado en $chatId por ${duration.inMinutes}min', tag: 'LiveLocation');
    return true;
  }

  /// Detener una sesión en vivo activa (manual o por expiración).
  Future<void> stopLiveShare({
    required String chatId,
    required bool isGroup,
  }) async {
    final share = _activeShares.remove(chatId);
    if (share == null) return;
    await share.subscription.cancel();
    share.timer.cancel();
    try {
      await share.sessionRef.update({
        'active': false,
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
    ReleaseLogger.log('📍 Live share detenido en $chatId', tag: 'LiveLocation');
  }

  // ═══════════════════════════════════════════════════════════════
  // RECEPCIÓN
  // ═══════════════════════════════════════════════════════════════

  /// Escuchar la sesión en vivo de [senderId] en [chatId]. Emite null si no
  /// hay sesión o ya no está activa/expiró.
  Stream<LiveLocationSnapshot?> watchSession({
    required String chatId,
    required String senderId,
    required bool isGroup,
  }) {
    return _firestore
        .collection(_collection(isGroup))
        .doc(chatId)
        .collection('live_locations')
        .doc(senderId)
        .snapshots()
        .map((doc) {
      if (!doc.exists) return null;
      final data = doc.data()!;
      final expiresAt = data['expiresAt'] as Timestamp?;
      final active = data['active'] as bool? ?? false;
      final expired = expiresAt != null && expiresAt.toDate().isBefore(DateTime.now());
      if (!active || expired) return null;
      return LiveLocationSnapshot(
        latitude: (data['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (data['longitude'] as num?)?.toDouble() ?? 0,
        heading: (data['heading'] as num?)?.toDouble(),
        updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
        expiresAt: expiresAt?.toDate(),
      );
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // INTERNAL
  // ═══════════════════════════════════════════════════════════════

  Future<bool> _sendLocationMessage({
    required String chatId,
    required bool isGroup,
    required Position position,
    required bool isLive,
    required Timestamp? expiresAt,
  }) async {
    final id = await _sendLocationMessageReturningId(
      chatId: chatId,
      isGroup: isGroup,
      position: position,
      isLive: isLive,
      expiresAt: expiresAt,
    );
    return id != null;
  }

  Future<String?> _sendLocationMessageReturningId({
    required String chatId,
    required bool isGroup,
    required Position position,
    required bool isLive,
    required Timestamp? expiresAt,
  }) async {
    final metadata = <String, dynamic>{
      'latitude': position.latitude,
      'longitude': position.longitude,
      'isLiveLocation': isLive,
      if (expiresAt != null)
        'liveLocationExpiresAt': expiresAt.millisecondsSinceEpoch,
    };

    if (isGroup) {
      return _sendGroupLocation(chatId, position, isLive, expiresAt);
    }

    // 1:1 → reutiliza el pipeline (visibleTo/moderación/optimistic/cache).
    return _chatOrchestrator.sendMessage(
      chatId: chatId,
      content: '',
      type: MessageType.location,
      metadata: metadata,
    );
  }

  /// Envío de ubicación en un grupo: escritura directa al doc de mensaje +
  /// metadata del grupo. Los grupos no usan el pipeline 1:1.
  Future<String?> _sendGroupLocation(
    String groupId,
    Position position,
    bool isLive,
    Timestamp? expiresAt,
  ) async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final senderName = userDoc.data()?['name'] as String? ?? 'Usuario';
      final senderPhotoURL = userDoc.data()?['photoURL'] as String?;

      final batch = _firestore.batch();
      final messageRef = _firestore
          .collection('groups_v2')
          .doc(groupId)
          .collection('messages')
          .doc();

      batch.set(messageRef, {
        'senderId': uid,
        'senderName': senderName,
        'senderPhotoURL': senderPhotoURL,
        'type': 'location',
        'latitude': position.latitude,
        'longitude': position.longitude,
        if (isLive) 'isLiveLocation': true,
        if (expiresAt != null) 'liveLocationExpiresAt': expiresAt,
        'timestamp': FieldValue.serverTimestamp(),
        'isDeleted': false,
        'reactions': <String, dynamic>{},
        'readBy': [uid],
      });

      batch.update(_firestore.collection('groups_v2').doc(groupId), {
        'lastMessage': isLive ? '📍 Ubicación en tiempo real' : '📍 Ubicación',
        'lastMessageType': 'location',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': uid,
        'lastMessageId': messageRef.id,
        'lastActivity': FieldValue.serverTimestamp(),
      });

      await batch.commit();
      return messageRef.id;
    } catch (e) {
      ReleaseLogger.error('Error enviando ubicación a grupo: $e', tag: 'LiveLocation');
      return null;
    }
  }

  void dispose() {
    for (final s in _activeShares.values) {
      s.subscription.cancel();
      s.timer.cancel();
    }
    _activeShares.clear();
  }
}

class _ActiveLiveShare {
  final StreamSubscription<Position> subscription;
  final Timer timer;
  final DocumentReference sessionRef;
  final bool isGroup;
  _ActiveLiveShare({
    required this.subscription,
    required this.timer,
    required this.sessionRef,
    required this.isGroup,
  });
}

/// Posición de una sesión en vivo, ya filtrada por activa/no expirada.
class LiveLocationSnapshot {
  final double latitude;
  final double longitude;
  final double? heading;
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  LiveLocationSnapshot({
    required this.latitude,
    required this.longitude,
    this.heading,
    this.updatedAt,
    this.expiresAt,
  });
}
