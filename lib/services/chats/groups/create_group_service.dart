import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../utils/release_logger.dart';

/// Servicio atómico: Crear grupo
///
/// Responsabilidad única: Crear un nuevo grupo de chat
///
/// Estructura del grupo en Firestore (collection: groups_v2):
/// - type: 'group'
/// - name: string
/// - description: string?
/// - photoURL: string?
/// - members: [userId1, userId2, ...]
/// - admins: [creatorId]
/// - createdBy: userId
/// - createdAt: timestamp
/// - lastActivity: timestamp
class CreateGroupService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CreateGroupService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Crear un nuevo grupo
  ///
  /// [name] - Nombre del grupo
  /// [memberIds] - Lista de IDs de miembros (sin incluir al creador)
  /// [description] - Descripción opcional
  /// [photoUrl] - URL de foto del grupo opcional
  ///
  /// Retorna (success, groupId, message)
  Future<({bool success, String? groupId, String message})> call({
    required String name,
    required List<String> memberIds,
    String? description,
    String? photoUrl,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return (
          success: false,
          groupId: null,
          message: 'Usuario no autenticado',
        );
      }

      // Validar nombre
      if (name.trim().isEmpty) {
        return (
          success: false,
          groupId: null,
          message: 'El nombre del grupo es requerido',
        );
      }

      // Validar miembros mínimos
      if (memberIds.isEmpty) {
        return (
          success: false,
          groupId: null,
          message: 'Debes agregar al menos un miembro',
        );
      }

      // Asegurar que el creador está en la lista de miembros
      final allMembers = {userId, ...memberIds}.toList();

      // Crear documento del grupo
      final groupData = {
        'type': 'group',
        'name': name.trim(),
        'description': description?.trim() ?? '',
        'photoURL': photoUrl,
        'members': allMembers,
        'admins': [userId], // El creador es admin
        'createdBy': userId,
        'createdAt': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': null,
        'lastMessageTime': null,
        'lastMessageSender': null,
      };

      final docRef = await _firestore.collection('groups_v2').add(groupData);
      final groupId = docRef.id;

      ReleaseLogger.log(
        'Grupo creado: $groupId con ${allMembers.length} miembros',
        tag: 'CreateGroup',
      );

      return (
        success: true,
        groupId: groupId,
        message: 'Grupo creado exitosamente',
      );
    } catch (e) {
      ReleaseLogger.error('Error creando grupo: $e', tag: 'CreateGroup');
      return (
        success: false,
        groupId: null,
        message: 'Error al crear grupo',
      );
    }
  }
}
