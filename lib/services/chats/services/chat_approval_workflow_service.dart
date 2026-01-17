import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/group_member.dart';
import '../repositories/chat_repository.dart';
import '../services/chat_notification_service.dart';
import '../services/group_management_service.dart';
import '../managers/chat_cache_manager.dart';
import '../../../utils/release_logger.dart';

/// Servicio de workflow completo de aprobación de chats y grupos
///
/// Responsabilidades:
/// - Coordinar proceso completo pending → approved
/// - Integrar notificaciones, auto-approval, y gestión de grupos
/// - Manejar timeouts y escalaciones
/// - Workflow de aprobación bidireccional
/// - Métricas de aprobaciones
class ChatApprovalWorkflowService {
  final ChatRepository _chatRepository;
  final ChatNotificationService _notificationService;
  final GroupManagementService _groupService;
  final ChatCacheManager _cacheManager;
  final FirebaseAuth _auth;

  // Timeouts para aprobaciones
  static const Duration _defaultApprovalTimeout = Duration(hours: 24);
  static const Duration _urgentApprovalTimeout = Duration(hours: 2);

  // Tracking de solicitudes pendientes
  final Map<String, PendingApprovalRequest> _pendingRequests = {};

  // Métricas
  int _totalRequests = 0;
  int _autoApprovals = 0;
  int _manualApprovals = 0;
  int _rejections = 0;
  int _timeouts = 0;

  ChatApprovalWorkflowService({
    required ChatRepository chatRepository,
    required ChatNotificationService notificationService,
    required GroupManagementService groupService,
    required ChatCacheManager cacheManager,
    FirebaseAuth? auth,
  }) : _chatRepository = chatRepository,
       _notificationService = notificationService,
       _groupService = groupService,
       _cacheManager = cacheManager,
       _auth = auth ?? FirebaseAuth.instance;

  // ═══════════════════════════════════════════════════════════════
  // MAIN WORKFLOW ENTRY POINTS
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
    _totalRequests++;

    final requestId = _generateRequestId();

