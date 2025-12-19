import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Actualizar nivel de moderación de contacto
///
/// Responsabilidad única: Escribir nivel de moderación IA a Firestore
/// ✅ Escribe en contacts.moderationSettings[childId] (por usuario)
///
/// Estructura:
/// contacts/{contactId}.moderationSettings.{childId} = {
///   enabled: true/false,
///   level: "high" | "medium" | "low",
///   enabledBy: "parentId",
///   enabledAt: timestamp
/// }
class UpdateContactModerationService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  UpdateContactModerationService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Actualizar nivel de moderación de un contacto
  /// Niveles válidos: 'high', 'medium', 'low', 'none'
  /// Retorna (success, message)
  Future<({bool success, String message})> call({
    required String childId,
    required String contactId,
    required String moderationLevel,
    bool enabled = true,
  }) async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) {
        return (success: false, message: 'Usuario no autenticado');
      }

      ReleaseLogger.log(
        'Actualizando moderación: childId=$childId, contactId=$contactId, level=$moderationLevel, enabled=$enabled',
        tag: 'UpdateContactModeration',
      );

      // Validar nivel
      final validLevels = ['high', 'medium', 'low', 'none'];
      if (!validLevels.contains(moderationLevel)) {
        return (
          success: false,
          message: 'Nivel de moderación no válido',
        );
      }

      // Si el nivel es 'none', deshabilitar moderación
      final shouldEnable = enabled && moderationLevel != 'none';
      final effectiveLevel = moderationLevel == 'none' ? 'medium' : moderationLevel;

      // Calcular contactDocId (ordenar alfabéticamente)
      final contactDocId = _getContactId(childId, contactId);
      final contactRef = _firestore.collection('contacts').doc(contactDocId);

      // Verificar que el contacto existe
      final contactDoc = await contactRef.get();
      if (!contactDoc.exists) {
        ReleaseLogger.log(
          'Contacto no existe: $contactDocId',
          tag: 'UpdateContactModeration',
        );
        return (
          success: false,
          message: 'El contacto no existe.',
        );
      }

      // Preparar nuevos settings para el child
      // NOTA: No usar FieldValue.delete() en campos anidados, usar null en su lugar
      final newSettings = <String, dynamic>{
        'enabled': shouldEnable,
        'level': effectiveLevel,
        'updatedAt': FieldValue.serverTimestamp(),
        'enabledBy': shouldEnable ? parentId : null,
        'enabledAt': shouldEnable ? FieldValue.serverTimestamp() : null,
      };

      // Actualizar moderationSettings del child en el contacto
      await contactRef.update({
        'moderationSettings.$childId': newSettings,
      });

      ReleaseLogger.log(
        'Moderación actualizada exitosamente para $childId',
        tag: 'UpdateContactModeration',
      );

      return (success: true, message: 'Moderación actualizada');
    } catch (e, stackTrace) {
      ReleaseLogger.error(
        'Error actualizando moderación: $e\nStackTrace: $stackTrace',
        tag: 'UpdateContactModeration',
      );

      // Manejar error de permisos
      if (e.toString().contains('PERMISSION_DENIED')) {
        return (
          success: false,
          message: 'No tienes permiso para modificar esta configuración',
        );
      }

      return (success: false, message: 'Error al actualizar moderación: $e');
    }
  }

  /// Genera el ID del contacto ordenando los IDs alfabéticamente
  String _getContactId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
