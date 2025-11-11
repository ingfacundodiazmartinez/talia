import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';

import '../repositories/chat_repository.dart';
import '../../../utils/release_logger.dart';

/// Servicio de notificaciones automáticas para chats
///
/// Responsabilidades:
/// - Envío de notificaciones a parents sobre actividad de grupos
/// - Notificaciones de solicitudes de miembros pendientes
/// - Workflow de aprobación automática vs manual
/// - Configuración de settings de notificación
class ChatNotificationService {
  final ChatRepository _chatRepository;
  final FirebaseAuth _auth;

  // TODO: Integrar con servicio de notificaciones existente cuando esté disponible
  // final NotificationService _notificationService;

  // Cache de configuraciones de parent para performance
  final Map<String, ParentNotificationSettings> _settingsCache = {};
  final Duration _cacheTimeout = Duration(minutes: 5);
  final Map<String, DateTime> _cacheTimestamps = {};

  ChatNotificationService({
    required ChatRepository chatRepository,
    FirebaseAuth? auth,
  }) : _chatRepository = chatRepository,
       _auth = auth ?? FirebaseAuth.instance;

  // ═══════════════════════════════════════════════════════════════
  // PARENT NOTIFICATION TRIGGERS
  // ═══════════════════════════════════════════════════════════════

  /// Notificar parent sobre nueva solicitud de grupo para su child
  Future<void> notifyParentOfGroupRequest({
    required String childId,
    required String groupId,
    required String groupName,
    required String requestedBy,
    List<String>? otherMembers,
  }) async {
    try {
      final parentIds = await _getParentIds(childId);
      if (parentIds.isEmpty) {
        ReleaseLogger.info('Child $childId no tiene parents configurados');
        return;
      }

      for (final parentId in parentIds) {
        final settings = await _getParentNotificationSettings(parentId);

        if (settings.enableGroupRequestNotifications) {
          await _sendGroupRequestNotification(
            parentId: parentId,
            childId: childId,
            groupId: groupId,
            groupName: groupName,
            requestedBy: requestedBy,
            otherMembers: otherMembers ?? [],
            autoApprove: settings.autoApproveGroups,
          );
        }
      }

      ReleaseLogger.info(
        'Notificación de grupo enviada a ${parentIds.length} parents para child $childId',
        tag: 'ChatNotification',
      );

    } catch (e) {
      ReleaseLogger.error('Error notificando parents sobre grupo: $e', tag: 'ChatNotification');
    }
  }

  /// Notificar parent sobre miembro agregado a grupo de su child
  Future<void> notifyParentOfMemberAdded({
    required String childId,
    required String groupId,
    required String groupName,
    required String newMemberId,
    required String addedBy,
  }) async {
    try {
      final parentIds = await _getParentIds(childId);

      for (final parentId in parentIds) {
        final settings = await _getParentNotificationSettings(parentId);

        if (settings.enableMemberChangeNotifications) {
          await _sendMemberAddedNotification(
            parentId: parentId,
            childId: childId,
            groupId: groupId,
            groupName: groupName,
            newMemberId: newMemberId,
            addedBy: addedBy,
          );
        }
      }

      ReleaseLogger.info(
        'Notificación de nuevo miembro enviada para child $childId',
        tag: 'ChatNotification',
      );

    } catch (e) {
      ReleaseLogger.error('Error notificando parents sobre nuevo miembro: $e');
    }
  }

