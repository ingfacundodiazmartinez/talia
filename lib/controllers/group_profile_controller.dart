import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/contact_alias_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica del perfil de grupo
///
/// Responsabilidades:
/// - Gestión de información del grupo
/// - Operaciones CRUD de miembros
/// - Actualización de configuración del grupo
/// - Coordinación con Firebase Services
/// - Gestión de avatares y multimedia
class GroupProfileController {
  final String groupId;

  // Servicios privados
  final ContactAliasService _aliasService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;

  // Estado del controlador
  Map<String, dynamic>? _groupData;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _pendingRequests = [];
  bool _isAdmin = false;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  // Subscripciones
  StreamSubscription? _groupDataSubscription;
  StreamSubscription? _membersSubscription;

  // Callbacks para comunicación con el screen
  Function(Map<String, dynamic>?)? onGroupDataChanged;
  Function(List<Map<String, dynamic>>)? onMembersChanged;
  Function(List<Map<String, dynamic>>)? onPendingRequestsChanged;
  Function(bool)? onAdminStatusChanged;
  Function(bool)? onLoadingChanged;
  Function(String)? onError;
  Function(String)? onSuccess;

  // Constructor
  GroupProfileController({
    required this.groupId,
    ContactAliasService? aliasService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    FirebaseStorage? storage,
    FirebaseFunctions? functions,
  }) : _aliasService = aliasService ?? ContactAliasService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _functions = functions ?? FirebaseFunctions.instance;

  // Getters para el estado
  Map<String, dynamic>? get groupData => _groupData;
  List<Map<String, dynamic>> get members => _members;
  List<Map<String, dynamic>> get pendingRequests => _pendingRequests;
  bool get isAdmin => _isAdmin;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  String? get errorMessage => _errorMessage;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Inicializar el controller
  Future<void> initialize() async {
    try {
      _setLoading(true);
      _clearError();

      // Cargar datos iniciales
      await Future.wait([
        _loadGroupData(),
        _loadMembers(),
        _loadPendingRequests(),
      ]);

      // Verificar si es admin
      _checkAdminStatus();

      // Configurar listeners para actualizaciones en tiempo real
      _setupListeners();

      _setLoading(false);
    } catch (e) {
      _setError('Error inicializando perfil del grupo: $e');
      _setLoading(false);
    }
  }

  /// Cargar datos del grupo
  Future<void> _loadGroupData() async {
    try {
      final groupDoc = await _firestore
          .collection('groups')
          .doc(groupId)
          .get();

      if (groupDoc.exists) {
        _groupData = {
          'id': groupDoc.id,
          ...groupDoc.data()!,
        };
        onGroupDataChanged?.call(_groupData);
      } else {
        throw 'Grupo no encontrado';
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando datos del grupo: $e', tag: 'GroupProfile');
      rethrow;
    }
  }

  /// Cargar miembros del grupo
  Future<void> _loadMembers() async {
    try {
      final memberIds = List<String>.from(_groupData?['members'] ?? []);
      final List<Map<String, dynamic>> loadedMembers = [];

      for (final userId in memberIds) {
        try {
          final userDoc = await _firestore
              .collection('users')
              .doc(userId)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data()!;

            // Obtener alias personalizado si existe
            final displayName = await _aliasService.getDisplayName(
              userId,
              userData['name'] ?? 'Usuario',
            );

            loadedMembers.add({
              'id': userId,
              'name': userData['name'] ?? 'Usuario',
              'displayName': displayName,
              'photoURL': userData['photoURL'],
              'role': userData['role'],
              'isOnline': userData['isOnline'] ?? false,
              'lastSeen': userData['lastSeen'],
            });
          }
        } catch (e) {
          ReleaseLogger.error('Error cargando miembro $userId: $e', tag: 'GroupProfile');
          // Continuar con otros miembros si uno falla
        }
      }

      _members = loadedMembers;
      onMembersChanged?.call(_members);
    } catch (e) {
      ReleaseLogger.error('Error cargando miembros: $e', tag: 'GroupProfile');
      rethrow;
    }
  }

