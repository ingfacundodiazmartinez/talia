import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/chat_permission_service.dart';
import '../services/block_service.dart';
import '../utils/release_logger.dart';
import '../utils/chat_utils.dart';

/// Controller para la pantalla de contactos de niños
///
/// Responsabilidades:
/// - Gestionar streams de solicitudes de contacto pendientes
/// - Obtener contactos aprobados bidirecccionalmente
/// - Manejar datos de usuarios y estados en línea
/// - Proporcionar información para navegación a chats
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ChildContactsController {
  final String childId;

  // Servicios privados
  final ChatPermissionService _permissionService;
  final BlockService _blockService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  bool _isInitialized = false;
  String? _currentUserId;

  /// Constructor
  ChildContactsController({
    required this.childId,
    ChatPermissionService? permissionService,
    BlockService? blockService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _permissionService = permissionService ?? ChatPermissionService(),
       _blockService = blockService ?? BlockService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para información del usuario actual
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  bool get isInitialized => _isInitialized;

  /// Inicializar el controller
  Future<void> initialize() async {
    try {
      ReleaseLogger.log('Inicializando ChildContactsController para: $childId', tag: 'ChildContacts');

      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado', tag: 'ChildContacts');
        return;
      }

      _isInitialized = true;
      ReleaseLogger.log('ChildContactsController inicializado exitosamente', tag: 'ChildContacts');
    } catch (e) {
      ReleaseLogger.error('Error inicializando ChildContactsController: $e', tag: 'ChildContacts');
    }
  }

  /// Stream de contactos bloqueados
  Stream<List<String>> getBlockedContactsStream() {
    try {
      return _blockService.getBlockedContactsStream();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de contactos bloqueados: $e', tag: 'ChildContacts');
      return Stream.value([]);
    }
  }

  /// Stream de solicitudes donde YO soy el hijo (mis padres deben aprobar)
  Stream<QuerySnapshot> getMyContactRequestsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener mis solicitudes', tag: 'ChildContacts');
      return Stream.value(const []).cast<QuerySnapshot>();
    }

    try {
      return _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: userId)
          .where('status', isEqualTo: 'pending')
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de mis solicitudes: $e', tag: 'ChildContacts');
      return Stream.value(const []).cast<QuerySnapshot>();
    }
  }

  /// Stream de solicitudes donde YO soy el contacto (padres del otro deben aprobar)
  Stream<QuerySnapshot> getOtherContactRequestsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener otras solicitudes', tag: 'ChildContacts');
      return Stream.value(const []).cast<QuerySnapshot>();
    }

    try {
      return _firestore
          .collection('contact_requests')
          .where('contactId', isEqualTo: userId)
          .where('status', isEqualTo: 'pending')
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de otras solicitudes: $e', tag: 'ChildContacts');
      return Stream.value(const []).cast<QuerySnapshot>();
    }
  }

  /// Stream de contactos aprobados bidirecccionalmente
  Stream<List<String>> getBidirectionallyApprovedContactsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para contactos aprobados', tag: 'ChildContacts');
      return Stream.value([]);
    }

    try {
      return _permissionService.watchBidirectionallyApprovedContacts(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de contactos aprobados: $e', tag: 'ChildContacts');
      return Stream.value([]);
    }
  }

  /// Obtener datos de un usuario específico
  Future<Map<String, dynamic>?> getUserData(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (!doc.exists) {
        ReleaseLogger.warning('Usuario $userId no existe', tag: 'ChildContacts');
        return null;
      }
      return doc.data();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de usuario $userId: $e', tag: 'ChildContacts');
      return null;
    }
  }

  /// Obtener datos de múltiples usuarios en paralelo
  Future<List<Map<String, dynamic>?>> getMultipleUsersData(List<String> userIds) async {
    try {
      if (userIds.isEmpty) return [];

      final futures = userIds.map((id) => getUserData(id));
      return await Future.wait(futures);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos de múltiples usuarios: $e', tag: 'ChildContacts');
      return userIds.map((e) => null).toList();
    }
  }

  /// Obtener datos de un usuario para FutureBuilder (compatible con widgets existentes)
  Future<DocumentSnapshot> getUserDocument(String userId) async {
    try {
      return await _firestore.collection('users').doc(userId).get();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo documento de usuario $userId: $e', tag: 'ChildContacts');
      rethrow;
    }
  }

  /// Obtener documentos de múltiples usuarios en paralelo
  Future<List<DocumentSnapshot>> getMultipleUserDocuments(List<String> userIds) async {
    try {
      if (userIds.isEmpty) return [];

      final futures = userIds.map((id) => getUserDocument(id));
      return await Future.wait(futures);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo documentos de múltiples usuarios: $e', tag: 'ChildContacts');
      rethrow;
    }
  }

  /// Generar chat ID entre dos usuarios
  String getChatId(String user1, String user2) {
    return ChatUtils.getChatId(user1, user2);
  }

  /// Generar chat ID para el usuario actual y un contacto
  String getChatIdWithContact(String contactId) {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para generar chat ID', tag: 'ChildContacts');
      return '';
    }
    return getChatId(userId, contactId);
  }

  /// Determinar el "otro usuario" en una solicitud de contacto
  String getOtherUserId(Map<String, dynamic> requestData) {
    final userId = currentUserId;
    if (userId == null) return '';

    final childId = requestData['childId'] as String;
    final contactId = requestData['contactId'] as String;

    return (childId == userId) ? contactId : childId;
  }

  /// Obtener nombre del "otro usuario" en una solicitud
  String getOtherUserName(Map<String, dynamic> requestData) {
    final userId = currentUserId;
    if (userId == null) return 'Usuario';

    final childId = requestData['childId'] as String;

    return (childId == userId)
        ? (requestData['contactName'] ?? 'Usuario')
        : (requestData['childName'] ?? 'Usuario');
  }

  /// Filtrar contactos por búsqueda
  bool matchesSearch(String name, String searchQuery) {
    if (searchQuery.isEmpty) return true;
    return name.toLowerCase().contains(searchQuery.toLowerCase());
  }

  /// Verificar si un contacto está bloqueado
  bool isContactBlocked(String contactId, List<String> blockedContacts) {
    return blockedContacts.contains(contactId);
  }

  /// Agrupar solicitudes pendientes por usuario
  Map<String, List<QueryDocumentSnapshot>> groupPendingRequestsByUser(
    List<QueryDocumentSnapshot> docs,
  ) {
    final userId = currentUserId;
    if (userId == null) return {};

    final Map<String, List<QueryDocumentSnapshot>> groupedRequests = {};

    try {
      for (var doc in docs) {
        final data = doc.data() as Map<String, dynamic>;
        final otherUserId = getOtherUserId(data);

        if (otherUserId.isNotEmpty) {
          if (!groupedRequests.containsKey(otherUserId)) {
            groupedRequests[otherUserId] = [];
          }
          groupedRequests[otherUserId]!.add(doc);
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error agrupando solicitudes pendientes: $e', tag: 'ChildContacts');
    }

    return groupedRequests;
  }

  /// Separar solicitudes en "mis padres" vs "padres del otro"
  Map<String, List<Map<String, dynamic>>> categorizeRequests(
    List<QueryDocumentSnapshot> requests,
  ) {
    final userId = currentUserId;
    if (userId == null) {
      return {'myParentRequests': [], 'otherParentRequests': []};
    }

    final myParentRequests = <Map<String, dynamic>>[];
    final otherParentRequests = <Map<String, dynamic>>[];

    try {
      for (var request in requests) {
        final data = request.data() as Map<String, dynamic>;
        final requestChildId = data['childId'] as String;

        if (requestChildId == userId) {
          myParentRequests.add(data);
        } else {
          otherParentRequests.add(data);
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error categorizando solicitudes: $e', tag: 'ChildContacts');
    }

    return {
      'myParentRequests': myParentRequests,
      'otherParentRequests': otherParentRequests,
    };
  }

  /// Crear mapa de nombres de padres por ID
  Map<String, String> createParentNamesMap(
    List<String> parentIds,
    List<DocumentSnapshot> parentDocs,
  ) {
    final parentNamesMap = <String, String>{};

    try {
      for (var i = 0; i < parentIds.length && i < parentDocs.length; i++) {
        final doc = parentDocs[i];
        final name = (doc.data() as Map<String, dynamic>?)?['name'] ?? 'Padre/Madre';
        parentNamesMap[parentIds[i]] = name;
      }
    } catch (e) {
      ReleaseLogger.error('Error creando mapa de nombres de padres: $e', tag: 'ChildContacts');
    }

    return parentNamesMap;
  }

  /// Validar que el usuario actual esté autenticado
  bool get isUserAuthenticated => currentUserId != null;

  /// Validar datos de solicitud de contacto
  bool isValidContactRequest(Map<String, dynamic> data) {
    try {
      return data.containsKey('childId') &&
             data.containsKey('contactId') &&
             data.containsKey('parentId');
    } catch (e) {
      ReleaseLogger.error('Error validando solicitud de contacto: $e', tag: 'ChildContacts');
      return false;
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChildContactsController', tag: 'ChildContacts');
    _isInitialized = false;
  }
}