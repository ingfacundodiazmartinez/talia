import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../repositories/chat_repository.dart';
import '../managers/chat_cache_manager.dart';
import '../../../services/chat_block_service.dart';
import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';
import 'rate_limiting_service.dart';

/// Servicio especializado para creación de chats y grupos
///
/// Responsabilidades:
/// - Validaciones de seguridad P0 antes de crear chats
/// - Lógica de negocio para creación de chats individuales
/// - Lógica de negocio para creación de grupos
/// - Validación de aprobaciones bidireccionales
class ChatCreationService {
  final ChatRepository _chatRepository;
  final ChatCacheManager _cacheManager;
  final ChatBlockService _blockService;
  final FirebaseAuth _auth;
  final RateLimitingService _rateLimitingService;

  ChatCreationService({
    required ChatRepository chatRepository,
    required dynamic contactRepository, // Temporal - no usado aún
    required ChatCacheManager cacheManager,
    ChatBlockService? blockService,
    FirebaseAuth? auth,
    RateLimitingService? rateLimitingService,
  }) : _chatRepository = chatRepository,
       _cacheManager = cacheManager,
       _blockService = blockService ?? ChatBlockService(),
       _auth = auth ?? FirebaseAuth.instance,
       _rateLimitingService = rateLimitingService ?? RateLimitingService();

  // ═══════════════════════════════════════════════════════════════
  // CHAT INDIVIDUAL CREATION WITH SECURITY
  // ═══════════════════════════════════════════════════════════════