  /// Notificar parent sobre actividad sospechosa en chats
  Future<void> notifyParentOfSuspiciousActivity({
    required String childId,
    required String chatId,
    required String activityType,
    required Map<String, dynamic> details,
  }) async {
    try {
      final parentIds = await _getParentIds(childId);

      for (final parentId in parentIds) {
        final settings = await _getParentNotificationSettings(parentId);

        if (settings.enableSuspiciousActivityNotifications) {
          await _sendSuspiciousActivityNotification(
            parentId: parentId,
            childId: childId,
            chatId: chatId,
            activityType: activityType,
            details: details,
          );
        }
      }

    } catch (e) {
      ReleaseLogger.error('Error notificando actividad sospechosa: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // AUTO-APPROVAL WORKFLOW
  // ═══════════════════════════════════════════════════════════════

  /// Procesar auto-aprobación basada en settings de parent
  Future<bool> processAutoApproval({
    required String childId,
    required String groupId,
    required String requestedBy,
    required List<String> proposedMembers,
  }) async {
    try {
      final parentIds = await _getParentIds(childId);
      if (parentIds.isEmpty) return false;

      // Verificar si TODOS los parents tienen auto-approval habilitado
      bool allParentsAutoApprove = true;
      for (final parentId in parentIds) {
        final settings = await _getParentNotificationSettings(parentId);
        if (!settings.autoApproveGroups) {
          allParentsAutoApprove = false;
          break;
        }
      }

      if (!allParentsAutoApprove) {
        ReleaseLogger.info(
          'Auto-aprobación no disponible para child $childId - requiere aprobación manual',
          tag: 'AutoApproval',
        );
        return false;
      }

      // Validaciones adicionales para auto-approval
      final autoApprovalAllowed = await _validateAutoApprovalConditions(
        childId: childId,
        groupId: groupId,
        requestedBy: requestedBy,
        proposedMembers: proposedMembers,
      );

      if (autoApprovalAllowed) {
        await _executeAutoApproval(
          childId: childId,
          groupId: groupId,
          parentIds: parentIds,
        );
        return true;
      }

      return false;

    } catch (e) {
      ReleaseLogger.error('Error en proceso de auto-aprobación: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PARENT SETTINGS MANAGEMENT
  // ═══════════════════════════════════════════════════════════════

  /// Obtener configuraciones de notificación de parent
  Future<ParentNotificationSettings> _getParentNotificationSettings(String parentId) async {
    // Verificar cache
    if (_settingsCache.containsKey(parentId)) {
      final timestamp = _cacheTimestamps[parentId];
      if (timestamp != null && DateTime.now().difference(timestamp) < _cacheTimeout) {
        return _settingsCache[parentId]!;
      }
    }

    try {
      // TODO: Obtener de Firestore cuando esté implementado
      // final doc = await FirebaseFirestore.instance
      //     .collection('parentSettings')
      //     .doc(parentId)
      //     .get();

      // Por ahora usar defaults
      final settings = ParentNotificationSettings.defaults();

      // Cachear resultado
      _settingsCache[parentId] = settings;
      _cacheTimestamps[parentId] = DateTime.now();

      return settings;

    } catch (e) {
      ReleaseLogger.warning('Error obteniendo settings de parent $parentId: $e');
      return ParentNotificationSettings.defaults();
    }
  }

  /// Obtener IDs de parents de un child
  Future<List<String>> _getParentIds(String childId) async {
    try {
      // TODO: Implementar cuando tengamos contactRepository
      // Por ahora retornar lista vacía - será implementado con contactRepository
      return <String>[];
    } catch (e) {
      ReleaseLogger.error('Error obteniendo parents de child $childId: $e');
      return <String>[];
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // NOTIFICATION SENDERS
  // ═══════════════════════════════════════════════════════════════

  /// Enviar notificación de solicitud de grupo
  Future<void> _sendGroupRequestNotification({
    required String parentId,
    required String childId,
    required String groupId,
    required String groupName,
    required String requestedBy,
    required List<String> otherMembers,
    required bool autoApprove,
  }) async {
    try {
      final notification = {
        'type': 'group_request',
        'parentId': parentId,
        'childId': childId,
        'groupId': groupId,
        'groupName': groupName,
        'requestedBy': requestedBy,
        'otherMembers': otherMembers,
        'autoApprove': autoApprove,
        'timestamp': DateTime.now().toIso8601String(),
        'title': autoApprove ? 'Grupo Auto-Aprobado' : 'Solicitud de Grupo',
        'message': autoApprove
            ? 'Tu hijo ha sido agregado automáticamente al grupo "$groupName"'
            : 'Tu hijo fue invitado al grupo "$groupName". ¿Aprobar?',
      };

      // TODO: Enviar via servicio de notificaciones real
      ReleaseLogger.info('📧 Notificación grupo: $notification', tag: 'ChatNotification');

    } catch (e) {
      ReleaseLogger.error('Error enviando notificación de grupo: $e');
    }
  }

  /// Enviar notificación de miembro agregado
  Future<void> _sendMemberAddedNotification({
    required String parentId,
    required String childId,
    required String groupId,
    required String groupName,
    required String newMemberId,
    required String addedBy,
  }) async {
    try {
      final notification = {
        'type': 'member_added',
        'parentId': parentId,
        'childId': childId,
        'groupId': groupId,
        'groupName': groupName,
        'newMemberId': newMemberId,
        'addedBy': addedBy,
        'timestamp': DateTime.now().toIso8601String(),
        'title': 'Nuevo Miembro en Grupo',
        'message': 'Se agregó un nuevo miembro al grupo "$groupName" donde está tu hijo',
      };

      // TODO: Enviar via servicio de notificaciones real
      ReleaseLogger.info('📧 Notificación miembro: $notification', tag: 'ChatNotification');

    } catch (e) {
      ReleaseLogger.error('Error enviando notificación de miembro: $e');
    }
  }

  /// Enviar notificación de actividad sospechosa
  Future<void> _sendSuspiciousActivityNotification({
    required String parentId,
    required String childId,
    required String chatId,
    required String activityType,
    required Map<String, dynamic> details,
  }) async {
    try {
      final notification = {
        'type': 'suspicious_activity',
        'parentId': parentId,
        'childId': childId,
        'chatId': chatId,
        'activityType': activityType,
        'details': details,
        'timestamp': DateTime.now().toIso8601String(),
        'title': 'Actividad Sospechosa Detectada',
        'message': 'Se detectó actividad sospechosa en los chats de tu hijo',
      };

      // TODO: Enviar via servicio de notificaciones real
      ReleaseLogger.info('🚨 Notificación sospechosa: $notification', tag: 'ChatNotification');

    } catch (e) {
      ReleaseLogger.error('Error enviando notificación sospechosa: $e');
    }
  }

  /// Validar condiciones para auto-aprobación
  Future<bool> _validateAutoApprovalConditions({
    required String childId,
    required String groupId,
    required String requestedBy,
    required List<String> proposedMembers,
  }) async {
    try {
      // Validaciones de seguridad para auto-approval

      // 1. Grupo no debe ser muy grande (máximo 5 para auto-approval)
      if (proposedMembers.length > 5) {
        ReleaseLogger.info('Auto-approval rechazada: grupo muy grande (${proposedMembers.length})');
        return false;
      }

      // 2. Requestor debe ser contacto aprobado
      // TODO: Verificar con contactRepository cuando esté disponible

      // 3. Todos los miembros deben ser contactos aprobados
      // TODO: Verificar con contactRepository

      // 4. No debe haber reportes previos de los miembros
      // TODO: Verificar con sistema de moderación

      return true;

    } catch (e) {
      ReleaseLogger.error('Error validando condiciones de auto-approval: $e');
      return false;
    }
  }

  /// Ejecutar auto-aprobación
  Future<void> _executeAutoApproval({
    required String childId,
    required String groupId,
    required List<String> parentIds,
  }) async {
    try {
      // Log de auto-aprobación ejecutada
      ReleaseLogger.info(
        '✅ Auto-aprobación ejecutada para child $childId en grupo $groupId',
        tag: 'AutoApproval',
      );

      // TODO: Actualizar estado de miembro a 'approved' automáticamente
      // await _groupService.updateMemberStatus(
      //   groupId: groupId,
      //   userId: childId,
      //   newStatus: GroupMemberStatus.approved,
      //   approvedBy: 'auto_approval_system',
      // );

      // Enviar confirmación a todos los parents
      for (final parentId in parentIds) {
        await _sendGroupRequestNotification(
          parentId: parentId,
          childId: childId,
          groupId: groupId,
          groupName: 'Grupo Auto-Aprobado',
          requestedBy: 'sistema',
          otherMembers: [],
          autoApprove: true,
        );
      }

    } catch (e) {
      ReleaseLogger.error('Error ejecutando auto-aprobación: $e');
      rethrow;
    }
  }

  /// Invalidar cache de settings
  void invalidateSettingsCache([String? parentId]) {
    if (parentId != null) {
      _settingsCache.remove(parentId);
      _cacheTimestamps.remove(parentId);
    } else {
      _settingsCache.clear();
      _cacheTimestamps.clear();
    }
  }
}

/// Configuración de notificaciones de parent
class ParentNotificationSettings {
  final bool enableGroupRequestNotifications;
  final bool enableMemberChangeNotifications;
  final bool enableSuspiciousActivityNotifications;
  final bool autoApproveGroups;
  final bool autoApproveFriendRequests;
  final int maxGroupSizeForAutoApproval;
  final List<String> trustedContactsForAutoApproval;

  const ParentNotificationSettings({
    required this.enableGroupRequestNotifications,
    required this.enableMemberChangeNotifications,
    required this.enableSuspiciousActivityNotifications,
    required this.autoApproveGroups,
    required this.autoApproveFriendRequests,
    required this.maxGroupSizeForAutoApproval,
    required this.trustedContactsForAutoApproval,
  });

  /// Configuración por defecto (conservadora)
  factory ParentNotificationSettings.defaults() {
    return ParentNotificationSettings(
      enableGroupRequestNotifications: true,
      enableMemberChangeNotifications: true,
      enableSuspiciousActivityNotifications: true,
      autoApproveGroups: false, // Disabled por defecto para seguridad
      autoApproveFriendRequests: false,
      maxGroupSizeForAutoApproval: 3,
      trustedContactsForAutoApproval: [],
    );
  }

  /// Configuración permisiva (para parents que confían)
  factory ParentNotificationSettings.permissive() {
    return ParentNotificationSettings(
      enableGroupRequestNotifications: true,
      enableMemberChangeNotifications: false,
      enableSuspiciousActivityNotifications: true,
      autoApproveGroups: true,
      autoApproveFriendRequests: true,
      maxGroupSizeForAutoApproval: 10,
      trustedContactsForAutoApproval: [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableGroupRequestNotifications': enableGroupRequestNotifications,
      'enableMemberChangeNotifications': enableMemberChangeNotifications,
      'enableSuspiciousActivityNotifications': enableSuspiciousActivityNotifications,
      'autoApproveGroups': autoApproveGroups,
      'autoApproveFriendRequests': autoApproveFriendRequests,
      'maxGroupSizeForAutoApproval': maxGroupSizeForAutoApproval,
      'trustedContactsForAutoApproval': trustedContactsForAutoApproval,
    };
  }

  factory ParentNotificationSettings.fromJson(Map<String, dynamic> json) {
    return ParentNotificationSettings(
      enableGroupRequestNotifications: json['enableGroupRequestNotifications'] ?? true,
      enableMemberChangeNotifications: json['enableMemberChangeNotifications'] ?? true,
      enableSuspiciousActivityNotifications: json['enableSuspiciousActivityNotifications'] ?? true,
      autoApproveGroups: json['autoApproveGroups'] ?? false,
      autoApproveFriendRequests: json['autoApproveFriendRequests'] ?? false,
      maxGroupSizeForAutoApproval: json['maxGroupSizeForAutoApproval'] ?? 3,
      trustedContactsForAutoApproval: List<String>.from(json['trustedContactsForAutoApproval'] ?? []),
    );
  }
}