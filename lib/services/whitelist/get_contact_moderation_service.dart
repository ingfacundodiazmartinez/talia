import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Obtener estado de moderación de contacto
///
/// Responsabilidad única: Leer nivel de moderación IA desde Firestore
/// ✅ Lee de contacts.moderationSettings[childId] (por usuario)
///
/// Estructura:
/// contacts/{contactId}.moderationSettings.{childId} = {
///   enabled: true/false,
///   level: "high" | "medium" | "low",
///   enabledBy: "parentId",
///   enabledAt: timestamp
/// }
class GetContactModerationService {
  final FirebaseFirestore _firestore;

  GetContactModerationService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Obtener estado de moderación de un contacto
  /// Retorna (success, moderationLevel, enabled, message)
  Future<({bool success, String? moderationLevel, bool enabled, String message})> call({
    required String childId,
    required String contactId,
  }) async {
    try {
      ReleaseLogger.log(
        'Obteniendo moderación: childId=$childId, contactId=$contactId',
        tag: 'GetContactModeration',
      );

      // Calcular contactDocId (ordenar alfabéticamente)
      final contactDocId = _getContactId(childId, contactId);

      // Leer directamente de Firestore (rules permiten al padre leer)
      final contactDoc = await _firestore.collection('contacts').doc(contactDocId).get();

      if (!contactDoc.exists) {
        // No existe contacto, devolver valores por defecto
        ReleaseLogger.log(
          'No existe contacto entre $childId y $contactId',
          tag: 'GetContactModeration',
        );
        return (
          success: true,
          moderationLevel: 'medium',
          enabled: false,
          message: 'OK',
        );
      }

      final data = contactDoc.data() ?? {};
      final moderationSettings = data['moderationSettings'] as Map<String, dynamic>? ?? {};
      final childSettings = moderationSettings[childId] as Map<String, dynamic>? ?? {};

      final moderationLevel = childSettings['level'] as String? ?? 'medium';
      final enabled = childSettings['enabled'] as bool? ?? false;

      ReleaseLogger.log(
        'Moderación obtenida: level=$moderationLevel, enabled=$enabled',
        tag: 'GetContactModeration',
      );

      return (
        success: true,
        moderationLevel: moderationLevel,
        enabled: enabled,
        message: 'OK',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error obteniendo moderación: $e',
        tag: 'GetContactModeration',
      );
      return (
        success: false,
        moderationLevel: null,
        enabled: false,
        message: 'Error al obtener moderación',
      );
    }
  }

  /// Genera el ID del contacto ordenando los IDs alfabéticamente
  String _getContactId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }
}
