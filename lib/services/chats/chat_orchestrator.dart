import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/chat_message.dart';
import '../../services/chat_block_service.dart';
import '../../utils/release_logger.dart';
import 'repositories/chat_repository.dart';
import 'repositories/message_repository.dart';
import 'services/chat_creation_service.dart';
import 'services/chat_messaging_service.dart';
import 'services/chat_retrieval_service.dart';
import 'services/chat_management_service.dart';
import 'services/group_management_service.dart';
import 'services/rate_limiting_service.dart';
import 'services/chat_notification_service.dart';
import 'services/chat_approval_workflow_service.dart';
import 'models/group_member.dart';
import 'managers/chat_cache_manager.dart';
import 'managers/chat_stream_manager.dart';
import 'managers/message_upload_manager.dart';

/// Orchestrator principal que coordina todos los servicios de chats
///
/// Responsabilidades:
/// - Coordinar entre servicios especializados
/// - Mantener API pública compatible con controllers existentes
/// - Gestionar dependencias entre servicios
/// - Proporcionar punto único de acceso para chats
class ChatOrchestrator {
  // Repositorios (Data Layer)
  late final ChatRepository _chatRepository;
  late final MessageRepository _messageRepository;

  // Servicios especializados (Business Logic Layer)
  late final ChatCreationService _creationService;
  late final ChatMessagingService _messagingService;
  late final ChatRetrievalService _retrievalService;
  late final ChatManagementService _managementService;
  late final GroupManagementService _groupService;

  // Servicios P2 (Advanced Features)
  late final RateLimitingService _rateLimitingService;
  late final ChatNotificationService _notificationService;
  late final ChatApprovalWorkflowService _approvalWorkflowService;

  // Managers (Data Layer)
  late final ChatCacheManager _cacheManager;
  late final ChatStreamManager _streamManager;
  late final MessageUploadManager _uploadManager;

  // Singleton instance
  static ChatOrchestrator? _instance;

