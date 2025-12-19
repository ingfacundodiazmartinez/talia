import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/contact.dart' as contact_model;
import '../models/grouped_contact.dart';
import '../models/user.dart' as app_user;
import '../groups/groups.dart';
import '../services/whitelist/whitelist_services.dart';
import '../utils/release_logger.dart';

/// Controller para Control Parental (Lista Blanca)
///
/// Arquitectura CODING_RULES:
/// - Controller solo coordina entre UI y Services
/// - Cada acción delega a un service atómico
/// - Lazy loading con cursor-based pagination
/// - Cache en memoria para búsqueda sin recrear streams
class WhitelistController {
  final String parentId;

  // ═══════════════════════════════════════════════════════════════
  // SERVICES (Inyección de dependencias)
  // ═══════════════════════════════════════════════════════════════

  final ListWhitelistContactsService _listContactsService;
  final ListGroupApprovalsService _listGroupsService;
  final GetLinkedChildrenService _linkedChildrenService;
  final GetSharedGroupsService _sharedGroupsService;
  final ApproveWhitelistContactService _approveService;
  final RejectWhitelistContactService _rejectService;
  final RevokeWhitelistContactService _revokeService;
  final ReapproveWhitelistContactService _reapproveService;
  final ApproveGroupMembershipService _approveGroupService;
  final RejectGroupMembershipService _rejectGroupService;
  final RevokeGroupMembershipService _revokeGroupService;
  final GetContactModerationService _getModerationService;
  final UpdateContactModerationService _updateModerationService;
  final MarkWhitelistNotificationsReadService _markNotificationsReadService;

  // ═══════════════════════════════════════════════════════════════
  // ESTADO
  // ═══════════════════════════════════════════════════════════════

  // Estado de procesamiento
  final Set<String> processingRequests = {};
  final Set<String> selectedRequests = {};

  // Cache para búsqueda y lazy loading
  List<contact_model.Contact> _contactsCache = [];
  List<GroupApprovalRequest> _groupRequestsCache = [];
  List<GroupMembershipInfo> _groupMembershipsCache = [];
  final Map<String, Map<String, dynamic>> _userDataCache = {};
  List<String> _linkedChildrenIds = [];

  // Streams
  StreamSubscription<List<contact_model.Contact>>? _contactsSubscription;
  StreamSubscription<List<GroupApprovalRequest>>? _groupRequestsSubscription;
  StreamSubscription<List<GroupMembershipInfo>>? _groupMembershipsSubscription;
  StreamSubscription<List<String>>? _linkedChildrenSubscription;

  // Callbacks para notificar cambios a la UI
  VoidCallback? onDataChanged;

  WhitelistController({
    required this.parentId,
    ListWhitelistContactsService? listContactsService,
    ListGroupApprovalsService? listGroupsService,
    GetLinkedChildrenService? linkedChildrenService,
    GetSharedGroupsService? sharedGroupsService,
    ApproveWhitelistContactService? approveService,
    RejectWhitelistContactService? rejectService,
    RevokeWhitelistContactService? revokeService,
    ReapproveWhitelistContactService? reapproveService,
    ApproveGroupMembershipService? approveGroupService,
    RejectGroupMembershipService? rejectGroupService,
    RevokeGroupMembershipService? revokeGroupService,
    GetContactModerationService? getModerationService,
    UpdateContactModerationService? updateModerationService,
    MarkWhitelistNotificationsReadService? markNotificationsReadService,
  })  : _listContactsService = listContactsService ?? ListWhitelistContactsService(),
        _listGroupsService = listGroupsService ?? ListGroupApprovalsService(),
        _linkedChildrenService = linkedChildrenService ?? GetLinkedChildrenService(),
        _sharedGroupsService = sharedGroupsService ?? GetSharedGroupsService(),
        _approveService = approveService ?? ApproveWhitelistContactService(),
        _rejectService = rejectService ?? RejectWhitelistContactService(),
        _revokeService = revokeService ?? RevokeWhitelistContactService(),
        _reapproveService = reapproveService ?? ReapproveWhitelistContactService(),
        _approveGroupService = approveGroupService ?? ApproveGroupMembershipService(),
        _rejectGroupService = rejectGroupService ?? RejectGroupMembershipService(),
        _revokeGroupService = revokeGroupService ?? RevokeGroupMembershipService(),
        _getModerationService = getModerationService ?? GetContactModerationService(),
        _updateModerationService = updateModerationService ?? UpdateContactModerationService(),
        _markNotificationsReadService = markNotificationsReadService ?? MarkWhitelistNotificationsReadService();