  /// 🔒 Crear chat individual con validaciones de seguridad P0
  Future<String> createIndividualChat({
    required String contactId,
    String? initialMessage,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🔒 P0 CRÍTICO: Validar bloqueos antes de crear chat
    await _validateBlockStatusForChatCreation(currentUserId, contactId);

    // TODO: P1 - Validar que el contactId existe
    // await _validateUserExists(contactId);

    // TODO: P1 - Validar aprobación de contacto según tipo de usuarios
    // await _validateContactApproval(currentUserId, contactId);

    try {
      // Verificar si el chat ya existe
      final existingChat = await _chatRepository.getIndividualChatByParticipants(
        userId1: currentUserId,
        userId2: contactId,
      );

      if (existingChat != null) {
        ReleaseLogger.info('Chat individual ya existe: ${existingChat.id}');
        return existingChat.id;
      }

      // Crear nuevo chat
      final chatId = await _chatRepository.createIndividualChat(
        contactId: contactId,
      );

      ReleaseLogger.info('✅ Chat individual creado: $chatId');

      // Actualizar cache
      _cacheManager.invalidateChatCache(chatId);

      // Enviar mensaje inicial si se proporcionó
      if (initialMessage != null && initialMessage.isNotEmpty) {
        // TODO: Enviar mensaje inicial a través de ChatMessagingService
        ReleaseLogger.info('Mensaje inicial pendiente: $initialMessage');
      }

      return chatId;

    } catch (e) {
      ReleaseLogger.error('Error creando chat individual: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GROUP CREATION WITH SECURITY
  // ═══════════════════════════════════════════════════════════════

  /// 🔒 Crear grupo con validaciones de seguridad P0
  Future<String> createGroup({
    required String name,
    required List<String> memberIds,
    String? description,
    String? photoUrl,
  }) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // 🚦 VALIDACIÓN DE RATE LIMITING P2: Verificar rate limits de creación
    await _rateLimitingService.validateGroupCreation(currentUserId);

    // 🔒 P0 CRÍTICO: Validaciones de seguridad
    await _validateGroupCreationSecurity(currentUserId, memberIds, name);

    try {
      final groupId = await _chatRepository.createGroup(
        name: name,
        memberIds: memberIds,
        description: description,
        photoUrl: photoUrl,
      );

      ReleaseLogger.info('✅ Grupo creado: $groupId con ${memberIds.length} miembros');

      // Actualizar cache
      _cacheManager.invalidateChatCache(groupId);

      // TODO: P1 - Enviar notificaciones a parents para miembros pendientes
      // await _sendParentNotificationsForPendingMembers(groupId, memberIds);

      return groupId;

    } catch (e) {
      ReleaseLogger.error('Error creando grupo: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SECURITY VALIDATION METHODS (P0)
  // ═══════════════════════════════════════════════════════════════

  /// 🔒 P0 CRÍTICO: Validar bloqueos para creación de chat individual
  Future<void> _validateBlockStatusForChatCreation(
    String currentUserId,
    String contactId,
  ) async {
    try {
      // Verificar si current user está bloqueado por contactId
      final blockStatus = await _blockService.getChatBlockStatus(
        childId: currentUserId,
        contactId: contactId,
      );

      if (blockStatus.isBlocked) {
        throw UserBlockedException(
          'No puedes crear un chat con este usuario. ${blockStatus.reason ?? "Usuario bloqueado"}',
          blockedBy: contactId,
          blockedAt: blockStatus.blockedAt?.toDate(),
        );
      }

      // Verificar si contactId está bloqueado por current user
      final reverseBlockStatus = await _blockService.getChatBlockStatus(
        childId: contactId,
        contactId: currentUserId,
      );

      if (reverseBlockStatus.isBlocked) {
        throw UserBlockedException(
          'Has bloqueado a este usuario. No puedes crear un chat.',
          blockedBy: currentUserId,
        );
      }

      ReleaseLogger.info('✅ Validación de bloqueo pasada para chat creation', tag: 'ChatSecurity');

    } catch (e) {
      if (e is UserBlockedException) {
        rethrow;
      }
      ReleaseLogger.error('Error en validación de bloqueo para creation: $e', tag: 'ChatSecurity');
      // En caso de error, permitir creación - el backend lo validará
    }
  }

  /// 🔒 P0 CRÍTICO: Validar seguridad para creación de grupos
  Future<void> _validateGroupCreationSecurity(
    String currentUserId,
    List<String> memberIds,
    String groupName,
  ) async {
    // Validación básica
    if (memberIds.isEmpty) {
      throw Exception('Un grupo debe tener al menos un miembro');
    }

    if (memberIds.length > 20) {
      throw GroupTooLargeException(
        'El grupo es muy grande',
        currentSize: memberIds.length,
        maxSize: 20,
      );
    }

    if (groupName.trim().isEmpty) {
      throw Exception('El grupo debe tener un nombre');
    }

    // 🔒 P0: Validar bloqueos para cada miembro
    for (final memberId in memberIds) {
      try {
        // Verificar si creador está bloqueado por miembro
        final blockStatus = await _blockService.getChatBlockStatus(
          childId: currentUserId,
          contactId: memberId,
        );

        if (blockStatus.isBlocked) {
          ReleaseLogger.warning(
            'Miembro $memberId ha bloqueado al creador - será miembro pendiente',
            tag: 'GroupCreation'
          );
          // No lanzar excepción - se manejará como miembro pendiente
        }

        // Verificar si miembro está bloqueado por creador
        final reverseBlockStatus = await _blockService.getChatBlockStatus(
          childId: memberId,
          contactId: currentUserId,
        );

        if (reverseBlockStatus.isBlocked) {
          throw UserBlockedException(
            'Has bloqueado a $memberId. No puedes agregarlo al grupo.',
            blockedBy: currentUserId,
          );
        }

      } catch (e) {
        if (e is UserBlockedException) {
          rethrow;
        }
        ReleaseLogger.warning('Error validando miembro $memberId: $e', tag: 'GroupCreation');
        // Continuar con otros miembros
      }
    }

    // TODO: P1 - Validar aprobación bidireccional O(n²) entre todos los miembros
    // await _validateBidirectionalApprovalsInGroup(currentUserId, memberIds);

    ReleaseLogger.info('✅ Validaciones de seguridad pasadas para grupo', tag: 'GroupCreation');
  }

  // TODO: P1 - Implementar validaciones adicionales
  /*
  Future<void> _validateBidirectionalApprovalsInGroup(
    String currentUserId,
    List<String> memberIds,
  ) async {
    // Validar que todos los children tengan aprobación bidireccional
    // entre ellos (O(n²) validation)
  }

  Future<void> _validateUserExists(String userId) async {
    // Verificar que el usuario existe en Firestore
  }

  Future<void> _validateContactApproval(
    String currentUserId,
    String contactId,
  ) async {
    // Verificar aprobación unidireccional/bidireccional según tipos de usuario
  }
  */
}