import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
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
  Future<void> _loadContactInfo() async {
    try {
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (!chatDoc.exists) {
        throw Exception('Chat no encontrado');
      }

      final participants = List<String>.from(chatDoc.data()?['participants'] ?? []);
      _contactId = participants.firstWhere((id) => id != _currentUserId, orElse: () => '');

      if (_contactId!.isEmpty) {
        throw Exception('Contacto no encontrado en el chat');
      }

      ReleaseLogger.log('ContactId encontrado: $_contactId', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error cargando información del contacto: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Cargar configuración actual de moderación
  Future<Map<String, dynamic>> loadModerationSettings() async {
    try {
      if (_currentUserId == null || _contactId == null) {
        await initialize();
      }

      if (_currentUserId == null || _contactId == null) {
        throw Exception('Usuario o contacto no encontrado');
      }

      // Buscar el documento de contacto
      final sortedUsers = [_currentUserId!, _contactId!]..sort();
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', isEqualTo: sortedUsers)
          .limit(1)
          .get();

      if (contactsQuery.docs.isEmpty) {
        ReleaseLogger.warning('Documento de contacto no encontrado, creando configuración por defecto', tag: 'ChatModeration');
        return {
          'enabled': false,
          'level': 'high',
        };
      }

      final contactDoc = contactsQuery.docs.first;
      _contactDocumentId = contactDoc.id;

      final contactData = contactDoc.data();
      final moderationSettings = contactData['moderationSettings'] as Map<String, dynamic>? ?? {};
      final userSettings = moderationSettings[_currentUserId!] as Map<String, dynamic>? ?? {};

      return {
        'enabled': userSettings['enabled'] ?? false,
        'level': userSettings['level'] ?? 'high',
      };
    } catch (e) {
      ReleaseLogger.error('Error cargando configuración de moderación: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Activar o desactivar moderación
  Future<void> toggleModeration(bool enabled, String moderationLevel) async {
    try {
      if (_currentUserId == null || _contactId == null) {
        throw Exception('Usuario o contacto no encontrado');
      }

      // Buscar el documento de contacto si no está cacheado
      if (_contactDocumentId == null) {
        final sortedUsers = [_currentUserId!, _contactId!]..sort();
        final contactsQuery = await _firestore
            .collection('contacts')
            .where('users', isEqualTo: sortedUsers)
            .limit(1)
            .get();

        if (contactsQuery.docs.isEmpty) {
          throw Exception('Documento de contacto no encontrado');
        }

        _contactDocumentId = contactsQuery.docs.first.id;
      }

      // Actualizar configuración de moderación
      await _firestore.collection('contacts').doc(_contactDocumentId!).update({
        'moderationSettings.$_currentUserId.enabled': enabled,
        'moderationSettings.$_currentUserId.level': moderationLevel,
        'moderationSettings.$_currentUserId.${enabled ? 'enabledAt' : 'disabledAt'}': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('Moderación ${enabled ? 'activada' : 'desactivada'} para contacto $_contactId', tag: 'ChatModeration');
    } catch (e) {
      ReleaseLogger.error('Error al actualizar moderación: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Cambiar nivel de moderación
  Future<void> changeModerationLevel(String newLevel) async {
    try {
      if (_currentUserId == null || _contactId == null) {
        throw Exception('Usuario o contacto no encontrado');
      }

      // Buscar el documento de contacto si no está cacheado
      if (_contactDocumentId == null) {
        final sortedUsers = [_currentUserId!, _contactId!]..sort();
        final contactsQuery = await _firestore
            .collection('contacts')
            .where('users', isEqualTo: sortedUsers)
            .limit(1)
            .get();

        if (contactsQuery.docs.isEmpty) {
          throw Exception('Documento de contacto no encontrado');
        }

        _contactDocumentId = contactsQuery.docs.first.id;
      }

      // Actualizar nivel de moderación
      await _firestore.collection('contacts').doc(_contactDocumentId!).update({
        'moderationSettings.$_currentUserId.level': newLevel,
      });

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

  /// Verificar si un mensaje es del contacto o del usuario actual
  bool isMessageFromContact(Map<String, dynamic> messageData) {
    final senderId = messageData['senderId'] as String?;
    return senderId != _currentUserId;
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
        return 'Modo Alto: Bloquea contenido potencialmente peligroso, insultos directos y palabrotas. Permite lenguaje coloquial sin insultos.';
      case 'medium':
        return 'Modo Medio: Bloquea insultos directos, palabrotas y contenido sexual. Permite lenguaje coloquial, sarcasmo e ironía sin insultos. Más flexible con el tono.';
      case 'low':
        return 'Modo Bajo: Solo bloquea contenido muy severo (amenazas serias, contenido sexual explícito, grooming). Más permisivo con lenguaje coloquial.';
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