  // ═══════════════════════════════════════════════════════════════
  // INICIALIZACIÓN Y STREAMS
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar controller y comenzar a escuchar cambios
  Future<void> initialize() async {
    // 1. Obtener hijos vinculados
    _linkedChildrenIds = await _linkedChildrenService.getIds(parentId);

    // 2. Escuchar cambios en hijos vinculados
    _linkedChildrenSubscription = _linkedChildrenService
        .watchIds(parentId)
        .listen((ids) {
      if (!_areListsEqual(_linkedChildrenIds, ids)) {
        _linkedChildrenIds = ids;
        _restartContactsStream();
      }
    });

    // 3. Iniciar streams de datos
    _startStreams();
  }

  void _startStreams() {
    if (_linkedChildrenIds.isEmpty) {
      ReleaseLogger.log('No hay hijos vinculados', tag: 'WhitelistController');
      return;
    }

    // Stream de contactos - query por parentViewers (requerido por Security Rules)
    _contactsSubscription = _listContactsService
        .watchByParent(parentId)
        .listen((contacts) {
      _contactsCache = contacts;
      onDataChanged?.call();
    });

    // Stream de solicitudes de grupo pendientes
    _groupRequestsSubscription = _listGroupsService
        .watchPendingRequests(parentId)
        .listen((requests) {
      _groupRequestsCache = requests;
      onDataChanged?.call();
    });

    // Stream de membresías de grupo aprobadas
    _groupMembershipsSubscription = _listGroupsService
        .watchApprovedMemberships(_linkedChildrenIds)
        .listen((memberships) {
      _groupMembershipsCache = memberships;
      onDataChanged?.call();
    });
  }

  void _restartContactsStream() {
    _contactsSubscription?.cancel();
    _groupMembershipsSubscription?.cancel();
    _startStreams();
  }

  bool _areListsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAMS PÚBLICOS (para compatibilidad)
  // ═══════════════════════════════════════════════════════════════

  /// Stream de contactos (delega a service)
  /// Query por parentViewers (requerido por Security Rules)
  Stream<List<contact_model.Contact>> getContactsStream() {
    return _listContactsService.watchByParent(parentId);
  }

  /// Stream de solicitudes de grupo pendientes
  Stream<List<GroupApprovalRequest>> getPendingGroupApprovalRequests() {
    return _listGroupsService.watchPendingRequests(parentId);
  }

  /// Stream de grupos aprobados
  Stream<List<Map<String, dynamic>>> getApprovedGroupMembershipsStream() {
    return Stream.fromFuture(_linkedChildrenService.getIds(parentId))
        .asyncExpand((childrenIds) {
      if (childrenIds.isEmpty) {
        return Stream.value(<Map<String, dynamic>>[]);
      }
      return _listGroupsService.watchApprovedMemberships(childrenIds)
          .map((memberships) => memberships.map((m) => m.toMap()).toList());
    });
  }

  /// Stream de IDs de hijos vinculados
  Stream<List<String>> getLinkedChildrenIdsStream() {
    return _linkedChildrenService.watchIds(parentId);
  }

  // ═══════════════════════════════════════════════════════════════
  // ACCESO A CACHE (para búsqueda sin recrear streams)
  // ═══════════════════════════════════════════════════════════════

  /// Contactos en cache
  List<contact_model.Contact> get contactsCache => List.unmodifiable(_contactsCache);

  /// Solicitudes de grupo en cache
  List<GroupApprovalRequest> get groupRequestsCache => List.unmodifiable(_groupRequestsCache);

  /// Membresías de grupo en cache
  List<GroupMembershipInfo> get groupMembershipsCache => List.unmodifiable(_groupMembershipsCache);

  /// IDs de hijos vinculados
  List<String> get linkedChildrenIds => List.unmodifiable(_linkedChildrenIds);

  // ═══════════════════════════════════════════════════════════════
  // PROCESAMIENTO Y AGRUPAMIENTO
  // ═══════════════════════════════════════════════════════════════

