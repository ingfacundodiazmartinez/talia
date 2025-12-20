import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service para que usuarios adultos configuren su propia moderación
///
/// Flujo:
/// 1. Llama a Cloud Function setOwnModeration
/// 2. La función verifica que el usuario es adulto (no niño supervisado)
/// 3. Actualiza moderationSettings en contacts
/// 4. Sincroniza con chat.moderationEnabled
class SetOwnModerationService {
  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  SetOwnModerationService({
    FirebaseFunctions? functions,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _functions = functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Actualizar nivel de moderación propio
  /// Niveles válidos: 'high', 'medium', 'low', 'none'
  /// Retorna (success, message, enabled, level)
  Future<({bool success, String message, bool enabled, String level})> call({
    required String contactId,
    required String moderationLevel,
    bool enabled = true,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          message: 'Usuario no autenticado',
          enabled: false,
          level: 'medium',
        );
      }

      ReleaseLogger.log(
        'Llamando setOwnModeration: contactId=$contactId, level=$moderationLevel, enabled=$enabled',
        tag: 'SetOwnModeration',
      );

      final result = await _functions.httpsCallable('setOwnModeration').call({
        'contactId': contactId,
        'level': moderationLevel,
        'enabled': enabled,
      });

      final data = result.data as Map<String, dynamic>;
      final success = data['success'] as bool? ?? false;
      final message = data['message'] as String? ?? '';
      final resultEnabled = data['enabled'] as bool? ?? false;
      final resultLevel = data['level'] as String? ?? 'medium';

      ReleaseLogger.log(
        'setOwnModeration result: success=$success, enabled=$resultEnabled, level=$resultLevel',
        tag: 'SetOwnModeration',
      );

      return (
        success: success,
        message: message,
        enabled: resultEnabled,
        level: resultLevel,
      );
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'FirebaseFunctionsException: ${e.code} - ${e.message}',
        tag: 'SetOwnModeration',
      );

      String userMessage;
      switch (e.code) {
        case 'permission-denied':
          userMessage = e.message ?? 'No tienes permiso para modificar esta configuración';
          break;
        case 'not-found':
          userMessage = e.message ?? 'Contacto no encontrado';
          break;
        case 'invalid-argument':
          userMessage = e.message ?? 'Nivel de moderación no válido';
          break;
        default:
          userMessage = 'Error al actualizar moderación';
      }

      return (
        success: false,
        message: userMessage,
        enabled: false,
        level: 'medium',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error inesperado en setOwnModeration: $e',
        tag: 'SetOwnModeration',
      );

      return (
        success: false,
        message: 'Error al actualizar moderación: $e',
        enabled: false,
        level: 'medium',
      );
    }
  }

  /// Obtener estado actual de moderación propia
  Future<({bool enabled, String level})> getCurrentModeration({
    required String contactId,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (enabled: false, level: 'medium');
      }

      final contactDoc = await _firestore.collection('contacts').doc(contactId).get();
      if (!contactDoc.exists) {
        return (enabled: false, level: 'medium');
      }

      final data = contactDoc.data()!;
      final moderationSettings = data['moderationSettings'] as Map<String, dynamic>? ?? {};
      final mySettings = moderationSettings[userId] as Map<String, dynamic>?;

      if (mySettings == null) {
        return (enabled: false, level: 'medium');
      }

      return (
        enabled: mySettings['enabled'] as bool? ?? false,
        level: mySettings['level'] as String? ?? 'medium',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo moderación actual: $e',
        tag: 'SetOwnModeration',
      );
      return (enabled: false, level: 'medium');
    }
  }
}
