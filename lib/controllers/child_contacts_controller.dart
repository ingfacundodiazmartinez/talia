import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../models/contact.dart';
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

  /// Stream de contactos donde MI aprobación está pendiente (mis padres deben aprobar)
  /// Usa colección `contacts` con filtro client-side por approvals[userId].status
  Stream<List<Contact>> getMyPendingContactsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener mis solicitudes', tag: 'ChildContacts');
      return Stream.value([]);
    }

    try {
      return Contact.watchPendingForChild(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de mis solicitudes: $e', tag: 'ChildContacts');
      return Stream.value([]);
    }
  }

  /// Stream de contactos donde el OTRO usuario tiene aprobación pendiente (sus padres deben aprobar)
  Stream<List<Contact>> getOtherPendingContactsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener otras solicitudes', tag: 'ChildContacts');
      return Stream.value([]);
    }

    try {
      return Contact.watchOtherPendingForChild(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de otras solicitudes: $e', tag: 'ChildContacts');
      return Stream.value([]);
    }
  }

  /// Stream de contactos RECHAZADOS donde yo soy el child (mis padres rechazaron)
  Stream<List<Contact>> getRejectedContactsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener solicitudes rechazadas', tag: 'ChildContacts');
      return Stream.value([]);
    }

    try {
      return Contact.watchRejectedForChild(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de solicitudes rechazadas: $e', tag: 'ChildContacts');
      return Stream.value([]);
    }
  }

  /// Stream de contactos SUGERIDOS (potential) - descubiertos en sync pero no solicitados aún
  /// Estos contactos aparecen en sección "Sugeridos" y pueden solicitarse aprobación
  Stream<List<Contact>> getPotentialContactsStream() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.error('Usuario no autenticado para obtener contactos sugeridos', tag: 'ChildContacts');
      return Stream.value([]);
    }

    try {
      return Contact.watchPotentialForUser(userId);
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream de contactos sugeridos: $e', tag: 'ChildContacts');
      return Stream.value([]);
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

  /// Determinar el "otro usuario" en un contacto
  String getOtherUserIdFromContact(Contact contact) {
    final userId = currentUserId;
    if (userId == null) return '';
    return contact.getOtherUserId(userId);
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

  /// Agrupar contactos pendientes por otro usuario
  Map<String, List<Contact>> groupPendingContactsByUser(List<Contact> contacts) {
    final userId = currentUserId;
    if (userId == null) return {};

    final Map<String, List<Contact>> groupedContacts = {};

    try {
      for (var contact in contacts) {
        final otherUserId = contact.getOtherUserId(userId);

        if (otherUserId.isNotEmpty) {
          groupedContacts.putIfAbsent(otherUserId, () => []);
          groupedContacts[otherUserId]!.add(contact);
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error agrupando contactos pendientes: $e', tag: 'ChildContacts');
    }

    return groupedContacts;
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

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChildContactsController', tag: 'ChildContacts');
    _isInitialized = false;
  }
}