import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';

/// Service atómico: Solicitar aprobación de contacto
///
/// Responsabilidad única: Actualizar contacto de potential a pending/approved.
/// Las notificaciones se crean via trigger (onContactApprovalRequested).
class RequestContactApprovalService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  RequestContactApprovalService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Helper: Obtener padres vinculados de un usuario
  Future<List<String>> _getLinkedParents(String userId) async {
    try {
      final links = await _firestore
          .collection('parent_children')
          .where('childId', isEqualTo: userId)
          .where('status', isEqualTo: 'approved')
          .get();
      return links.docs.map((doc) => doc.data()['parentId'] as String).toList();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo padres: $e', tag: 'RequestApproval');
      return [];
    }
  }

  /// Helper: Obtener rol de un usuario
  Future<String> _getUserRole(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.data()?['role'] as String? ?? 'child';
    } catch (e) {
      ReleaseLogger.error('Error obteniendo rol: $e', tag: 'RequestApproval');
      return 'child';
    }
  }

  /// Helper: Determinar rol efectivo (child sin padre = adult)
  String _getEffectiveRole(String role, List<String> parents) {
    if (role == 'child' && parents.isEmpty) {
      return 'adult';
    }
    return role;
  }

  /// Solicitar aprobación para un contacto
  /// Retorna (success, message, newStatus)
  Future<({bool success, String message, String? newStatus})> call(
    String contactDocId,
  ) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (
          success: false,
          message: 'Usuario no autenticado',
          newStatus: null
        );
      }

      ReleaseLogger.log(
        'Solicitando aprobación para: $contactDocId',
        tag: 'RequestApproval',
      );

      // 1. Obtener el contacto
      final contactRef = _firestore.collection('contacts').doc(contactDocId);
      final contactDoc = await contactRef.get();

      if (!contactDoc.exists) {
        return (
          success: false,
          message: 'Contacto no encontrado',
          newStatus: null
        );
      }

      final data = contactDoc.data()!;

      // 2. Verificar que está en estado 'potential'
      if (data['status'] != 'potential') {
        return (
          success: false,
          message: 'El contacto no está en estado sugerido',
          newStatus: null
        );
      }

      // 3. Verificar que el usuario es parte del contacto
      final users = List<String>.from(data['users'] ?? []);
      if (!users.contains(currentUserId)) {
        return (
          success: false,
          message: 'No eres parte de este contacto',
          newStatus: null
        );
      }

      // 4. Obtener datos de usuarios y verificar aprobación
      final isUser1 = users[0] == currentUserId;
      final otherUserId = users.firstWhere((u) => u != currentUserId);

      // Variables para requisitos de aprobación
      List<String> currentUserParents;
      List<String> otherUserParents;
      bool needsInitiatorApproval;
      bool needsTargetApproval;

      // ✅ SECURITY FIX: Si faltan campos pre-calculados, verificar dinámicamente
      // Esto previene bypass de aprobación parental en contactos creados sin estos campos
      final hasPrecalculatedFields =
          data.containsKey('needsInitiatorApproval') &&
          data.containsKey('needsTargetApproval');

      if (hasPrecalculatedFields) {
        // Usar datos pre-calculados
        currentUserParents = List<String>.from(
          isUser1 ? (data['user1Parents'] ?? []) : (data['user2Parents'] ?? []),
        );
        otherUserParents = List<String>.from(
          isUser1 ? (data['user2Parents'] ?? []) : (data['user1Parents'] ?? []),
        );
        needsInitiatorApproval = data['needsInitiatorApproval'] ?? false;
        needsTargetApproval = data['needsTargetApproval'] ?? false;

        ReleaseLogger.log(
          'Usando campos pre-calculados: initiator=$needsInitiatorApproval, target=$needsTargetApproval',
          tag: 'RequestApproval',
        );
      } else {
        // ⚠️ Campos faltantes - verificar dinámicamente desde Firestore
        ReleaseLogger.log(
          '⚠️ Campos pre-calculados faltantes, verificando dinámicamente',
          tag: 'RequestApproval',
        );

        // Obtener padres vinculados de ambos usuarios
        currentUserParents = await _getLinkedParents(currentUserId);
        otherUserParents = await _getLinkedParents(otherUserId);

        // Obtener roles de ambos usuarios
        final currentUserRole = await _getUserRole(currentUserId);
        final otherUserRole = await _getUserRole(otherUserId);

        // Calcular roles efectivos
        final currentEffectiveRole = _getEffectiveRole(currentUserRole, currentUserParents);
        final otherEffectiveRole = _getEffectiveRole(otherUserRole, otherUserParents);

        ReleaseLogger.log(
          'Roles efectivos: current=$currentEffectiveRole, other=$otherEffectiveRole',
          tag: 'RequestApproval',
        );

        // Aplicar matriz de aprobación:
        // - Parent/Adult → Parent/Adult: NO requiere aprobación
        // - Parent/Adult → Child: 1 padre del child (target)
        // - Child → Child: 1 padre de CADA lado
        // - Child → Adult/Parent: solo padres del child (initiator)

        if ((currentEffectiveRole == 'parent' || currentEffectiveRole == 'adult') &&
            (otherEffectiveRole == 'parent' || otherEffectiveRole == 'adult')) {
          needsInitiatorApproval = false;
          needsTargetApproval = false;
        } else if ((currentEffectiveRole == 'parent' || currentEffectiveRole == 'adult') &&
            otherEffectiveRole == 'child') {
          needsInitiatorApproval = false;
          needsTargetApproval = otherUserParents.isNotEmpty;
        } else if (currentEffectiveRole == 'child' &&
            (otherEffectiveRole == 'parent' || otherEffectiveRole == 'adult')) {
          needsInitiatorApproval = currentUserParents.isNotEmpty;
          needsTargetApproval = false;
        } else if (currentEffectiveRole == 'child' && otherEffectiveRole == 'child') {
          needsInitiatorApproval = currentUserParents.isNotEmpty;
          needsTargetApproval = otherUserParents.isNotEmpty;
        } else {
          needsInitiatorApproval = false;
          needsTargetApproval = false;
        }

        ReleaseLogger.log(
          'Requisitos calculados: initiator=$needsInitiatorApproval, target=$needsTargetApproval',
          tag: 'RequestApproval',
        );
      }

      final needsApproval = needsInitiatorApproval || needsTargetApproval;

      // 5. Preparar datos de actualización
      final updateData = <String, dynamic>{
        'initiatorId': currentUserId,
        'requestedAt': FieldValue.serverTimestamp(),
      };

      String newStatus;

      if (!needsApproval) {
        // Auto-aprobar
        newStatus = 'approved';
        updateData['status'] = 'approved';
        updateData['approvedAt'] = FieldValue.serverTimestamp();

        ReleaseLogger.log('Auto-aprobando contacto', tag: 'RequestApproval');
      } else {
        // Requiere aprobación parental
        newStatus = 'pending';
        updateData['status'] = 'pending';
        updateData['completedApprovals'] = [];

        // Preparar mapa de approvals
        final approvalsMap = <String, dynamic>{};
        if (needsInitiatorApproval && currentUserParents.isNotEmpty) {
          approvalsMap[currentUserId] = {
            'status': 'pending',
            'parentId': currentUserParents[0],
            'side': 'initiator',
          };
        }
        if (needsTargetApproval && otherUserParents.isNotEmpty) {
          approvalsMap[otherUserId] = {
            'status': 'pending',
            'parentId': otherUserParents[0],
            'side': 'target',
          };
        }
        if (approvalsMap.isNotEmpty) {
          updateData['approvals'] = approvalsMap;
        }

        ReleaseLogger.log(
          'Contacto pendiente de aprobación',
          tag: 'RequestApproval',
        );
      }

      // 6. Actualizar contacto
      await contactRef.update(updateData);

      final message = newStatus == 'approved'
          ? 'Contacto aprobado automáticamente'
          : 'Solicitud enviada. Tu padre/madre debe aprobarla.';

      ReleaseLogger.log(
        'Contacto actualizado: status=$newStatus',
        tag: 'RequestApproval',
      );

      return (success: true, message: message, newStatus: newStatus);
    } catch (e) {
      ReleaseLogger.error(
        'Error solicitando aprobación: $e',
        tag: 'RequestApproval',
      );
      return (
        success: false,
        message: 'Error al solicitar aprobación',
        newStatus: null
      );
    }
  }
}