  /// Agrupa contactos por persona y resuelve datos de usuarios
  Future<List<GroupedContact>> groupContactsByPerson(
    List<contact_model.Contact> contacts,
    List<GroupApprovalRequest> groupRequests,
    List<Map<String, dynamic>> approvedGroupMemberships,
  ) async {
    final grouped = <String, GroupedContact>{};

    // Recolectar todos los userIds que necesitamos resolver
    final userIdsToResolve = <String>{};
    for (final contact in contacts) {
      userIdsToResolve.addAll(contact.users);
    }
    userIdsToResolve.addAll(_linkedChildrenIds);

    // Batch fetch de datos de usuarios
    await _batchFetchUserData(userIdsToResolve.toList());

    // Procesar contactos individuales
    for (final contact in contacts) {
      for (final userId in contact.users) {
        if (!_linkedChildrenIds.contains(userId)) continue;

        final childId = userId;
        final contactUserId = contact.getOtherUserId(childId);
        if (contactUserId.isEmpty) continue;

        final contactData = _userDataCache[contactUserId] ?? {};
        final childData = _userDataCache[childId] ?? {};

        final contactName =
            contactData['name'] as String? ?? contactData['displayName'] as String? ?? 'Usuario';
        final contactPhone = contactData['phoneNumber'] as String? ?? contactData['phone'] as String?;
        final contactPhoto = contactData['photoURL'] as String?;
        final childName = childData['name'] as String? ?? 'Hijo';
        final childPhoto = childData['photoURL'] as String?;

        final approval = contact.getApprovalForChild(childId);
        final status = contact.status == 'revoked'
            ? 'revoked'
            : (approval?.status ?? contact.status);

        if (!grouped.containsKey(contactUserId)) {
          grouped[contactUserId] = GroupedContact(
            contactId: contactUserId,
            contactName: contactName,
            contactPhone: contactPhone,
            contactPhotoURL: contactPhoto,
            childRelations: [],
          );
        }

        final existingIndex = grouped[contactUserId]!
            .childRelations
            .indexWhere((r) => r.childId == childId);

        if (existingIndex == -1) {
          grouped[contactUserId] = grouped[contactUserId]!.copyWith(
            childRelations: [
              ...grouped[contactUserId]!.childRelations,
              ChildRelation(
                childId: childId,
                childName: childName,
                childPhotoURL: childPhoto,
                status: status,
                contactDocId: contact.id,
                type: 'contact',
                data: {
                  'contactId': contactUserId,
                  'contactName': contactName,
                  'contactPhone': contactPhone,
                  'contactPhoto': contactPhoto,
                  'childId': childId,
                  'approval': approval?.toMap(),
                },
              ),
            ],
          );
        }
      }
    }

    // Procesar solicitudes de grupo pendientes
    for (final request in groupRequests) {
      final groupId = request.groupId;
      final childId = request.childId;
      final groupName = request.groupName;
      final groupAvatar = request.groupAvatar;

      final childData = _userDataCache[childId] ?? {};
      final childName = childData['name'] as String? ?? 'Hijo';
      final childPhoto = childData['photoURL'] as String?;

      final key = 'group_$groupId';

      if (!grouped.containsKey(key)) {
        grouped[key] = GroupedContact(
          contactId: groupId,
          contactName: groupName,
          contactPhone: null,
          contactPhotoURL: groupAvatar,
          childRelations: [],
        );
      }

      final existingIndex = grouped[key]!
          .childRelations
          .indexWhere((r) => r.childId == childId);

      if (existingIndex == -1) {
        grouped[key] = grouped[key]!.copyWith(
          childRelations: [
            ...grouped[key]!.childRelations,
            ChildRelation(
              childId: childId,
              childName: childName,
              childPhotoURL: childPhoto,
              status: 'pending',
              contactDocId: request.id,
              type: 'group_v2',
              data: {
                'groupId': groupId,
                'groupName': groupName,
                'groupAvatar': groupAvatar,
                'requestId': request.id,
                'groupCreatorId': request.groupCreatorId,
                'groupCreatorName': request.groupCreatorName,
              },
            ),
          ],
        );
      }
    }

    // Procesar grupos aprobados
    for (final membership in approvedGroupMemberships) {
      final groupId = membership['groupId'] as String;
      final childId = membership['childId'] as String;
      final groupName = membership['groupName'] as String;
      final groupAvatar = membership['groupAvatar'] as String?;
      final memberCount = membership['memberCount'] as int? ?? 0;

      final childData = _userDataCache[childId] ?? {};
      final childName = childData['name'] as String? ?? 'Hijo';
      final childPhoto = childData['photoURL'] as String?;

      final key = 'group_$groupId';

      if (!grouped.containsKey(key)) {
        grouped[key] = GroupedContact(
          contactId: groupId,
          contactName: groupName,
          contactPhone: null,
          contactPhotoURL: groupAvatar,
          childRelations: [],
        );
      }

      final existingIndex = grouped[key]!
          .childRelations
          .indexWhere((r) => r.childId == childId);

      if (existingIndex == -1) {
        grouped[key] = grouped[key]!.copyWith(
          childRelations: [
            ...grouped[key]!.childRelations,
            ChildRelation(
              childId: childId,
              childName: childName,
              childPhotoURL: childPhoto,
              status: 'approved',
              contactDocId: groupId,
              type: 'group_v2',
              data: {
                'groupId': groupId,
                'groupName': groupName,
                'groupAvatar': groupAvatar,
                'memberCount': memberCount,
                'members': membership['members'],
                'memberDetails': membership['memberDetails'],
              },
            ),
          ],
        );
      }
    }

    final result = grouped.values.toList();
    result.sort((a, b) {
      final priorityCompare = a.sortPriority.compareTo(b.sortPriority);
      if (priorityCompare != 0) return priorityCompare;
      return a.contactName.toLowerCase().compareTo(b.contactName.toLowerCase());
    });

    return result;
  }