    try {
      // 1. Crear solicitud pendiente
      final request = PendingApprovalRequest(
        id: requestId,
        type: ApprovalType.groupMember,
        groupId: groupId,
        userId: userId,
        displayName: displayName,
        requestedBy: requestedBy,
        existingMembers: existingMembers ?? [],
        metadata: metadata ?? {},
        createdAt: DateTime.now(),
        timeout: isUrgent ? _urgentApprovalTimeout : _defaultApprovalTimeout,
        status: ApprovalStatus.pending,
      );

      _pendingRequests[requestId] = request;

      // 2. Intentar auto-aprobación primero
      final autoApproved = await _attemptAutoApproval(request);

      if (autoApproved) {
        return requestId;
      }

      // 3. Si no es auto-aprobable, enviar notificaciones a parents
      await _sendApprovalNotifications(request);

      // 4. Configurar timeout
      _scheduleTimeout(request);

      ReleaseLogger.info(
        '📋 Workflow de aprobación iniciado: $requestId para usuario $userId en grupo $groupId',
        tag: 'ApprovalWorkflow',
      );

      return requestId;

    } catch (e) {
      _pendingRequests.remove(requestId);
      ReleaseLogger.error('Error iniciando workflow de aprobación: $e');
      rethrow;
    }
  }

  /// Procesar respuesta de parent (aprobación/rechazo)
  Future<void> processParentResponse({
    required String requestId,
    required String parentId,
    required bool approved,
    String? reason,
  }) async {
    final request = _pendingRequests[requestId];
    if (request == null) {
      throw Exception('Solicitud $requestId no encontrada o ya procesada');
    }

    try {
      if (approved) {
        await _executeApproval(request, parentId);
        _manualApprovals++;
      } else {
        await _executeRejection(request, parentId, reason);
        _rejections++;
      }

      // Remover de pendientes
      _pendingRequests.remove(requestId);

      ReleaseLogger.info(
        '✅ Respuesta de parent procesada: $requestId ${approved ? 'aprobado' : 'rechazado'} por $parentId',
        tag: 'ApprovalWorkflow',
      );

    } catch (e) {
      ReleaseLogger.error('Error procesando respuesta de parent: $e');
      rethrow;
    }
  }

  /// Cancelar solicitud de aprobación
  Future<void> cancelApprovalRequest(String requestId, {String? reason}) async {
    final request = _pendingRequests[requestId];
    if (request == null) return;

    request.status = ApprovalStatus.cancelled;
    _pendingRequests.remove(requestId);

    ReleaseLogger.info(
      '❌ Solicitud de aprobación cancelada: $requestId. Razón: ${reason ?? "No especificada"}',
      tag: 'ApprovalWorkflow',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // AUTO-APPROVAL LOGIC
  // ═══════════════════════════════════════════════════════════════

  /// Intentar auto-aprobación basada en settings
  Future<bool> _attemptAutoApproval(PendingApprovalRequest request) async {
    try {
      final autoApproved = await _notificationService.processAutoApproval(
        childId: request.userId,
        groupId: request.groupId!,
        requestedBy: request.requestedBy,
        proposedMembers: request.existingMembers,
      );

      if (autoApproved) {
        await _executeAutoApproval(request);
        _autoApprovals++;
        _pendingRequests.remove(request.id);
        return true;
      }

      return false;

    } catch (e) {
      ReleaseLogger.error('Error en auto-aprobación: $e');
      return false;
    }
  }

  /// Ejecutar auto-aprobación
  Future<void> _executeAutoApproval(PendingApprovalRequest request) async {
    try {
      // Actualizar estado a aprobado
      await _groupService.updateMemberStatus(
        groupId: request.groupId!,
        userId: request.userId,
        newStatus: GroupMemberStatus.approved,
        approvedBy: 'auto_approval_system',
      );

      request.status = ApprovalStatus.autoApproved;
      request.approvedBy = 'auto_approval_system';
      request.approvedAt = DateTime.now();

      ReleaseLogger.info(
        '🤖 Auto-aprobación ejecutada para request ${request.id}',
        tag: 'AutoApproval',
      );

    } catch (e) {
      ReleaseLogger.error('Error ejecutando auto-aprobación: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // NOTIFICATION WORKFLOW
  // ═══════════════════════════════════════════════════════════════

  /// Enviar notificaciones de aprobación a parents
  Future<void> _sendApprovalNotifications(PendingApprovalRequest request) async {
    try {
      await _notificationService.notifyParentOfGroupRequest(
        childId: request.userId,
        groupId: request.groupId!,
        groupName: await _getGroupName(request.groupId!),
        requestedBy: request.requestedBy,
        otherMembers: request.existingMembers,
      );

      request.notificationsSent = true;
      request.notificationsSentAt = DateTime.now();

    } catch (e) {
      ReleaseLogger.error('Error enviando notificaciones de aprobación: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // APPROVAL EXECUTION
  // ═══════════════════════════════════════════════════════════════

  /// Ejecutar aprobación manual
  Future<void> _executeApproval(PendingApprovalRequest request, String parentId) async {
    try {
      // Actualizar estado del miembro
      await _groupService.updateMemberStatus(
        groupId: request.groupId!,
        userId: request.userId,
        newStatus: GroupMemberStatus.approved,
        approvedBy: parentId,
      );

      // Actualizar request
      request.status = ApprovalStatus.approved;
      request.approvedBy = parentId;
      request.approvedAt = DateTime.now();

      // Invalidar cache
      _cacheManager.invalidateChatCache(request.groupId!);

      ReleaseLogger.info(
        '✅ Aprobación manual ejecutada para ${request.userId} por parent $parentId',
        tag: 'ManualApproval',
      );

    } catch (e) {
      ReleaseLogger.error('Error ejecutando aprobación manual: $e');
      rethrow;
    }
  }

  /// Ejecutar rechazo
  Future<void> _executeRejection(PendingApprovalRequest request, String parentId, String? reason) async {
    try {
      // Actualizar estado del miembro a bloqueado
      await _groupService.updateMemberStatus(
        groupId: request.groupId!,
        userId: request.userId,
        newStatus: GroupMemberStatus.blocked,
        reason: reason ?? 'Rechazado por control parental',
      );

      // Actualizar request
      request.status = ApprovalStatus.rejected;
      request.rejectedBy = parentId;
      request.rejectedAt = DateTime.now();
      request.rejectionReason = reason;

      ReleaseLogger.info(
        '❌ Rechazo ejecutado para ${request.userId} por parent $parentId. Razón: $reason',
        tag: 'ApprovalRejection',
      );

    } catch (e) {
      ReleaseLogger.error('Error ejecutando rechazo: $e');
      rethrow;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // TIMEOUT MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Configurar timeout para solicitud
  void _scheduleTimeout(PendingApprovalRequest request) {
    Timer(request.timeout, () {
      if (_pendingRequests.containsKey(request.id)) {
        _handleTimeout(request);
      }
    });
  }

  /// Manejar timeout de solicitud
  Future<void> _handleTimeout(PendingApprovalRequest request) async {
    try {
      request.status = ApprovalStatus.timeout;
      request.timeoutAt = DateTime.now();
      _timeouts++;

      // Por defecto, rechazar en timeout para seguridad
      await _groupService.updateMemberStatus(
        groupId: request.groupId!,
        userId: request.userId,
        newStatus: GroupMemberStatus.blocked,
        reason: 'Timeout de aprobación parental (${request.timeout.inHours}h)',
      );

      _pendingRequests.remove(request.id);

      ReleaseLogger.warning(
        '⏰ Timeout de aprobación para request ${request.id} - usuario bloqueado por seguridad',
        tag: 'ApprovalTimeout',
      );

    } catch (e) {
      ReleaseLogger.error('Error manejando timeout: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // QUERY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener solicitudes pendientes para un parent
  List<PendingApprovalRequest> getPendingRequestsForParent(String parentId) {
    // TODO: Filtrar por parentId cuando tengamos contactRepository
    return _pendingRequests.values
        .where((request) => request.status == ApprovalStatus.pending)
        .toList();
  }

  /// Obtener estado de solicitud
  PendingApprovalRequest? getRequestStatus(String requestId) {
    return _pendingRequests[requestId];
  }

  /// Obtener métricas de aprobaciones
  Map<String, dynamic> getApprovalMetrics() {
    final pendingCount = _pendingRequests.values
        .where((r) => r.status == ApprovalStatus.pending)
        .length;

    return {
      'totalRequests': _totalRequests,
      'autoApprovals': _autoApprovals,
      'manualApprovals': _manualApprovals,
      'rejections': _rejections,
      'timeouts': _timeouts,
      'currentPending': pendingCount,
      'autoApprovalRate': _totalRequests > 0 ? _autoApprovals / _totalRequests : 0.0,
      'approvalRate': _totalRequests > 0
          ? (_autoApprovals + _manualApprovals) / _totalRequests : 0.0,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Generar ID único para request
  String _generateRequestId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'approval_req_${timestamp}_$random';
  }

  /// Obtener nombre del grupo
  Future<String> _getGroupName(String groupId) async {
    try {
      final doc = await _chatRepository.getGroupById(groupId);
      if (doc?.exists == true) {
        final data = doc!.data() as Map<String, dynamic>;
        return data['name'] as String? ?? 'Grupo sin nombre';
      }
      return 'Grupo desconocido';
    } catch (e) {
      return 'Grupo $groupId';
    }
  }

  /// Limpiar requests antiguos
  void cleanupOldRequests() {
    final cutoffTime = DateTime.now().subtract(Duration(days: 7));

    _pendingRequests.removeWhere((id, request) {
      return request.createdAt.isBefore(cutoffTime) ||
             request.status != ApprovalStatus.pending;
    });
  }
}

/// Modelo de solicitud de aprobación pendiente
class PendingApprovalRequest {
  final String id;
  final ApprovalType type;
  final String? groupId;
  final String userId;
  final String displayName;
  final String requestedBy;
  final List<String> existingMembers;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final Duration timeout;

  ApprovalStatus status;
  String? approvedBy;
  DateTime? approvedAt;
  String? rejectedBy;
  DateTime? rejectedAt;
  String? rejectionReason;
  DateTime? timeoutAt;
  bool notificationsSent;
  DateTime? notificationsSentAt;

  PendingApprovalRequest({
    required this.id,
    required this.type,
    this.groupId,
    required this.userId,
    required this.displayName,
    required this.requestedBy,
    required this.existingMembers,
    required this.metadata,
    required this.createdAt,
    required this.timeout,
    required this.status,
    this.approvedBy,
    this.approvedAt,
    this.rejectedBy,
    this.rejectedAt,
    this.rejectionReason,
    this.timeoutAt,
    this.notificationsSent = false,
    this.notificationsSentAt,
  });

  /// Tiempo restante antes del timeout
  Duration get timeRemaining {
    final deadlineTime = createdAt.add(timeout);
    final remaining = deadlineTime.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Está próximo al timeout
  bool get isNearTimeout => timeRemaining <= Duration(hours: 2);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'groupId': groupId,
      'userId': userId,
      'displayName': displayName,
      'requestedBy': requestedBy,
      'existingMembers': existingMembers,
      'metadata': metadata,
      'createdAt': createdAt.toIso8601String(),
      'timeout': timeout.inMilliseconds,
      'status': status.name,
      'approvedBy': approvedBy,
      'approvedAt': approvedAt?.toIso8601String(),
      'rejectedBy': rejectedBy,
      'rejectedAt': rejectedAt?.toIso8601String(),
      'rejectionReason': rejectionReason,
      'timeoutAt': timeoutAt?.toIso8601String(),
      'notificationsSent': notificationsSent,
      'notificationsSentAt': notificationsSentAt?.toIso8601String(),
    };
  }
}

/// Tipos de aprobación
enum ApprovalType {
  groupMember,
  friendRequest,
  chatInvite,
}

/// Estados de aprobación
enum ApprovalStatus {
  pending,
  approved,
  rejected,
  autoApproved,
  timeout,
  cancelled,
}