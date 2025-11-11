import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio de gestión de moderación de chats
///
/// Responsabilidades:
/// - Cargar hijos vinculados del padre
/// - Gestionar configuración de moderación por contacto
/// - Abstraer operaciones Firebase de la pantalla
class ChatModerationManagementController {
  // Firebase services
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  /// Constructor
  ChatModerationManagementController({
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters for current user information
  String? get currentUserId => _auth.currentUser?.uid;

  /// Cargar hijos vinculados del padre actual
  Future<List<String>> loadLinkedChildren() async {
    try {
      final currentUserId = this.currentUserId;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      ReleaseLogger.log('Cargando hijos vinculados para padre: $currentUserId', tag: 'ChatModeration');

      // Leer desde /users/{userId}.linkedChildrenIds por seguridad
      final userDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();

      if (userDoc.exists) {
        final userData = userDoc.data();
        final linkedChildrenIds = List<String>.from(userData?['linkedChildrenIds'] ?? []);

        ReleaseLogger.log('Encontrados ${linkedChildrenIds.length} hijos vinculados', tag: 'ChatModeration');
        return linkedChildrenIds;
      } else {
        ReleaseLogger.log('No se encontró documento del usuario', tag: 'ChatModeration');
        return [];
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando hijos vinculados: $e', tag: 'ChatModeration');
      rethrow;
    }
  }

  /// Obtener información del hijo para mostrar en la UI
  Future<Map<String, dynamic>?> getChildInfo(String childId) async {
    try {
      final childDoc = await _firestore
          .collection('users')
          .doc(childId)
          .get();

      if (childDoc.exists) {
        return childDoc.data();
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo información del hijo $childId: $e', tag: 'ChatModeration');
      return null;
    }
  }

  /// Obtener configuración de moderación para un hijo
  Future<Map<String, dynamic>?> getModerationConfig(String childId) async {
    try {
      final configDoc = await _firestore
          .collection('moderation_settings')
          .doc(childId)
          .get();

      if (configDoc.exists) {
        return configDoc.data();
      }
      return null;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo configuración de moderación para $childId: $e', tag: 'ChatModeration');
      return null;
    }
  }

  /// Actualizar configuración de moderación para un contacto específico
  Future<bool> updateContactModerationConfig({
    required String childId,
    required String contactId,
    required bool enableModeration,
  }) async {
    try {
      await _firestore
          .collection('moderation_settings')
          .doc(childId)
          .collection('contacts')
          .doc(contactId)
          .set({
        'enableModeration': enableModeration,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': currentUserId,
      }, SetOptions(merge: true));

      ReleaseLogger.log(
        'Configuración de moderación actualizada para hijo $childId, contacto $contactId: $enableModeration',
        tag: 'ChatModeration'
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        'Error actualizando configuración de moderación para hijo $childId, contacto $contactId: $e',
        tag: 'ChatModeration'
      );
      return false;
    }
  }

  /// Obtener estadísticas de mensajes bloqueados
  Future<Map<String, int>> getModerationStats(String childId) async {
    try {
      final statsDoc = await _firestore
          .collection('moderation_stats')
          .doc(childId)
          .get();

      if (statsDoc.exists) {
        final data = statsDoc.data() as Map<String, dynamic>;
        return {
          'totalBlocked': data['totalBlocked'] ?? 0,
          'lastWeekBlocked': data['lastWeekBlocked'] ?? 0,
          'lastMonthBlocked': data['lastMonthBlocked'] ?? 0,
        };
      }
      return {
        'totalBlocked': 0,
        'lastWeekBlocked': 0,
        'lastMonthBlocked': 0,
      };
    } catch (e) {
      ReleaseLogger.error('Error obteniendo estadísticas de moderación para $childId: $e', tag: 'ChatModeration');
      return {
        'totalBlocked': 0,
        'lastWeekBlocked': 0,
        'lastMonthBlocked': 0,
      };
    }
  }

  /// Obtener contactos aprobados del hijo
  Future<List<Map<String, dynamic>>> getApprovedContacts(String childId) async {
    try {
      final contactsSnapshot = await _firestore
          .collection('users')
          .doc(childId)
          .collection('contacts')
          .where('status', isEqualTo: 'approved')
          .get();

      return contactsSnapshot.docs
          .map((doc) => {
                'id': doc.id,
                ...doc.data(),
              })
          .toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo contactos aprobados para $childId: $e', tag: 'ChatModeration');
      return [];
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
}