  /// Filtra contactos agrupados por estado y/o hijo
  List<GroupedContact> filterGroupedContacts(
    List<GroupedContact> contacts, {
    String? statusFilter,
    String? childIdFilter,
  }) {
    return contacts.where((contact) {
      final filteredRelations = contact.childRelations.where((relation) {
        if (statusFilter != null && statusFilter != 'all') {
          if (relation.status != statusFilter) return false;
        }
        if (childIdFilter != null && childIdFilter != 'all') {
          if (relation.childId != childIdFilter) return false;
        }
        return true;
      }).toList();

      return filteredRelations.isNotEmpty;
    }).map((contact) {
      final filteredRelations = contact.childRelations.where((relation) {
        if (statusFilter != null && statusFilter != 'all') {
          if (relation.status != statusFilter) return false;
        }
        if (childIdFilter != null && childIdFilter != 'all') {
          if (relation.childId != childIdFilter) return false;
        }
        return true;
      }).toList();

      return contact.copyWith(childRelations: filteredRelations);
    }).toList();
  }

  // ═══════════════════════════════════════════════════════════════
  // ACCIONES (delegan a services)
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar un contacto
  Future<Map<String, dynamic>> approveContact({
    required String contactDocId,
    required String childId,
  }) async {
    processingRequests.add(contactDocId);

    final result = await _approveService.call(
      contactDocId: contactDocId,
      childId: childId,
      parentId: parentId,
    );

    processingRequests.remove(contactDocId);
    selectedRequests.remove(contactDocId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  /// Rechazar un contacto
  Future<Map<String, dynamic>> rejectContact({
    required String contactDocId,
    required String childId,
  }) async {
    processingRequests.add(contactDocId);

    final result = await _rejectService.call(
      contactDocId: contactDocId,
      childId: childId,
      parentId: parentId,
    );

    processingRequests.remove(contactDocId);
    selectedRequests.remove(contactDocId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  /// Revocar un contacto aprobado
  Future<Map<String, dynamic>> revokeContact({
    required String contactDocId,
    required String childId,
    List<String>? groupsToRemove,
  }) async {
    processingRequests.add(contactDocId);

    final result = await _revokeService.call(
      contactDocId: contactDocId,
      childId: childId,
      parentId: parentId,
    );

    // Remover de grupos si se especificaron
    if (result.success && groupsToRemove != null && groupsToRemove.isNotEmpty) {
      for (final groupId in groupsToRemove) {
        await removeChildFromGroup(groupId: groupId, childId: childId);
      }
    }

    processingRequests.remove(contactDocId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  /// Re-aprobar un contacto rechazado
  Future<Map<String, dynamic>> reApproveContact({
    required String contactDocId,
    required String childId,
  }) async {
    processingRequests.add(contactDocId);

    final result = await _reapproveService.call(
      contactDocId: contactDocId,
      childId: childId,
      parentId: parentId,
    );

    processingRequests.remove(contactDocId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  // ═══════════════════════════════════════════════════════════════
  // GRUPOS V2
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar solicitud de grupo V2
  Future<Map<String, dynamic>> approveGroupV2Request({
    required String requestId,
    required String groupId,
    required String childId,
  }) async {
    processingRequests.add(requestId);

    final result = await _approveGroupService.call(
      requestId: requestId,
      groupId: groupId,
      childId: childId,
    );

    processingRequests.remove(requestId);
    selectedRequests.remove(requestId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  /// Rechazar solicitud de grupo V2
  Future<Map<String, dynamic>> rejectGroupV2Request({
    required String requestId,
  }) async {
    processingRequests.add(requestId);

    final result = await _rejectGroupService.call(requestId: requestId);

    processingRequests.remove(requestId);
    selectedRequests.remove(requestId);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  /// Revocar membresía de grupo
  Future<Map<String, dynamic>> revokeGroupMembership({
    required String groupId,
    required String childId,
  }) async {
    final requestKey = '$groupId-$childId';
    processingRequests.add(requestKey);

    final result = await _revokeGroupService.call(
      groupId: groupId,
      childId: childId,
    );

    processingRequests.remove(requestKey);

    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  // ═══════════════════════════════════════════════════════════════
  // MODERACIÓN IA
  // ═══════════════════════════════════════════════════════════════

  /// Obtener nivel de moderación de un contacto
  Future<String?> getContactModerationLevel({
    required String childId,
    required String contactId,
  }) async {
    final result = await _getModerationService.call(
      childId: childId,
      contactId: contactId,
    );
    return result.moderationLevel;
  }

  /// Actualizar nivel de moderación de un contacto
  Future<Map<String, dynamic>> updateContactModerationLevel({
    required String childId,
    required String contactId,
    required String moderationLevel,
  }) async {
    final result = await _updateModerationService.call(
      childId: childId,
      contactId: contactId,
      moderationLevel: moderationLevel,
    );
    return {'success': result.success, 'error': result.success ? null : result.message};
  }

  // ═══════════════════════════════════════════════════════════════
  // NOTIFICACIONES
  // ═══════════════════════════════════════════════════════════════

  /// Marcar todas las notificaciones de whitelist como leídas
  Future<int> markNotificationsAsRead() async {
    return await _markNotificationsReadService.call(parentId);
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener lista de hijos vinculados con sus nombres
  Future<List<Map<String, String>>> getLinkedChildrenWithNames() async {
    final children = await _linkedChildrenService.getWithNames(parentId);
    return children
        .map((c) => {'id': c.id, 'name': c.name})
        .toList();
  }

  /// Batch fetch de datos de usuarios
  Future<void> _batchFetchUserData(List<String> userIds) async {
    final idsToFetch = userIds.where((id) => !_userDataCache.containsKey(id)).toList();
    if (idsToFetch.isEmpty) return;

    const batchSize = 10;
    for (var i = 0; i < idsToFetch.length; i += batchSize) {
      final batch = idsToFetch.skip(i).take(batchSize).toList();

      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        for (final doc in snapshot.docs) {
          _userDataCache[doc.id] = doc.data();
        }
      } catch (e) {
        ReleaseLogger.error('Error en batch fetch de usuarios: $e', tag: 'WhitelistController');
        for (final userId in batch) {
          await _fetchSingleUser(userId);
        }
      }
    }
  }

  Future<void> _fetchSingleUser(String userId) async {
    try {
      final userData = await app_user.User.getById(userId);
      if (userData != null) {
        _userDataCache[userId] = userData;
      }
    } catch (e) {
      ReleaseLogger.error('Error obteniendo usuario $userId: $e', tag: 'WhitelistController');
    }
  }

  /// Obtener grupos compartidos entre hijo y contacto
  Future<List<Map<String, dynamic>>> getSharedGroups({
    required String childId,
    required String contactId,
  }) async {
    final groups = await _sharedGroupsService.call(
      childId: childId,
      contactId: contactId,
    );
    return groups
        .map((g) => {'id': g.id, 'name': g.name, 'memberCount': g.memberCount})
        .toList();
  }

  /// Remover a hijo de un grupo
  Future<void> removeChildFromGroup({
    required String groupId,
    required String childId,
  }) async {
    await _sharedGroupsService.removeChildFromGroup(
      groupId: groupId,
      childId: childId,
    );
  }

  /// Limpiar recursos
  void dispose() {
    _contactsSubscription?.cancel();
    _groupRequestsSubscription?.cancel();
    _groupMembershipsSubscription?.cancel();
    _linkedChildrenSubscription?.cancel();
    processingRequests.clear();
    selectedRequests.clear();
    _userDataCache.clear();
    _contactsCache.clear();
    _groupRequestsCache.clear();
    _groupMembershipsCache.clear();
  }
}

typedef VoidCallback = void Function();
