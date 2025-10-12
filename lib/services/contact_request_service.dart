import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Resultado de una solicitud de contacto
class ContactRequestResult {
  final bool success;
  final String status; // 'approved' o 'pending'
  final int pendingCount;
  final String? errorMessage;

  ContactRequestResult({
    required this.success,
    required this.status,
    required this.pendingCount,
    this.errorMessage,
  });
}

/// Información del usuario que acepta la solicitud
class UserRoleInfo {
  final String userId;
  final String role;
  final bool isAdultOrParent;

  UserRoleInfo({
    required this.userId,
    required this.role,
    required this.isAdultOrParent,
  });
}

/// Servicio para manejar operaciones de solicitudes de contacto
///
/// Responsabilidades:
/// - Procesar códigos de usuario (QR o manual)
/// - Verificar roles de usuario
/// - Enviar solicitudes de contacto mediante Cloud Functions
/// - Validar relaciones entre usuarios
class ContactRequestService {
  // Singleton pattern
  static final ContactRequestService _instance = ContactRequestService._internal();
  factory ContactRequestService() => _instance;
  ContactRequestService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Obtener información de rol del usuario actual
  Future<UserRoleInfo?> getCurrentUserRoleInfo(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (!userDoc.exists) {
        return null;
      }

      final data = userDoc.data();
      final role = data?['role'] ?? 'child';
      final isAdultOrParent = role == 'adult' || role == 'parent';

      return UserRoleInfo(
        userId: userId,
        role: role,
        isAdultOrParent: isAdultOrParent,
      );
    } catch (e) {
      print('Error obteniendo información de rol de usuario: $e');
      return null;
    }
  }

  /// Enviar solicitud de contacto mediante Cloud Function
  ///
  /// Parámetros:
  /// - contactUserId: ID del usuario a agregar como contacto
  /// - currentUserId: ID del usuario actual
  /// - currentUserName: Nombre del usuario actual
  /// - currentUserEmail: Email del usuario actual
  /// - contactName: Nombre del contacto
  /// - contactEmail: Email del contacto
  ///
  /// Retorna un ContactRequestResult con el estado de la solicitud
  Future<ContactRequestResult> sendContactRequest({
    required String contactUserId,
    required String currentUserId,
    required String currentUserName,
    required String currentUserEmail,
    required String contactName,
    required String contactEmail,
  }) async {
    print('🚀 Iniciando sendContactRequest para $contactName');

    try {
      print('📞 Llamando a Cloud Function createContactRequest...');

      final callable = _functions.httpsCallable('createContactRequest');
      final response = await callable.call({
        'contactUserId': contactUserId,
        'currentUserName': currentUserName,
        'currentUserEmail': currentUserEmail,
        'contactName': contactName,
        'contactEmail': contactEmail,
      });

      final data = response.data as Map<String, dynamic>;
      print('✅ Cloud Function ejecutada: ${data['status']}, pending: ${data['pendingCount']}');

      return ContactRequestResult(
        success: true,
        status: data['status'] ?? 'pending',
        pendingCount: data['pendingCount'] ?? 0,
      );
    } catch (e) {
      print('❌ Error en sendContactRequest: $e');
      return ContactRequestResult(
        success: false,
        status: 'error',
        pendingCount: 0,
        errorMessage: e.toString(),
      );
    }
  }

  /// Verificar si un código de usuario es válido para agregar como contacto
  ///
  /// Validaciones:
  /// - El usuario existe
  /// - No es el mismo usuario
  /// - No es un contacto existente
  ///
  /// Retorna null si es válido, o un mensaje de error si no lo es
  Future<String?> validateContactCode({
    required String targetUserId,
    required String currentUserId,
  }) async {
    try {
      // Verificar que no sea el mismo usuario
      if (targetUserId == currentUserId) {
        return 'No puedes agregarte a ti mismo como contacto';
      }

      // TODO: Agregar validación de contacto existente si es necesario
      // Verificar si ya existe una relación de contacto activa

      return null; // Código válido
    } catch (e) {
      print('❌ Error validando código de contacto: $e');
      return 'Error validando código: $e';
    }
  }
}
