import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';

/// Controller para la configuración de moderación de chats
///
/// Responsabilidades:
/// - Cargar configuración actual de moderación
/// - Togglear activación/desactivación de moderación
/// - Cambiar nivel de moderación (alto/medio/bajo)
/// - Obtener historial de mensajes bloqueados
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ChatModerationSettingsController {
  final String chatId;
  final String contactName;

  // Servicios privados
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  bool _isInitialized = false;
  String? _currentUserId;
  String? _contactId;
  String? _childId; // El hijo cuyo chat estamos moderando
  String? _contactDocumentId;

  /// Constructor
  ChatModerationSettingsController({
    required this.chatId,
    required this.contactName,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para información del usuario actual
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  String? get contactId => _contactId;
  bool get isInitialized => _isInitialized;

  /// Inicializar el controller y encontrar el contactId
  Future<void> initialize() async {
    try {
      ReleaseLogger.log('Inicializando ChatModerationSettingsController para chat: $chatId', tag: 'ChatModeration');

      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado', tag: 'ChatModeration');
        return;
      }

      // Obtener el contactId del chat
      await _loadContactInfo();

      _isInitialized = true;
      ReleaseLogger.log('ChatModerationSettingsController inicializado exitosamente', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error inicializando ChatModerationSettingsController: $e', tag: 'ChatModeration');
    }
  }

  /// Cargar información del contacto desde el chat
  /// Identifica quién es el hijo (de los linkedChildrenIds del padre) y quién es el contacto
  Future<void> _loadContactInfo() async {
    try {
      // El chatId tiene formato "userId1_userId2" (ordenados alfabéticamente)
      final participants = chatId.split('_');
      if (participants.length != 2) {
        throw Exception('Formato de chatId inválido');
      }

      // Obtener los hijos vinculados del padre actual
      final parentDoc = await _firestore.collection('users').doc(_currentUserId).get();
      final linkedChildrenIds = List<String>.from(parentDoc.data()?['linkedChildrenIds'] ?? []);

      ReleaseLogger.log('Padre $_currentUserId tiene hijos vinculados: $linkedChildrenIds', tag: 'ChatModeration');
      ReleaseLogger.log('Participantes del chat: $participants', tag: 'ChatModeration');

      // Determinar quién es el hijo y quién es el contacto
      // El hijo es uno de los participantes que está en linkedChildrenIds
      for (final participantId in participants) {
        if (linkedChildrenIds.contains(participantId)) {
          _childId = participantId;
          _contactId = participants.firstWhere((id) => id != participantId);
          break;
        }
      }

      // Si no encontramos un hijo vinculado, podría ser que el padre está viendo su propio chat
      if (_childId == null) {
        // Verificar si el padre es uno de los participantes
        if (participants.contains(_currentUserId)) {
          _childId = _currentUserId; // En este caso, "el hijo" es el padre mismo
          _contactId = participants.firstWhere((id) => id != _currentUserId);
        } else {
          throw Exception('No tienes permiso para moderar este chat');
        }
      }

      ReleaseLogger.log('ChildId: $_childId, ContactId: $_contactId', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error cargando información del contacto: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Cargar configuración actual de moderación
  Future<Map<String, dynamic>> loadModerationSettings() async {
    try {
      if (_currentUserId == null || _contactId == null || _childId == null) {
        await initialize();
      }

      if (_currentUserId == null || _contactId == null || _childId == null) {
        throw Exception('Usuario, contacto o hijo no encontrado');
      }

      // Leer la configuración del chat directamente
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();

      if (!chatDoc.exists) {
        ReleaseLogger.log('Chat no existe aún, usando configuración por defecto', tag: 'ChatModeration');
        return {
          'enabled': false,
          'level': 'high',
        };
      }

      final chatData = chatDoc.data() ?? {};

      return {
        'enabled': chatData['moderationEnabled'] ?? false,
        'level': chatData['moderationLevel'] ?? 'high',
      };
    } catch (e) {
      ReleaseLogger.error('Error cargando configuración de moderación: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Activar o desactivar moderación usando Cloud Function
  Future<void> toggleModeration(bool enabled, String moderationLevel) async {
    try {
      if (_childId == null || _contactId == null) {
        throw Exception('Hijo o contacto no encontrado');
      }

      ReleaseLogger.log('Llamando Cloud Function para ${enabled ? "activar" : "desactivar"} moderación', tag: 'ChatModeration');
      ReleaseLogger.log('childId: $_childId, contactId: $_contactId, chatId: $chatId', tag: 'ChatModeration');

      // Usar Cloud Function para evitar problemas de permisos
      final callable = FirebaseFunctions.instance.httpsCallable('updateChildContactModeration');
      final result = await callable.call({
        'childId': _childId,
        'contactId': _contactId,
        'chatId': chatId,
        'enabled': enabled,
        'level': moderationLevel,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception('Error al actualizar moderación: ${data['message'] ?? 'Unknown error'}');
      }

      ReleaseLogger.log('Moderación ${enabled ? 'activada' : 'desactivada'} para contacto $_contactId', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error al actualizar moderación: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Cambiar nivel de moderación usando Cloud Function
  Future<void> changeModerationLevel(String newLevel) async {
    try {
      if (_childId == null || _contactId == null) {
        throw Exception('Hijo o contacto no encontrado');
      }

      ReleaseLogger.log('Cambiando nivel de moderación a: $newLevel', tag: 'ChatModeration');

      // Usar Cloud Function para evitar problemas de permisos
      final callable = FirebaseFunctions.instance.httpsCallable('updateChildContactModeration');
      final result = await callable.call({
        'childId': _childId,
        'contactId': _contactId,
        'chatId': chatId,
        'enabled': true, // Mantenemos activado al cambiar nivel
        'level': newLevel,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception('Error al cambiar nivel: ${data['message'] ?? 'Unknown error'}');
      }

      ReleaseLogger.log('Nivel de moderación cambiado a: $newLevel', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error al cambiar nivel de moderación: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Stream de mensajes bloqueados para el historial
  Stream<QuerySnapshot> getBlockedMessagesStream() {
    try {
      return _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .where('moderationStatus', isEqualTo: 'blocked')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de mensajes bloqueados: $e', tag: 'ChatModeration');
      // Retornar stream vacío en caso de error
      return Stream.value(FirebaseFirestore.instance.collection('_empty').snapshots() as QuerySnapshot);
    }
  }

  /// Verificar si un mensaje es del contacto o del hijo
  bool isMessageFromContact(Map<String, dynamic> messageData) {
    final senderId = messageData['senderId'] as String?;
    return senderId != _childId;
  }

  /// Formatear timestamp para mostrar
  String formatTimestamp(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return 'Hoy ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Ayer ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} días atrás';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  /// Obtener color según severidad
  /// Nota: Esto podría moverse a un utils helper, pero por simplicidad lo dejamos aquí
  String getSeverityColorName(String severity) {
    switch (severity) {
      case 'high':
        return 'red';
      case 'medium':
        return 'orange';
      case 'low':
        return 'yellow';
      default:
        return 'grey';
    }
  }

  /// Obtener etiqueta según severidad
  String getSeverityLabel(String severity) {
    switch (severity) {
      case 'high':
        return 'ALTA';
      case 'medium':
        return 'MEDIA';
      case 'low':
        return 'BAJA';
      default:
        return 'N/A';
    }
  }

  /// Obtener descripción del nivel de moderación
  String getModerationLevelDescription(String level) {
    switch (level) {
      case 'high':
        return '⚠️ Modo Alto (MUY RESTRICTIVO): Bloquea insultos, palabrotas Y expresiones como "qué pesado", "no seas exagerado", etc. Solo permite conversación completamente cordial y educada. Puede bloquear conversación normal entre amigos/familia.';
      case 'medium':
        return '✅ Modo Medio (RECOMENDADO): Equilibrio perfecto. Bloquea insultos directos, palabrotas y contenido sexual, pero permite lenguaje coloquial normal, sarcasmo e ironía sin insultos. Ideal para la mayoría de casos.';
      case 'low':
        return 'Modo Bajo (PERMISIVO): Solo bloquea contenido muy severo como amenazas serias, contenido sexual explícito o grooming. Muy permisivo con el tono y lenguaje coloquial entre adultos.';
      default:
        return 'Nivel no reconocido';
    }
  }

  /// Verificar que el usuario esté autenticado
  bool get isUserAuthenticated => _currentUserId != null;

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChatModerationSettingsController', tag: 'ChatModeration');
    _isInitialized = false;
  }
}