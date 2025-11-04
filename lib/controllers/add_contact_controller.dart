import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/user_code_service.dart';
import '../services/contact_request_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio de agregar contactos
///
/// Responsabilidades:
/// - Proporcionar información del usuario actual
/// - Gestionar el flujo de agregar contactos
/// - Abstraer operaciones Firebase de la pantalla
class AddContactController {
  // Firebase services
  final firebase_auth.FirebaseAuth _auth;

  // Services
  final UserCodeService _userCodeService;
  final ContactRequestService _contactRequestService;

  /// Constructor
  AddContactController({
    firebase_auth.FirebaseAuth? auth,
    UserCodeService? userCodeService,
    ContactRequestService? contactRequestService,
  }) : _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _userCodeService = userCodeService ?? UserCodeService(),
       _contactRequestService = contactRequestService ?? ContactRequestService();

  // Getters for current user information
  String? get currentUserId => _auth.currentUser?.uid;
  String get currentUserDisplayName => _auth.currentUser?.displayName ?? 'Usuario';
  String get currentUserEmail => _auth.currentUser?.email ?? '';

  /// Obtener código del usuario actual
  Future<String> getCurrentUserCode() async {
    try {
      return await _userCodeService.getCurrentUserCode();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo código del usuario: $e', tag: 'AddContact');
      rethrow;
    }
  }

  /// Regenerar código del usuario actual
  Future<String> regenerateCurrentUserCode() async {
    try {
      final currentUserId = this.currentUserId;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      return await _userCodeService.regenerateUserCode(currentUserId);
    } catch (e) {
      ReleaseLogger.error('Error regenerando código del usuario: $e', tag: 'AddContact');
      rethrow;
    }
  }

  /// Buscar contacto por código
  Future<Map<String, dynamic>?> findContactByCode(String code) async {
    try {
      return await _userCodeService.findUserByCode(code);
    } catch (e) {
      ReleaseLogger.error('Error buscando contacto por código: $e', tag: 'AddContact');
      rethrow;
    }
  }

  /// Enviar solicitud de contacto
  Future<bool> sendContactRequest(String targetUserId) async {
    try {
      final currentUserId = this.currentUserId;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      await _contactRequestService.sendContactRequest(
        senderId: currentUserId,
        receiverId: targetUserId,
      );

      ReleaseLogger.log('Solicitud de contacto enviada a $targetUserId', tag: 'AddContact');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando solicitud de contacto: $e', tag: 'AddContact');
      return false;
    }
  }

  /// Enviar solicitud grupal
  Future<bool> sendGroupRequest(String groupCode) async {
    try {
      final currentUserId = this.currentUserId;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      await _contactRequestService.sendGroupRequest(
        groupCode: groupCode,
        currentUserId: currentUserId,
        currentUserName: currentUserDisplayName,
        currentUserEmail: currentUserEmail,
      );

      ReleaseLogger.log('Solicitud grupal enviada para código $groupCode', tag: 'AddContact');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error enviando solicitud grupal: $e', tag: 'AddContact');
      return false;
    }
  }
}