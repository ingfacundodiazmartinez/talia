import 'package:cloud_firestore/cloud_firestore.dart';
import 'user_role_service.dart';

class ChatPermissionService {
  static final ChatPermissionService _instance = ChatPermissionService._internal();
  factory ChatPermissionService() => _instance;
  ChatPermissionService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Verificar si dos usuarios pueden chatear
  /// Casos especiales:
  /// 1. Padre-hijo: Siempre permitido sin aprobación
  /// 2. Adulto-adulto o padre-padre: Permitido si son contactos
  /// 3. Niño-niño: Requiere aprobación BIDIRECCIONAL de ambos padres
  Future<ChatPermissionResult> canUsersChat(String userA, String userB) async {
    try {
      // CASO ESPECIAL 1: Verificar si es una conversación padre-hijo
      final isParentChildChat = await _isParentChildRelationship(userA, userB);
      if (isParentChildChat) {
        return ChatPermissionResult.allowed();
      }

      // CASO ESPECIAL 2: Verificar si ambos son adultos/padres que son contactos
      final areAdultContacts = await _areAdultContacts(userA, userB);
      if (areAdultContacts) {
        return ChatPermissionResult.allowed();
      }

      // CASO NORMAL: Verificar aprobaciones bidireccionales para conversaciones niño-niño
      // Verificar permiso A -> B (padre de A aprueba que A hable con B)
      final permissionAtoB = await _hasParentApproval(
        childId: userA,
        contactId: userB,
      );

      // Verificar permiso B -> A (padre de B aprueba que B hable con A)
      final permissionBtoA = await _hasParentApproval(
        childId: userB,
        contactId: userA,
      );

      if (permissionAtoB && permissionBtoA) {
        return ChatPermissionResult.allowed();
      } else {
        return ChatPermissionResult.denied(
          missingApprovals: _getMissingApprovals(userA, userB, permissionAtoB, permissionBtoA),
        );
      }
    } catch (e) {
      return ChatPermissionResult.error('Error verificando permisos: $e');
    }
  }