  /// Cargar solicitudes pendientes
  Future<void> _loadPendingRequests() async {
    try {
      final requests = await _firestore
          .collection('group_requests')
          .where('groupId', isEqualTo: groupId)
          .where('status', isEqualTo: 'pending')
          .get();

      final List<Map<String, dynamic>> loadedRequests = [];

      for (final requestDoc in requests.docs) {
        final requestData = requestDoc.data();
        final userId = requestData['userId'];

        try {
          final userDoc = await _firestore
              .collection('users')
              .doc(userId)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data()!;
            loadedRequests.add({
              'requestId': requestDoc.id,
              'userId': userId,
              'name': userData['name'] ?? 'Usuario',
              'photoURL': userData['photoURL'],
              'requestedAt': requestData['requestedAt'],
              'message': requestData['message'],
            });
          }
        } catch (e) {
          ReleaseLogger.error('Error cargando solicitud de $userId: $e', tag: 'GroupProfile');
        }
      }

      _pendingRequests = loadedRequests;
      onPendingRequestsChanged?.call(_pendingRequests);
    } catch (e) {
      ReleaseLogger.error('Error cargando solicitudes pendientes: $e', tag: 'GroupProfile');
      rethrow;
    }
  }

  /// Verificar si el usuario actual es admin
  void _checkAdminStatus() {
    final currentUserId = _auth.currentUser?.uid;
    final admins = List<String>.from(_groupData?['admins'] ?? []);
    _isAdmin = currentUserId != null && admins.contains(currentUserId);
    onAdminStatusChanged?.call(_isAdmin);
  }

  /// Configurar listeners para actualizaciones en tiempo real
  void _setupListeners() {
    // Listener para datos del grupo
    _groupDataSubscription = _firestore
        .collection('groups')
        .doc(groupId)
        .snapshots()
        .listen(
          (snapshot) {
            if (snapshot.exists) {
              _groupData = {
                'id': snapshot.id,
                ...snapshot.data()!,
              };
              onGroupDataChanged?.call(_groupData);

              // Recargar miembros si la lista cambió
              _loadMembers();
              _checkAdminStatus();
            }
          },
          onError: (error) {
            ReleaseLogger.error('Error en stream de grupo: $error', tag: 'GroupProfile');
          },
        );
  }

  /// Actualizar información del grupo
  Future<bool> updateGroupInfo({
    String? name,
    String? description,
    File? avatarFile,
  }) async {
    if (!_isAdmin) {
      onError?.call('Solo los administradores pueden editar el grupo');
      return false;
    }

    try {
      _setLoading(true);

      final Map<String, dynamic> updates = {};

      if (name != null && name.isNotEmpty) {
        updates['name'] = name.trim();
      }

      if (description != null) {
        updates['description'] = description.trim();
      }

      // Subir avatar si se proporcionó
      if (avatarFile != null) {
        final avatarUrl = await _uploadGroupAvatar(avatarFile);
        updates['photoURL'] = avatarUrl;
      }

      if (updates.isNotEmpty) {
        updates['updatedAt'] = FieldValue.serverTimestamp();

        await _firestore
            .collection('groups')
            .doc(groupId)
            .update(updates);

        onSuccess?.call('Información del grupo actualizada');
        return true;
      }

      return false;
    } catch (e) {
      ReleaseLogger.error('Error actualizando grupo: $e', tag: 'GroupProfile');
      onError?.call('Error actualizando información del grupo');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Subir avatar del grupo
  Future<String> _uploadGroupAvatar(File file) async {
    try {
      final ref = _storage
          .ref()
          .child('group_avatars')
          .child('$groupId.jpg');

      final uploadTask = ref.putFile(file);
      final snapshot = await uploadTask;

      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      ReleaseLogger.error('Error subiendo avatar: $e', tag: 'GroupProfile');
      throw 'Error subiendo imagen';
    }
  }

  /// Remover miembro del grupo
  Future<bool> removeMember(String userId) async {
    if (!_isAdmin) {
      onError?.call('Solo los administradores pueden remover miembros');
      return false;
    }

    if (userId == currentUserId) {
      onError?.call('No puedes removerte a ti mismo');
      return false;
    }

    try {
      final functions = _functions;
      final result = await functions.httpsCallable('removeGroupMember').call({
        'groupId': groupId,
        'userId': userId,
      });

      if (result.data['success'] == true) {
        onSuccess?.call('Miembro removido del grupo');
        return true;
      } else {
        onError?.call(result.data['error'] ?? 'Error removiendo miembro');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Error removiendo miembro: $e', tag: 'GroupProfile');
      onError?.call('Error removiendo miembro del grupo');
      return false;
    }
  }

  /// Aprobar solicitud de ingreso
  Future<bool> approveRequest(String requestId, String userId) async {
    if (!_isAdmin) {
      onError?.call('Solo los administradores pueden aprobar solicitudes');
      return false;
    }

    try {
      final functions = _functions;
      final result = await functions.httpsCallable('approveGroupRequest').call({
        'requestId': requestId,
        'groupId': groupId,
        'userId': userId,
      });

      if (result.data['success'] == true) {
        onSuccess?.call('Solicitud aprobada');
        await _loadPendingRequests(); // Recargar solicitudes
        return true;
      } else {
        onError?.call(result.data['error'] ?? 'Error aprobando solicitud');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Error aprobando solicitud: $e', tag: 'GroupProfile');
      onError?.call('Error aprobando solicitud');
      return false;
    }
  }

  /// Rechazar solicitud de ingreso
  Future<bool> rejectRequest(String requestId) async {
    if (!_isAdmin) {
      onError?.call('Solo los administradores pueden rechazar solicitudes');
      return false;
    }

    try {
      await _firestore
          .collection('group_requests')
          .doc(requestId)
          .update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
      });

      onSuccess?.call('Solicitud rechazada');
      await _loadPendingRequests(); // Recargar solicitudes
      return true;
    } catch (e) {
      ReleaseLogger.error('Error rechazando solicitud: $e', tag: 'GroupProfile');
      onError?.call('Error rechazando solicitud');
      return false;
    }
  }

  /// Abandonar grupo
  Future<bool> leaveGroup() async {
    if (_isAdmin) {
      // Si es admin, verificar que haya otros admins
      final admins = List<String>.from(_groupData?['admins'] ?? []);
      if (admins.length <= 1) {
        onError?.call('Debes transferir el rol de administrador antes de abandonar el grupo');
        return false;
      }
    }

    try {
      final functions = _functions;
      final result = await functions.httpsCallable('leaveGroup').call({
        'groupId': groupId,
      });

      if (result.data['success'] == true) {
        onSuccess?.call('Has abandonado el grupo');
        return true;
      } else {
        onError?.call(result.data['error'] ?? 'Error abandonando grupo');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Error abandonando grupo: $e', tag: 'GroupProfile');
      onError?.call('Error abandonando el grupo');
      return false;
    }
  }

  /// Métodos de utilidad privados
  void _setLoading(bool loading) {
    _isLoading = loading;
    onLoadingChanged?.call(loading);
  }

  void _setError(String error) {
    _hasError = true;
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _hasError = false;
    _errorMessage = null;
  }

  /// Limpiar recursos
  void dispose() {
    _groupDataSubscription?.cancel();
    _membersSubscription?.cancel();
  }
}