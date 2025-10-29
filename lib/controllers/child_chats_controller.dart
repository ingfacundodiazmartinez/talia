import 'package:flutter/foundation.dart';
import 'base_chats_controller.dart';
import '../services/contact_service.dart';
import '../services/user_role_service.dart';
import '../services/contact_alias_service.dart';

/// Controller para la pantalla de chats de un niño
///
/// Responsabilidades:
/// - Obtener padre vinculado
/// - Verificar permisos de contactos
/// - Proveer acceso a alias
class ChildChatsController extends BaseChatsController with ChangeNotifier {
  final ContactService _contactService;
  final UserRoleService _userRoleService;
  final ContactAliasService _aliasService;

  ChildChatsController({
    required super.userId,
    super.firestore,
    super.chatService,
    super.groupChatService,
    ContactService? contactService,
    UserRoleService? userRoleService,
    ContactAliasService? aliasService,
  })  : _contactService = contactService ?? ContactService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _aliasService = aliasService ?? ContactAliasService();

  /// Obtener ID del padre vinculado
  Future<String?> getLinkedParentId() async {
    try {
      final linkedParents = await _userRoleService.getLinkedParents(userId);
      return linkedParents.isNotEmpty ? linkedParents.first : null;
    } catch (e) {
      debugPrint('❌ Error obteniendo padre vinculado: $e');
      return null;
    }
  }

  /// Watch para el nombre display (con alias)
  Stream<String> watchDisplayName(String targetUserId, String realName) {
    return _aliasService.watchDisplayName(targetUserId, realName);
  }

  /// Watch para verificar si un chat está bloqueado
  Stream<bool> watchChatBlocked(String chatId) {
    return _contactService.watchChatBlocked(chatId);
  }

  /// Verificar si un contacto está revocado
  Future<bool> isContactRevoked(String contactId) async {
    return await _contactService.isContactRevoked(userId, contactId);
  }

  /// Inicializar controller
  Future<void> initialize() async {
    // Placeholder para inicialización futura si es necesaria
    notifyListeners();
  }
}
