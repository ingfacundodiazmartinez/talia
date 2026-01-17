import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/contact_alias_service.dart';
import '../services/favorite_service.dart';
import '../services/group_moderation_service.dart';
import '../models/chat_message.dart';
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
  final FavoriteService _favoriteService;
  final GroupModerationService _moderationService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;

  // Estado del controlador
  Map<String, dynamic>? _groupData;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _pendingMembers = []; // Usuarios pendientes de aprobación de permisos
  List<Map<String, dynamic>> _pendingRequests = [];
  List<ChatMessage> _favoriteMessages = [];
  bool _isLoadingFavorites = false;
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
  Function(List<Map<String, dynamic>>)? onPendingMembersChanged;
  Function(List<Map<String, dynamic>>)? onPendingRequestsChanged;
  Function(List<ChatMessage>)? onFavoritesChanged;
  Function(bool)? onAdminStatusChanged;
  Function(bool)? onLoadingChanged;
  Function(String)? onError;
  Function(String)? onSuccess;

  // Constructor
  GroupProfileController({
    required this.groupId,
    ContactAliasService? aliasService,
    FavoriteService? favoriteService,
    GroupModerationService? moderationService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    FirebaseStorage? storage,
    FirebaseFunctions? functions,
  }) : _aliasService = aliasService ?? ContactAliasService(),
       _favoriteService = favoriteService ?? FavoriteService(),
       _moderationService = moderationService ?? GroupModerationService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _functions = functions ?? FirebaseFunctions.instance;

  // Getters para el estado
  Map<String, dynamic>? get groupData => _groupData;
  List<Map<String, dynamic>> get members => _members;
  List<Map<String, dynamic>> get pendingMembers => _pendingMembers;
  List<Map<String, dynamic>> get pendingRequests => _pendingRequests;
  List<ChatMessage> get favoriteMessages => _favoriteMessages;
  bool get isLoadingFavorites => _isLoadingFavorites;
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
      await _loadGroupData();
      await Future.wait([
        _loadMembers(),
        _loadPendingMembers(),
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
          .collection('groups_v2')
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

  /// Cargar miembros pendientes de aprobación de permisos
  Future<void> _loadPendingMembers() async {
    try {
      final pendingMemberIds = List<String>.from(_groupData?['pendingMembers'] ?? []);
      final List<Map<String, dynamic>> loadedPendingMembers = [];

      for (final userId in pendingMemberIds) {
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

            loadedPendingMembers.add({
              'id': userId,
              'name': userData['name'] ?? 'Usuario',
              'displayName': displayName,
              'photoURL': userData['photoURL'],
              'role': userData['role'],
            });
          }
        } catch (e) {
          ReleaseLogger.error('Error cargando pending member $userId: $e', tag: 'GroupProfile');
        }
      }

      _pendingMembers = loadedPendingMembers;
      onPendingMembersChanged?.call(_pendingMembers);
      ReleaseLogger.log('Cargados ${_pendingMembers.length} miembros pendientes', tag: 'GroupProfile');
    } catch (e) {
      ReleaseLogger.error('Error cargando miembros pendientes: $e', tag: 'GroupProfile');
      // No rethrow - es información opcional
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

  /// Cargar mensajes favoritos del grupo
  Future<void> loadFavorites() async {
    try {
      _isLoadingFavorites = true;
      onFavoritesChanged?.call(_favoriteMessages);

      final favoriteMaps = await _favoriteService.getFavoriteMessagesForProfile(
        chatId: groupId,
        isGroupChat: true,
      );

      // Convertir a ChatMessage
      _favoriteMessages = favoriteMaps.map((map) {
        return ChatMessage.fromMap(map['id'] ?? '', map);
      }).toList();

      // Ordenar por timestamp (más reciente primero)
      _favoriteMessages.sort((a, b) {
        if (a.timestamp == null && b.timestamp == null) return 0;
        if (a.timestamp == null) return 1;
        if (b.timestamp == null) return -1;
        return b.timestamp!.compareTo(a.timestamp!);
      });

      _isLoadingFavorites = false;
      onFavoritesChanged?.call(_favoriteMessages);
    } catch (e) {
      ReleaseLogger.error('Error cargando favoritos: $e', tag: 'GroupProfile');
      _isLoadingFavorites = false;
      // No rethrow - los favoritos son opcionales
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
        .collection('groups_v2')
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

              // Recargar miembros y pending members si la lista cambió
              _loadMembers();
              _loadPendingMembers();
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
        updates['avatar'] = avatarUrl;
      }

      if (updates.isNotEmpty) {
        updates['updatedAt'] = FieldValue.serverTimestamp();

        await _firestore
            .collection('groups_v2')
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
      final result = await functions.httpsCallable('leaveGroupV2').call({
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

  // ═══════════════════════════════════════════════════════════════
  // MODERACIÓN DEL GRUPO
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si el usuario actual puede modificar la moderación del grupo
  ///
  /// Retorna (canModify, reason)
  Future<({bool canModify, String reason})> canModifyModeration() async {
    return _moderationService.canModifyModeration(groupId);
  }

  /// Obtener estado actual de moderación
  bool get moderationEnabled => _groupData?['moderationEnabled'] as bool? ?? false;
  String get moderationLevel => _groupData?['moderationLevel'] as String? ?? 'high';

  /// Actualizar configuración de moderación del grupo
  ///
  /// [enabled] - Activar o desactivar moderación
  /// [level] - Nivel de moderación: 'high', 'medium', 'low'
  Future<bool> setModeration({
    required bool enabled,
    String level = 'high',
  }) async {
    final result = await _moderationService.setModeration(
      groupId: groupId,
      enabled: enabled,
      level: level,
    );

    if (result.success) {
      onSuccess?.call(result.message);
      return true;
    } else {
      onError?.call(result.message);
      return false;
    }
  }

  /// Stream del estado de moderación del grupo
  Stream<GroupModerationState> watchModeration() {
    return _moderationService.watchModeration(groupId);
  }

  /// Limpiar recursos
  void dispose() {
    _groupDataSubscription?.cancel();
    _membersSubscription?.cancel();
  }
}