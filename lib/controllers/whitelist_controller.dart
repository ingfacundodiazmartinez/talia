import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:rxdart/rxdart.dart';
import '../models/contact.dart' as contact_model;
import '../models/grouped_contact.dart';
import '../models/user.dart' as app_user;
import '../groups/groups.dart';
import '../utils/release_logger.dart';

/// Controller simplificado para Control Parental (Lista Blanca)
///
/// Arquitectura unificada:
/// - Una sola query a `/contacts` donde `parentViewers` contiene el parentId
/// - Escrituras directas a Firestore para approve/reject
/// - Fetch de datos de usuarios fresh desde `/users`
/// - Mantiene soporte para grupos V2 (flujo separado)
class WhitelistController {
  final String parentId;
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  // Estado de procesamiento
  final Set<String> processingRequests = {};
  final Set<String> selectedRequests = {};

  // Cache de datos de usuarios
  final Map<String, Map<String, dynamic>> _userDataCache = {};

  WhitelistController({
    required this.parentId,
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  // ═══════════════════════════════════════════════════════════════
  // STREAM PRINCIPAL - CONTACTOS DE HIJOS VINCULADOS
  // ═══════════════════════════════════════════════════════════════

  /// Stream de todos los contactos de los hijos vinculados
  /// Combina queries por cada hijo para obtener todos sus contactos
  Stream<List<contact_model.Contact>> getContactsStream() {
    // Primero obtener los hijos vinculados, luego crear streams para cada uno
    return Stream.fromFuture(_getLinkedChildrenIds()).asyncExpand((childrenIds) {
      if (childrenIds.isEmpty) {
        ReleaseLogger.log('[Whitelist] No hay hijos vinculados', tag: 'WhitelistController');
        return Stream.value(<contact_model.Contact>[]);
      }

      ReleaseLogger.log('[Whitelist] Buscando contactos de ${childrenIds.length} hijos', tag: 'WhitelistController');

      // Crear un stream por cada hijo
      final streams = childrenIds.map((childId) {
        return _firestore
            .collection('contacts')
            .where('users', arrayContains: childId)
            .snapshots()
            .map((snapshot) =>
                snapshot.docs
                    .map((doc) => contact_model.Contact.fromFirestore(doc))
                    .where((contact) => contact.isRealContact) // Filtrar parent_child_link
                    .toList());
      }).toList();

      // Combinar todos los streams y eliminar duplicados
      if (streams.isEmpty) {
        return Stream.value(<contact_model.Contact>[]);
      }

      if (streams.length == 1) {
        return streams.first;
      }

      // Combinar múltiples streams
      return Rx.combineLatestList(streams).map((listOfLists) {
        final allContacts = <String, contact_model.Contact>{};
        for (final list in listOfLists) {
          for (final contact in list) {
            allContacts[contact.id] = contact;
          }
        }
        return allContacts.values.toList();
      });
    });
  }

  /// Stream de grupos V2 pendientes (flujo separado)
  Stream<List<GroupApprovalRequest>> getPendingGroupApprovalRequests() {
    return GroupApprovalRepository().watchPendingRequestsForParent(parentId);
  }

  /// Stream de grupos donde los hijos son miembros aprobados
  /// Usa arrayContainsAny para una sola query (hasta 30 hijos)
  Stream<List<Map<String, dynamic>>> getApprovedGroupMembershipsStream() {
    return Stream.fromFuture(_getLinkedChildrenIds()).asyncExpand((childrenIds) {
      if (childrenIds.isEmpty) {
        ReleaseLogger.log('[Whitelist] No hay hijos vinculados para buscar grupos', tag: 'WhitelistController');
        return Stream.value(<Map<String, dynamic>>[]);
      }

      ReleaseLogger.log('[Whitelist] Buscando grupos aprobados para ${childrenIds.length} hijos', tag: 'WhitelistController');

      // Una sola query usando arrayContainsAny (hasta 30 valores)
      return _firestore
          .collection('groups_v2')
          .where('members', arrayContainsAny: childrenIds)
          .snapshots()
          .map((snapshot) {
            final results = <Map<String, dynamic>>[];

            for (final doc in snapshot.docs) {
              final data = doc.data();
              final members = List<String>.from(data['members'] ?? []);

              // Para cada hijo que es miembro de este grupo, crear una entrada
              for (final childId in childrenIds) {
                if (members.contains(childId)) {
                  results.add({
                    'groupId': doc.id,
                    'groupName': data['name'] ?? 'Grupo',
                    'groupAvatar': data['avatar'],
                    'groupDescription': data['description'],
                    'memberCount': data['memberCount'] ?? 0,
                    'childId': childId,
                    'members': members,
                    'memberDetails': data['memberDetails'] ?? {},
                  });
                }
              }
            }

            ReleaseLogger.log('[Whitelist] Encontrados ${results.length} membresías de grupo aprobadas', tag: 'WhitelistController');
            return results;
          });
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // PROCESAMIENTO Y AGRUPAMIENTO
  // ═══════════════════════════════════════════════════════════════

  /// Agrupa contactos por persona (el otro usuario en el contacto)
  /// y resuelve datos de usuarios fresh
  /// Incluye grupos aprobados donde los hijos son miembros
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

    // Obtener IDs de hijos vinculados
    final linkedChildrenIds = await _getLinkedChildrenIds();
    userIdsToResolve.addAll(linkedChildrenIds);

    // Batch fetch de datos de usuarios
    await _batchFetchUserData(userIdsToResolve.toList());

    // Procesar contactos individuales
    for (final contact in contacts) {
      // Determinar cuál usuario es el hijo y cuál es el contacto
      for (final userId in contact.users) {
        if (!linkedChildrenIds.contains(userId)) continue;

        final childId = userId;
        final contactUserId = contact.getOtherUserId(childId);
        if (contactUserId.isEmpty) continue;

        // Obtener datos del contacto y del hijo
        final contactData = _userDataCache[contactUserId] ?? {};
        final childData = _userDataCache[childId] ?? {};

        final contactName =
            contactData['name'] as String? ?? contactData['displayName'] as String? ?? 'Usuario';
        final contactPhone = contactData['phoneNumber'] as String? ??
            contactData['phone'] as String?;
        final contactPhoto = contactData['photoURL'] as String?;
        final childName = childData['name'] as String? ?? 'Hijo';
        final childPhoto = childData['photoURL'] as String?;

        // Obtener estado de aprobación para este hijo
        // IMPORTANTE: Si el contacto está revocado a nivel documento, usar ese status
        // porque la CF solo actualiza contact.status, no approvals.{childId}.status
        final approval = contact.getApprovalForChild(childId);
        final status = contact.status == 'revoked'
            ? 'revoked'
            : (approval?.status ?? contact.status);

        // Crear o actualizar grupo
        if (!grouped.containsKey(contactUserId)) {
          grouped[contactUserId] = GroupedContact(
            contactId: contactUserId,
            contactName: contactName,
            contactPhone: contactPhone,
            contactPhotoURL: contactPhoto,
            childRelations: [],
          );
        }

        // Verificar si ya existe esta relación hijo-contacto
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

      // Usar groupId como key (prefijado para evitar colisiones con contactos)
      final key = 'group_$groupId';

      if (!grouped.containsKey(key)) {
        grouped[key] = GroupedContact(
          contactId: groupId,
          contactName: groupName,
          contactPhone: null, // Los grupos no tienen teléfono
          contactPhotoURL: groupAvatar,
          childRelations: [],
        );
      }

      // Verificar si ya existe esta relación hijo-grupo
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
              contactDocId: request.id, // ID del request para aprobar/rechazar
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

      // Usar groupId como key (prefijado para evitar colisiones con contactos)
      final key = 'group_$groupId';

      if (!grouped.containsKey(key)) {
        grouped[key] = GroupedContact(
          contactId: groupId,
          contactName: groupName,
          contactPhone: null, // Los grupos no tienen teléfono
          contactPhotoURL: groupAvatar,
          childRelations: [],
        );
      }

      // Verificar si ya existe esta relación hijo-grupo
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

    // Convertir a lista y ordenar
    final result = grouped.values.toList();
    result.sort((a, b) {
      // Primero por prioridad (pending > approved > rejected)
      final priorityCompare = a.sortPriority.compareTo(b.sortPriority);
      if (priorityCompare != 0) return priorityCompare;
      // Luego alfabético por nombre
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
  // ACCIONES DIRECTAS A FIRESTORE (SIN CLOUD FUNCTIONS)
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar un contacto - escritura directa a Firestore
  Future<Map<String, dynamic>> approveContact({
    required String contactDocId,
    required String childId,
  }) async {
    ReleaseLogger.log('🔄 [ApproveContact] Iniciando aprobación: contactDocId=$contactDocId, childId=$childId', tag: 'WhitelistController');
    processingRequests.add(contactDocId);

    try {
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      ReleaseLogger.log('📖 [ApproveContact] Leyendo documento de contacto...', tag: 'WhitelistController');
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        ReleaseLogger.error('❌ [ApproveContact] Documento no existe: $contactDocId', tag: 'WhitelistController');
        throw Exception('Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);
      ReleaseLogger.log('📋 [ApproveContact] Contacto cargado. parentViewers: ${contact.parentViewers}', tag: 'WhitelistController');

      // Verificar que este padre tiene permiso para aprobar
      if (!contact.parentViewers.contains(parentId)) {
        ReleaseLogger.error('❌ [ApproveContact] Padre $parentId no tiene permiso. parentViewers: ${contact.parentViewers}', tag: 'WhitelistController');
        throw Exception('No tienes permiso para aprobar este contacto');
      }

      // Actualizar aprobación para este hijo
      final updates = <String, dynamic>{
        'approvals.$childId.status': 'approved',
        'approvals.$childId.approvedBy': parentId,
        'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
      };

      // Verificar si todas las aprobaciones están completas
      final approvals = Map<String, contact_model.ApprovalStatus>.from(contact.approvals);
      approvals[childId] = contact_model.ApprovalStatus(
        status: 'approved',
        parentId: approvals[childId]?.parentId,
        approvedBy: parentId,
        approvedAt: DateTime.now(),
      );

      final allApproved = approvals.values.every((a) => a.isApproved);
      if (allApproved) {
        updates['status'] = 'approved';
        ReleaseLogger.log('✅ [ApproveContact] Todas las aprobaciones completas, actualizando status a approved', tag: 'WhitelistController');
      }

      ReleaseLogger.log('📤 [ApproveContact] Actualizando Firestore con: $updates', tag: 'WhitelistController');
      await contactRef.update(updates);
      ReleaseLogger.log('✅ [ApproveContact] Firestore actualizado exitosamente', tag: 'WhitelistController');

      // Procesar invitaciones de grupo pendientes
      try {
        final contactUserId = contact.getOtherUserId(childId);
        final contactData = await _getUserData(contactUserId);
        final contactPhone = contactData['phoneNumber'] as String? ??
            contactData['phone'] as String?;

        if (contactPhone != null && contactPhone.isNotEmpty) {
          ReleaseLogger.log('🔄 [ApproveContact] Procesando invitaciones de grupo para $contactPhone', tag: 'WhitelistController');
          await _functions
              .httpsCallable('processGroupInvitationsAfterContactApproval')
              .call({
            'childId': childId,
            'contactPhone': contactPhone,
          });
        }
      } catch (e) {
        ReleaseLogger.error('⚠️ [ApproveContact] Error procesando invitaciones de grupo (no crítico): $e', tag: 'WhitelistController');
      }

      processingRequests.remove(contactDocId);
      selectedRequests.remove(contactDocId);

      ReleaseLogger.log('✅ [ApproveContact] Aprobación completada exitosamente', tag: 'WhitelistController');
      return {'success': true};
    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [ApproveContact] Error: $e', tag: 'WhitelistController');
      ReleaseLogger.error('❌ [ApproveContact] StackTrace: $stackTrace', tag: 'WhitelistController');
      processingRequests.remove(contactDocId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  /// Rechazar un contacto - escritura directa a Firestore
  Future<Map<String, dynamic>> rejectContact({
    required String contactDocId,
    required String childId,
  }) async {
    processingRequests.add(contactDocId);

    try {
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        throw Exception('Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);

      if (!contact.parentViewers.contains(parentId)) {
        throw Exception('No tienes permiso para rechazar este contacto');
      }

      // Actualizar aprobación para este hijo
      await contactRef.update({
        'approvals.$childId.status': 'rejected',
        'approvals.$childId.rejectedBy': parentId,
        'approvals.$childId.rejectedAt': FieldValue.serverTimestamp(),
        'status': 'rejected',
      });

      processingRequests.remove(contactDocId);
      selectedRequests.remove(contactDocId);

      return {'success': true};
    } catch (e) {
      processingRequests.remove(contactDocId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  /// Revocar un contacto aprobado
  Future<Map<String, dynamic>> revokeContact({
    required String contactDocId,
    required String childId,
    List<String>? groupsToRemove,
  }) async {
    ReleaseLogger.log('🔄 [RevokeContact] Iniciando: contactDocId=$contactDocId, childId=$childId', tag: 'WhitelistController');
    processingRequests.add(contactDocId);

    try {
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        ReleaseLogger.error('❌ [RevokeContact] Contacto no encontrado: $contactDocId', tag: 'WhitelistController');
        throw Exception('Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);
      ReleaseLogger.log('📋 [RevokeContact] Contacto cargado. parentViewers: ${contact.parentViewers}, parentId: $parentId', tag: 'WhitelistController');

      if (!contact.parentViewers.contains(parentId)) {
        ReleaseLogger.error('❌ [RevokeContact] Sin permiso. parentViewers: ${contact.parentViewers}', tag: 'WhitelistController');
        throw Exception('No tienes permiso para revocar este contacto');
      }

      final contactUserId = contact.getOtherUserId(childId);
      ReleaseLogger.log('📝 [RevokeContact] Actualizando Firestore...', tag: 'WhitelistController');

      // Actualizar estado a revocado
      await contactRef.update({
        'status': 'revoked',
        'revokedAt': FieldValue.serverTimestamp(),
        'revokedBy': parentId,
        'revokedReason': 'Revocado por padre',
      });
      ReleaseLogger.log('✅ [RevokeContact] Firestore actualizado', tag: 'WhitelistController');

      // Bloquear el chat usando Cloud Function (requiere permisos especiales)
      if (contactUserId.isNotEmpty) {
        try {
          await _functions.httpsCallable('blockChat').call({
            'childId': childId,
            'contactId': contactUserId,
            'reason': 'Contacto revocado por el padre',
            'blockedBy': parentId,
          });
        } catch (e) {
          ReleaseLogger.error('Error bloqueando chat: $e');
        }
      }

      // Remover de grupos si se especificaron
      if (groupsToRemove != null && groupsToRemove.isNotEmpty) {
        for (final groupId in groupsToRemove) {
          await removeChildFromGroup(groupId: groupId, childId: childId);
        }
      }

      processingRequests.remove(contactDocId);
      ReleaseLogger.log('✅ [RevokeContact] Completado exitosamente', tag: 'WhitelistController');
      return {'success': true};
    } catch (e, stackTrace) {
      ReleaseLogger.error('❌ [RevokeContact] Error: $e', tag: 'WhitelistController');
      ReleaseLogger.error('❌ [RevokeContact] StackTrace: $stackTrace', tag: 'WhitelistController');
      processingRequests.remove(contactDocId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  /// Re-aprobar un contacto rechazado
  Future<Map<String, dynamic>> reApproveContact({
    required String contactDocId,
    required String childId,
  }) async {
    processingRequests.add(contactDocId);

    try {
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        throw Exception('Contacto no encontrado');
      }

      final contact = contact_model.Contact.fromFirestore(contactDoc);

      if (!contact.parentViewers.contains(parentId)) {
        throw Exception('No tienes permiso para re-aprobar este contacto');
      }

      // Actualizar aprobación
      await contactRef.update({
        'approvals.$childId.status': 'approved',
        'approvals.$childId.approvedBy': parentId,
        'approvals.$childId.approvedAt': FieldValue.serverTimestamp(),
        'status': 'approved',
        'revokedAt': FieldValue.delete(),
        'revokedBy': FieldValue.delete(),
        'revokedReason': FieldValue.delete(),
      });

      // Desbloquear el chat
      final contactUserId = contact.getOtherUserId(childId);
      if (contactUserId.isNotEmpty) {
        try {
          await _functions.httpsCallable('unblockChat').call({
            'childId': childId,
            'contactId': contactUserId,
          });
        } catch (e) {
          ReleaseLogger.error('Error desbloqueando chat: $e');
        }
      }

      processingRequests.remove(contactDocId);
      return {'success': true};
    } catch (e) {
      processingRequests.remove(contactDocId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GRUPOS V2 (MANTIENE CLOUD FUNCTIONS)
  // ═══════════════════════════════════════════════════════════════

  /// Aprobar solicitud de grupo V2
  Future<Map<String, dynamic>> approveGroupV2Request({
    required String requestId,
    required String groupId,
    required String childId,
  }) async {
    processingRequests.add(requestId);

    try {
      await _functions.httpsCallable('approveGroupMembership').call({
        'requestId': requestId,
        'groupId': groupId,
        'childId': childId,
      });

      processingRequests.remove(requestId);
      selectedRequests.remove(requestId);
      return {'success': true};
    } catch (e) {
      processingRequests.remove(requestId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  /// Rechazar solicitud de grupo V2
  Future<Map<String, dynamic>> rejectGroupV2Request({
    required String requestId,
  }) async {
    processingRequests.add(requestId);

    try {
      await _functions.httpsCallable('rejectGroupMembership').call({
        'requestId': requestId,
      });

      processingRequests.remove(requestId);
      selectedRequests.remove(requestId);
      return {'success': true};
    } catch (e) {
      processingRequests.remove(requestId);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  /// Revocar membresía de grupo (sacar hijo del grupo)
  Future<Map<String, dynamic>> revokeGroupMembership({
    required String groupId,
    required String childId,
  }) async {
    final requestKey = '$groupId-$childId';
    processingRequests.add(requestKey);

    try {
      ReleaseLogger.log('[RevokeGroup] Sacando a $childId del grupo $groupId', tag: 'WhitelistController');

      await _functions.httpsCallable('revokeGroupMembership').call({
        'groupId': groupId,
        'childId': childId,
      });

      processingRequests.remove(requestKey);
      ReleaseLogger.log('[RevokeGroup] Éxito: $childId removido del grupo $groupId', tag: 'WhitelistController');
      return {'success': true};
    } catch (e) {
      ReleaseLogger.error('[RevokeGroup] Error: $e', tag: 'WhitelistController');
      processingRequests.remove(requestKey);
      return {'success': false, 'error': _getErrorMessage(e)};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener IDs de hijos vinculados
  Future<List<String>> _getLinkedChildrenIds() async {
    final parentDoc = await _firestore.collection('users').doc(parentId).get();
    return List<String>.from(parentDoc.data()?['linkedChildrenIds'] ?? []);
  }

  /// Stream de IDs de hijos vinculados
  Stream<List<String>> getLinkedChildrenIdsStream() {
    return _firestore
        .collection('users')
        .doc(parentId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) return <String>[];
      return List<String>.from(snapshot.data()?['linkedChildrenIds'] ?? []);
    });
  }

  /// Obtener lista de hijos vinculados con sus nombres
  Future<List<Map<String, String>>> getLinkedChildrenWithNames() async {
    final children = <Map<String, String>>[];

    try {
      final linkedChildrenIds = await _getLinkedChildrenIds();

      for (final childId in linkedChildrenIds) {
        final childData = await _getUserData(childId);
        children.add({
          'id': childId,
          'name': childData['name'] as String? ?? 'Hijo',
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error obteniendo hijos vinculados: $e');
    }

    return children;
  }

  /// Batch fetch de datos de usuarios
  Future<void> _batchFetchUserData(List<String> userIds) async {
    final idsToFetch =
        userIds.where((id) => !_userDataCache.containsKey(id)).toList();

    if (idsToFetch.isEmpty) return;

    // Firestore limita a 10 documentos por IN query
    const batchSize = 10;
    for (var i = 0; i < idsToFetch.length; i += batchSize) {
      final batch = idsToFetch.skip(i).take(batchSize).toList();

      try {
        final snapshot = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        for (final doc in snapshot.docs) {
          _userDataCache[doc.id] = doc.data();
        }
      } catch (e) {
        ReleaseLogger.error('Error en batch fetch de usuarios: $e');
        // Fetch individual como fallback
        for (final userId in batch) {
          await _getUserData(userId);
        }
      }
    }
  }

  /// Obtener datos de un usuario (con cache)
  Future<Map<String, dynamic>> _getUserData(String userId) async {
    if (_userDataCache.containsKey(userId)) {
      return _userDataCache[userId]!;
    }

    try {
      final userData = await app_user.User.getById(userId);
      if (userData != null) {
        _userDataCache[userId] = userData;
        return userData;
      }
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de usuario $userId: $e');
    }

    return {};
  }

  /// Obtener grupos compartidos entre hijo y contacto
  Future<List<Map<String, dynamic>>> getSharedGroups({
    required String childId,
    required String contactId,
  }) async {
    try {
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: childId)
          .where('isActive', isEqualTo: true)
          .get();

      final sharedGroups = <Map<String, dynamic>>[];

      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        final members = List<String>.from(data['members'] ?? []);

        if (members.contains(contactId)) {
          sharedGroups.add({
            'id': doc.id,
            'name': data['name'] ?? 'Grupo sin nombre',
            'memberCount': members.length,
          });
        }
      }

      return sharedGroups;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo grupos compartidos: $e');
      return [];
    }
  }

  /// Remover a hijo de un grupo
  Future<void> removeChildFromGroup({
    required String groupId,
    required String childId,
  }) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'members': FieldValue.arrayRemove([childId]),
      });
    } catch (e) {
      ReleaseLogger.error('Error removiendo niño del grupo: $e');
      rethrow;
    }
  }

  /// Obtener mensaje de error amigable
  String _getErrorMessage(dynamic error) {
    if (error is FirebaseFunctionsException) {
      switch (error.code) {
        case 'failed-precondition':
          return 'Esta solicitud ya fue procesada';
        case 'permission-denied':
          return 'No tienes permiso para realizar esta acción';
        case 'not-found':
          return 'Solicitud no encontrada';
        case 'unauthenticated':
          return 'Debes iniciar sesión nuevamente';
        default:
          return error.message ?? 'Error al procesar solicitud';
      }
    }
    return error.toString();
  }

  /// Limpiar recursos
  void dispose() {
    processingRequests.clear();
    selectedRequests.clear();
    _userDataCache.clear();
  }
}