  /// Verificar si dos usuarios son adultos/padres que son contactos
  Future<bool> _areAdultContacts(String userA, String userB) async {
    try {
      // Obtener roles de ambos usuarios
      final userADoc = await _firestore.collection('users').doc(userA).get();
      final userBDoc = await _firestore.collection('users').doc(userB).get();

      if (!userADoc.exists || !userBDoc.exists) {
        return false;
      }

      final userAData = userADoc.data() as Map<String, dynamic>;
      final userBData = userBDoc.data() as Map<String, dynamic>;

      final userARole = userAData['role'] ?? 'child';
      final userBRole = userBData['role'] ?? 'child';

      // Verificar que ambos sean adultos o padres
      final isUserAAdult = userARole == 'adult' || userARole == 'parent';
      final isUserBAdult = userBRole == 'adult' || userBRole == 'parent';

      if (!isUserAAdult || !isUserBAdult) {
        return false;
      }

      // Verificar que sean contactos (buscar en la colección contacts)
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userA)
          .get();

      for (final doc in contactsQuery.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);
        if (users.contains(userB)) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Verificar si dos usuarios tienen una relación padre-hijo
  Future<bool> _isParentChildRelationship(String userA, String userB) async {
    try {
      // Verificar si userA es padre de userB
      final isAParentOfB = await _isParentOf(userA, userB);
      if (isAParentOfB) {
        return true;
      }

      // Verificar si userB es padre de userA
      final isBParentOfA = await _isParentOf(userB, userA);
      if (isBParentOfA) {
        return true;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Verificar si un usuario es padre de otro usuario
  /// ⚠️ CORREGIDO: Lee desde /users/{potentialParentId}.linkedChildrenIds por seguridad
  Future<bool> _isParentOf(String potentialParentId, String potentialChildId) async {
    try {
      // Verificar si el padre tiene al hijo en su linkedChildrenIds
      final parentDoc = await _firestore.collection('users').doc(potentialParentId).get();
      if (parentDoc.exists) {
        final parentData = parentDoc.data() as Map<String, dynamic>;
        final linkedChildrenIds = List<String>.from(parentData['linkedChildrenIds'] ?? []);
        if (linkedChildrenIds.contains(potentialChildId)) {
          return true;
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Verificar si el padre de un niño ha aprobado un contacto específico
  /// Busca en la colección contacts unificada y verifica el mapa de approvals
  Future<bool> _hasParentApproval({
    required String childId,
    required String contactId,
  }) async {
    try {
      // Generar el ID del documento de contacto (ordenado alfabéticamente)
      final users = [childId, contactId]..sort();
      final contactDocId = '${users[0]}_${users[1]}';

      // Buscar el documento de contacto
      final contactDoc = await _firestore
          .collection('contacts')
          .doc(contactDocId)
          .get();

      if (!contactDoc.exists) {
        return false;
      }

      final data = contactDoc.data()!;
      final status = data['status'] as String? ?? '';

      // Si el status global es approved, está aprobado para ambos
      if (status == 'approved') {
        return true;
      }

      // Si es pending, verificar el mapa de approvals para este hijo específico
      if (status == 'pending') {
        final approvals = Map<String, dynamic>.from(data['approvals'] ?? {});
        final childApproval = approvals[childId] as Map<String, dynamic>?;
        if (childApproval != null) {
          return childApproval['status'] == 'approved';
        }
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Obtener lista de aprobaciones faltantes
  List<MissingApproval> _getMissingApprovals(
    String userA,
    String userB,
    bool permissionAtoB,
    bool permissionBtoA
  ) {
    final missing = <MissingApproval>[];

    if (!permissionAtoB) {
      missing.add(MissingApproval(
        childId: userA,
        contactId: userB,
        description: 'El padre de $userA debe aprobar el contacto con $userB',
      ));
    }

    if (!permissionBtoA) {
      missing.add(MissingApproval(
        childId: userB,
        contactId: userA,
        description: 'El padre de $userB debe aprobar el contacto con $userA',
      ));
    }

    return missing;
  }

  /// Verificar permisos para múltiples usuarios (para grupos)
  Future<GroupChatPermissionResult> canUsersFormGroup(List<String> userIds) async {
    try {

      final allowedPairs = <String>[];
      final deniedPairs = <String>[];
      final missingApprovals = <MissingApproval>[];

      // Verificar permisos entre cada par de usuarios
      for (int i = 0; i < userIds.length; i++) {
        for (int j = i + 1; j < userIds.length; j++) {
          final userA = userIds[i];
          final userB = userIds[j];

          final result = await canUsersChat(userA, userB);

          if (result.isAllowed) {
            allowedPairs.add('$userA-$userB');
          } else {
            deniedPairs.add('$userA-$userB');
            if (result.missingApprovals != null) {
              missingApprovals.addAll(result.missingApprovals!);
            }
          }
        }
      }

      final allPairsAllowed = deniedPairs.isEmpty;

      return GroupChatPermissionResult(
        allUsersCanChat: allPairsAllowed,
        allowedPairs: allowedPairs,
        deniedPairs: deniedPairs,
        missingApprovals: missingApprovals,
        allowedUsers: allPairsAllowed ? userIds : _getFullyApprovedUsers(userIds, allowedPairs),
      );
    } catch (e) {
      return GroupChatPermissionResult(
        allUsersCanChat: false,
        allowedPairs: [],
        deniedPairs: [],
        missingApprovals: [],
        allowedUsers: [],
        error: 'Error verificando permisos: $e',
      );
    }
  }

  /// Obtener usuarios que tienen permisos completos con todos los demás
  List<String> _getFullyApprovedUsers(List<String> allUsers, List<String> allowedPairs) {
    final fullyApproved = <String>[];

    for (final userId in allUsers) {
      bool canChatWithAll = true;

      for (final otherUserId in allUsers) {
        if (userId == otherUserId) continue;

        // Verificar si este par está en allowedPairs (en cualquier orden)
        final pair1 = '$userId-$otherUserId';
        final pair2 = '$otherUserId-$userId';

        if (!allowedPairs.contains(pair1) && !allowedPairs.contains(pair2)) {
          canChatWithAll = false;
          break;
        }
      }

      if (canChatWithAll) {
        fullyApproved.add(userId);
      }
    }

    return fullyApproved;
  }

  /// Obtener todos los contactos con los que el usuario puede chatear
  Future<List<String>> getBidirectionallyApprovedContacts(String userId) async {
    try {
      final validContacts = <String>{};

      // 1. Obtener hijos vinculados (para padres) - siempre permitidos
      final userRoleService = UserRoleService();
      final linkedChildren = await userRoleService.getLinkedChildren(userId);
      validContacts.addAll(linkedChildren);

      // 2. Obtener padres vinculados (para hijos) - siempre permitidos
      final linkedParents = await userRoleService.getLinkedParents(userId);
      validContacts.addAll(linkedParents);

      // 3. Obtener contactos aprobados de la colección contacts
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      for (final doc in contactsQuery.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);

        // Agregar el otro usuario del array
        for (final otherUserId in users) {
          if (otherUserId != userId) {
            validContacts.add(otherUserId);
          }
        }
      }

      return validContacts.toList();
    } catch (e) {
      return [];
    }
  }

  /// Stream de contactos aprobados bidireccionales
  /// ✅ OPTIMIZADO: Usa snapshots() en lugar de polling cada 2 segundos
  /// Esto reduce lecturas de Firestore ~99% (solo actualiza cuando hay cambios reales)
  Stream<List<String>> watchBidirectionallyApprovedContacts(String userId) {
    return _firestore
        .collection('contacts')
        .where('users', arrayContains: userId)
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) {
          final bidirectionalContacts = <String>{};

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final users = List<String>.from(data['users'] ?? []);
            // Agregar el otro usuario
            for (final otherUserId in users) {
              if (otherUserId != userId) {
                bidirectionalContacts.add(otherUserId);
              }
            }
          }

          return bidirectionalContacts.toList();
        });
  }

  /// Verificar si un chat específico es válido (ambos usuarios pueden chatear)
  Future<bool> isChatValid(String chatId, List<String> participants) async {
    if (participants.length != 2) {
      return false;
    }

    final result = await canUsersChat(participants[0], participants[1]);
    return result.isAllowed;
  }

  /// Verificar si un usuario puede unirse a un grupo existente
  Future<bool> canUserJoinGroup(String userId, List<String> existingMembers) async {
    for (final memberId in existingMembers) {
      final result = await canUsersChat(userId, memberId);
      if (!result.isAllowed) {
        return false;
      }
    }
    return true;
  }
}

// Clases de resultado
class ChatPermissionResult {
  final bool isAllowed;
  final List<MissingApproval>? missingApprovals;
  final String? error;

  ChatPermissionResult._({
    required this.isAllowed,
    this.missingApprovals,
    this.error,
  });

  factory ChatPermissionResult.allowed() {
    return ChatPermissionResult._(isAllowed: true);
  }

  factory ChatPermissionResult.denied({
    required List<MissingApproval> missingApprovals,
  }) {
    return ChatPermissionResult._(
      isAllowed: false,
      missingApprovals: missingApprovals,
    );
  }

  factory ChatPermissionResult.error(String error) {
    return ChatPermissionResult._(
      isAllowed: false,
      error: error,
    );
  }
}

class GroupChatPermissionResult {
  final bool allUsersCanChat;
  final List<String> allowedPairs;
  final List<String> deniedPairs;
  final List<MissingApproval> missingApprovals;
  final List<String> allowedUsers;
  final String? error;

  GroupChatPermissionResult({
    required this.allUsersCanChat,
    required this.allowedPairs,
    required this.deniedPairs,
    required this.missingApprovals,
    required this.allowedUsers,
    this.error,
  });
}

class MissingApproval {
  final String childId;
  final String contactId;
  final String description;

  MissingApproval({
    required this.childId,
    required this.contactId,
    required this.description,
  });

  @override
  String toString() => 'MissingApproval(child: $childId, contact: $contactId, desc: $description)';
}