  /// Factory constructor que devuelve singleton
  factory ChatOrchestrator({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) {
    _instance ??= ChatOrchestrator._internal(
      firestore: firestore,
      auth: auth,
    );
    return _instance!;
  }

  /// Constructor interno para inicialización
  ChatOrchestrator._internal({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) {
    _initializeServices(firestore, auth);
  }

  /// Inicializar todos los servicios y sus dependencias
  void _initializeServices(
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  ) {
    // Repositorios base
    _chatRepository = ChatRepository(
      firestore: firestore ?? FirebaseFirestore.instance,
      auth: auth ?? FirebaseAuth.instance,
    );

    _messageRepository = MessageRepository(
      firestore: firestore ?? FirebaseFirestore.instance,
      auth: auth ?? FirebaseAuth.instance,
    );

    // Contact repository temporal - usar servicio existente
    // _contactRepository será implementado después

    // Inicializar servicios P2 primero (para dependencias)
    _rateLimitingService = RateLimitingService();

    // Managers
    _cacheManager = ChatCacheManager();
    _uploadManager = MessageUploadManager();

    _streamManager = ChatStreamManager(
      chatRepository: _chatRepository,
      messageRepository: _messageRepository,
      cacheManager: _cacheManager,
    );

    // Servicios especializados
    _creationService = ChatCreationService(
      chatRepository: _chatRepository,
      contactRepository: null, // Temporal
      cacheManager: _cacheManager,
      blockService: ChatBlockService(),
      auth: auth,
      rateLimitingService: _rateLimitingService,
    );

    _messagingService = ChatMessagingService(
      messageRepository: _messageRepository,
      uploadManager: _uploadManager,
      cacheManager: _cacheManager,
      rateLimitingService: _rateLimitingService,
    );

    _retrievalService = ChatRetrievalService(
      streamManager: _streamManager,
      cacheManager: _cacheManager,
      chatRepository: _chatRepository,
      messageRepository: _messageRepository,
    );

    _managementService = ChatManagementService(
      chatRepository: _chatRepository,
      messageRepository: _messageRepository,
      cacheManager: _cacheManager,
    );

    _groupService = GroupManagementService(
      chatRepository: _chatRepository,
      cacheManager: _cacheManager,
      auth: auth,
    );

    // Inicializar servicios P2 restantes
    _notificationService = ChatNotificationService();

    _approvalWorkflowService = ChatApprovalWorkflowService(
      chatRepository: _chatRepository,
      notificationService: _notificationService,
      groupService: _groupService,
      cacheManager: _cacheManager,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // API PÚBLICA - Compatible con controllers existentes
  // ═══════════════════════════════════════════════════════════════

  /// Crear nuevo chat individual
  Future<String> createIndividualChat({
    required String contactId,
    String? initialMessage,
  }) async {
    return await _creationService.createIndividualChat(
      contactId: contactId,
      initialMessage: initialMessage,
    );
  }

  /// Crear nuevo grupo
  Future<String> createGroup({
    required String name,
    required List<String> memberIds,
    String? description,
    String? photoUrl,
  }) async {
    return await _creationService.createGroup(
      name: name,
      memberIds: memberIds,
      description: description,
      photoUrl: photoUrl,
    );
  }

  /// Enviar mensaje con upload optimista
  Future<String?> sendMessage({
    required String chatId,
    required String content,
    MessageType type = MessageType.text,
    String? mediaPath,
    Map<String, dynamic>? replyTo,  // ✅ FIX: Cambiar de replyToId a replyTo completo
    Map<String, dynamic>? metadata,
    bool isGroup = false,  // ✅ FIX: Agregar parámetro isGroup
    Function(String messageId, double progress)? onProgressUpdate,
  }) async {
    return await _messagingService.sendMessage(
      chatId: chatId,
      content: content,
      type: type,
      mediaPath: mediaPath,
      replyTo: replyTo,  // ✅ FIX: Pasar replyTo completo
      metadata: metadata,
      isGroup: isGroup,  // ✅ FIX: Pasar isGroup al servicio
      onProgressUpdate: onProgressUpdate,
    );
  }

  /// Obtener stream de mensajes de un chat
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return _retrievalService.getMessagesStream(chatId);
  }

  /// Obtener lista de chats del usuario
  Stream<List<Chat>> getUserChatsStream() {
    return _retrievalService.getUserChatsStream();
  }

  /// Marcar chat como leído
  Future<void> markChatAsRead(String chatId) async {
    await _managementService.markChatAsRead(chatId);
  }

  /// Invalidar cache de clearedAt después de limpiar chat
  void invalidateClearedAtCache(String chatId, String userId) {
    _streamManager.invalidateClearedAtCache(chatId, userId);
  }

  /// Resetear stream del chat (cerrar y recrear con nuevo clearedAt)
  void resetChatStream(String chatId) {
    _streamManager.closeChatStream(chatId);
    ReleaseLogger.log('🔄 Chat stream cerrado para chat $chatId - se recreará con nuevo clearedAt');
  }

  /// ⚡ Iniciar listener global de mensajes para notificaciones instantáneas
  /// Este listener elimina el delay de 1-2 segundos de FCM al detectar mensajes en tiempo real
  /// ⚡ NUEVO: Iniciar listeners eficientes de documentos de chats
  /// Reemplaza GlobalListener (que fallaba por permisos)
  /// Solo 2 listeners (chats + grupos) para notificaciones instantáneas <100ms
  Future<void> startChatDocumentsListener() async {
    await _streamManager.startChatDocumentsListener();
  }

  /// @deprecated Usar startChatDocumentsListener() en su lugar
  Future<void> startGlobalMessageListener() async {
    // Redirigir al nuevo método
    await startChatDocumentsListener();
  }

  /// Eliminar mensaje
  Future<void> deleteMessage(String chatId, String messageId) async {
    await _managementService.deleteMessage(chatId, messageId);
  }

  /// Editar mensaje
  Future<void> editMessage(
    String chatId,
    String messageId,
    String newContent,
  ) async {
    await _managementService.editMessage(chatId, messageId, newContent);
  }

  /// Forward mensaje a otros chats
  Future<void> forwardMessage({
    required ChatMessage message,
    required List<String> targetChatIds,
    required List<String> targetGroupIds,
  }) async {
    await _managementService.forwardMessage(
      message: message,
      targetChatIds: targetChatIds,
      targetGroupIds: targetGroupIds,
    );
  }

  /// Buscar mensajes en chat
  Future<List<ChatMessage>> searchMessages({
    required String chatId,
    required String query,
    int limit = 50,
  }) async {
    return await _retrievalService.searchMessages(
      chatId: chatId,
      query: query,
      limit: limit,
    );
  }

  /// Cargar mensajes anteriores (paginación)
  Future<List<ChatMessage>> loadMoreMessages({
    required String chatId,
    ChatMessage? lastMessage,
    int limit = 20,
  }) async {
    return await _retrievalService.loadMoreMessages(
      chatId: chatId,
      lastMessage: lastMessage,
      limit: limit,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // CACHE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Obtener mensajes del cache
  List<ChatMessage> getCachedMessages(String chatId) {
    return _cacheManager.getCachedMessages(chatId);
  }

  /// Invalidar cache de un chat
  void invalidateChatCache(String chatId) {
    _cacheManager.invalidateChatCache(chatId);
  }

  /// Limpiar cache completo
  void clearAllCache() {
    _cacheManager.clearAllCache();
  }

  // ═══════════════════════════════════════════════════════════════
  // LIFECYCLE MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar background processes
  Future<void> startBackgroundProcesses() async {
    await _streamManager.startBackgroundStreams();
  }

  /// Detener background processes
  void stopBackgroundProcesses() {
    _streamManager.stopBackgroundStreams();
  }

  /// Dispose del orchestrator
  void dispose() {
    stopBackgroundProcesses();
    _cacheManager.dispose();
    _uploadManager.dispose();
    _groupService.dispose();
    _instance = null;
  }

  // ═══════════════════════════════════════════════════════════════
  // GROUP MANAGEMENT API
  // ═══════════════════════════════════════════════════════════════

  /// Obtener miembros de un grupo
  Future<GroupMemberList> getGroupMembers(String groupId) async {
    return await _groupService.getGroupMembers(groupId);
  }

  /// Stream de cambios en miembros de un grupo
  Stream<GroupMemberList> getGroupMembersStream(String groupId) {
    return _groupService.getGroupMembersStream(groupId);
  }

  /// Verificar si usuario puede ver grupo
  Future<bool> canViewGroup(String userId, String groupId) async {
    return await _groupService.canViewGroup(userId, groupId);
  }

  /// Verificar si usuario puede enviar mensajes al grupo
  Future<bool> canSendToGroup(String userId, String groupId) async {
    return await _groupService.canSendToGroup(userId, groupId);
  }

  /// Agregar miembro a grupo
  Future<void> addMemberToGroup({
    required String groupId,
    required String userId,
    required String displayName,
    GroupMemberStatus initialStatus = GroupMemberStatus.pending,
    String? photoUrl,
    Map<String, dynamic>? metadata,
  }) async {
    await _groupService.addMemberToGroup(
      groupId: groupId,
      userId: userId,
      displayName: displayName,
      initialStatus: initialStatus,
      photoUrl: photoUrl,
      metadata: metadata,
    );
  }

  /// Actualizar estado de miembro
  Future<void> updateMemberStatus({
    required String groupId,
    required String userId,
    required GroupMemberStatus newStatus,
    String? reason,
    String? approvedBy,
  }) async {
    await _groupService.updateMemberStatus(
      groupId: groupId,
      userId: userId,
      newStatus: newStatus,
      reason: reason,
      approvedBy: approvedBy,
    );
  }

  /// Aprobar miembro pendiente (por parent)
  Future<void> approvePendingMember({
    required String groupId,
    required String userId,
    required String parentId,
  }) async {
    await _groupService.approvePendingMember(
      groupId: groupId,
      userId: userId,
      parentId: parentId,
    );
  }

  /// Rechazar/bloquear miembro pendiente (por parent)
  Future<void> rejectPendingMember({
    required String groupId,
    required String userId,
    required String parentId,
    String? reason,
  }) async {
    await _groupService.rejectPendingMember(
      groupId: groupId,
      userId: userId,
      parentId: parentId,
      reason: reason,
    );
  }

  /// Remover miembro del grupo
  Future<void> removeMemberFromGroup({
    required String groupId,
    required String userId,
    String? reason,
  }) async {
    await _groupService.removeMemberFromGroup(
      groupId: groupId,
      userId: userId,
      reason: reason,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // RATE LIMITING API (P2)
  // ═══════════════════════════════════════════════════════════════

  /// Obtener métricas de rate limiting
  Map<String, dynamic> getRateLimitMetrics() {
    return _rateLimitingService.getMetrics();
  }

  /// Obtener estado de rate limit para un usuario
  Map<String, dynamic> getUserRateLimitStatus(String userId) {
    return _rateLimitingService.getUserLimitStatus(userId);
  }

  /// Reset rate limits para un usuario (admin)
  void resetUserRateLimits(String userId) {
    _rateLimitingService.resetUserLimits(userId);
  }

  // ═══════════════════════════════════════════════════════════════
  // NOTIFICATION API (P2)
  // ═══════════════════════════════════════════════════════════════

  /// Notificar parent sobre nueva solicitud de grupo
  Future<void> notifyParentOfGroupRequest({
    required String childId,
    required String groupId,
    required String groupName,
    required String requestedBy,
    List<String>? otherMembers,
  }) async {
    await _notificationService.notifyParentOfGroupRequest(
      childId: childId,
      groupId: groupId,
      groupName: groupName,
      requestedBy: requestedBy,
      otherMembers: otherMembers,
    );
  }

  /// Notificar parent sobre miembro agregado
  Future<void> notifyParentOfMemberAdded({
    required String childId,
    required String groupId,
    required String groupName,
    required String newMemberId,
    required String addedBy,
  }) async {
    await _notificationService.notifyParentOfMemberAdded(
      childId: childId,
      groupId: groupId,
      groupName: groupName,
      newMemberId: newMemberId,
      addedBy: addedBy,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // APPROVAL WORKFLOW API (P2)
  // ═══════════════════════════════════════════════════════════════

  /// Iniciar workflow de aprobación para miembro de grupo
  Future<String> startGroupMemberApproval({
    required String groupId,
    required String userId,
    required String displayName,
    required String requestedBy,
    List<String>? existingMembers,
    Map<String, dynamic>? metadata,
    bool isUrgent = false,
  }) async {
    return await _approvalWorkflowService.startGroupMemberApproval(
      groupId: groupId,
      userId: userId,
      displayName: displayName,
      requestedBy: requestedBy,
      existingMembers: existingMembers,
      metadata: metadata,
      isUrgent: isUrgent,
    );
  }

  /// Procesar respuesta de parent (aprobación/rechazo)
  Future<void> processParentResponse({
    required String requestId,
    required String parentId,
    required bool approved,
    String? reason,
  }) async {
    await _approvalWorkflowService.processParentResponse(
      requestId: requestId,
      parentId: parentId,
      approved: approved,
      reason: reason,
    );
  }

  /// Obtener solicitudes pendientes para un parent
  List<dynamic> getPendingApprovalRequests(String parentId) {
    return _approvalWorkflowService.getPendingRequestsForParent(parentId);
  }

  /// Obtener métricas de aprobaciones
  Map<String, dynamic> getApprovalMetrics() {
    return _approvalWorkflowService.getApprovalMetrics();
  }

  /// Cancelar solicitud de aprobación
  Future<void> cancelApprovalRequest(String requestId, {String? reason}) async {
    await _approvalWorkflowService.cancelApprovalRequest(requestId, reason: reason);
  }

  // ═══════════════════════════════════════════════════════════════
  // DEBUG & TESTING HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Acceso a cache manager para testing
  ChatCacheManager get cacheManagerForTesting => _cacheManager;

  /// Acceso a stream manager para testing
  ChatStreamManager get streamManagerForTesting => _streamManager;

  /// Forzar refresh de cache
  Future<void> forceRefreshCache() async {
    await _streamManager.forceRefresh();
  }

  /// Obtener métricas de performance
  Map<String, dynamic> getPerformanceMetrics() {
    return {
      'activeChatStreams': _streamManager.getActiveStreamCount(),
      'cachedChatsCount': _cacheManager.getCachedChatsCount(),
      'pendingUploads': _uploadManager.getPendingUploadsCount(),
      'cacheHitRate': _cacheManager.getCacheHitRate(),
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // MESSAGE MODERATION - Edit blocked messages
  // ═══════════════════════════════════════════════════════════════

  /// Verificar moderación de contenido sin crear mensaje
  ///
  /// Usado para edición de mensajes bloqueados.
  /// Lanza ModerationBlockedException si el contenido es bloqueado.
  Future<void> checkModerationOnly({
    required String chatId,
    required String content,
  }) async {
    await _messagingService.checkModerationOnly(
      chatId: chatId,
      content: content,
    );
  }

  /// Crear mensaje aprobado en Firestore después de pasar moderación
  ///
  /// Usado cuando un mensaje bloqueado es editado y aprobado.
  Future<void> createApprovedMessage({
    required String chatId,
    required String messageId,
    required String senderId,
    required String text,
    String? localId, // ✅ FIX: Agregar localId para deduplicación
  }) async {
    await _messagingService.createApprovedMessage(
      chatId: chatId,
      messageId: messageId,
      senderId: senderId,
      text: text,
      localId: localId, // ✅ FIX: Pasar localId
    );
  }
}

/// Modelo para Chat (placeholder - debe existir en models/)
class Chat {
  final String id;
  final String type; // 'individual' | 'group'
  final String name;
  final List<String> participants;
  final ChatMessage? lastMessage;
  final DateTime lastActivity;
  final int unreadCount;

  Chat({
    required this.id,
    required this.type,
    required this.name,
    required this.participants,
    this.lastMessage,
    required this.lastActivity,
    this.unreadCount = 0,
  });
}