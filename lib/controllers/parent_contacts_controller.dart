import 'dart:async';
import 'dart:math' show min;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../models/contact.dart';
import '../models/parent.dart';
import '../services/contacts/list_contacts_service.dart';
import '../services/contacts_sync_service.dart';
import '../services/block_service.dart';
import '../services/friend_service.dart';
import '../services/user_cache_service.dart';
import '../services/user_role_service.dart';
import '../utils/release_logger.dart';

/// Datos de un contacto procesado para mostrar en la UI
class ProcessedContact {
  final Contact contact;
  final String oderId;
  /// Nombre de la DB (denormalizado del contacto) - usado para ordenar
  final String dbName;
  /// Alias personalizado del usuario (del cache) - puede ser igual a dbName
  final String? alias;
  final String? photoURL;
  final String? phone;
  final int? age;
  final bool isChild;
  final bool isOnline;
  /// Si son amigos (pueden ver historias mutuamente)
  final bool isFriend;
  /// Estado de amistad: none, pending_sent, pending_received, accepted, rejected
  final String friendStatus;

  ProcessedContact({
    required this.contact,
    required this.oderId,
    required this.dbName,
    this.alias,
    this.photoURL,
    this.phone,
    this.age,
    this.isChild = false,
    this.isOnline = false,
    this.isFriend = false,
    this.friendStatus = 'none',
  });

  /// Nombre para mostrar: alias si existe y es diferente, sino dbName
  String get displayName => alias ?? dbName;
}

/// Controller para la pantalla de contactos de padres
///
/// Arquitectura: Screen → Controller → Service → Model
/// El Controller maneja TODO el filtrado y ordenamiento
///
/// Carga todos los contactos de una vez para ordenar alfabéticamente,
/// luego actualiza datos frescos (fotos, status) de forma lazy para items visibles.
class ParentContactsController {
  final String parentId;

  // Services
  final ListContactsService _listContactsService;
  final ContactsSyncService _syncService;
  final BlockService _blockService;
  final FriendService _friendService;
  final UserCacheService _userCache;
  final UserRoleService _userRoleService;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;
  String _searchQuery = '';
  List<Contact> _allContacts = [];
  Set<String> _linkedChildrenIds = {};
  Set<String> _blockedIds = {};

  // Cache para evitar spinner al volver a la pantalla
  List<ProcessedContact> _cachedContacts = [];
  List<ProcessedContact> _cachedChildren = [];
  List<ProcessedContact> _cachedOthers = [];
  List<ProcessedContact> _cachedFriends = [];
  List<Contact> _cachedPendingRequests = [];

  // Streams
  StreamSubscription? _contactsSubscription;
  StreamSubscription? _linkedChildrenSubscription;
  StreamSubscription? _blockedSubscription;
  StreamSubscription? _pendingRequestsSubscription;
  final _contactsStreamController = StreamController<List<ProcessedContact>>.broadcast();
  final _pendingRequestsStreamController = StreamController<List<Contact>>.broadcast();

  ParentContactsController({
    required this.parentId,
    ListContactsService? listContactsService,
    ContactsSyncService? syncService,
    BlockService? blockService,
    FriendService? friendService,
    UserCacheService? userCache,
    UserRoleService? userRoleService,
    firebase_auth.FirebaseAuth? auth,
  })  : _listContactsService = listContactsService ?? ListContactsService(),
        _syncService = syncService ?? ContactsSyncService(),
        _blockService = blockService ?? BlockService(),
        _friendService = friendService ?? FriendService(),
        _userCache = userCache ?? UserCacheService(),
        _userRoleService = userRoleService ?? UserRoleService(),
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;

  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════

  Future<void> initialize() async {
    try {
      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado', tag: 'ParentContacts');
        return;
      }

      await _userCache.initialize();
      await _syncService.initialize();

      _startLinkedChildrenStream();
      _startBlockedStream();
      _startContactsStream();
      _startPendingRequestsStream();
    } catch (e) {
      ReleaseLogger.error('Error inicializando ParentContactsController: $e', tag: 'ParentContacts');
    }
  }

  void _startLinkedChildrenStream() {
    _linkedChildrenSubscription?.cancel();
    _linkedChildrenSubscription = _userRoleService
        .watchLinkedChildren(parentId)
        .listen((children) {
      _linkedChildrenIds = children.toSet();
      _emitProcessedContacts();
    });
  }

  void _startBlockedStream() {
    _blockedSubscription?.cancel();
    _blockedSubscription = _blockService
        .getBlockedContactsStream()
        .listen((blocked) {
      _blockedIds = blocked.toSet();
      _emitProcessedContacts();
    });
  }

  void _startContactsStream() {
    final userId = currentUserId;
    if (userId == null) return;

    _contactsSubscription?.cancel();

    // Stream de TODOS los contactos (sin paginación)
    // Los contactos tienen nombres denormalizados para ordenar
    _contactsSubscription = _listContactsService.watchByUser(userId).listen(
      (contacts) {
        _allContacts = contacts;
        _emitProcessedContacts();
      },
      onError: (e) {
        ReleaseLogger.error('Error en stream de contactos: $e', tag: 'ParentContacts');
        _contactsStreamController.addError(e);
      },
    );
  }

  void _startPendingRequestsStream() {
    _pendingRequestsSubscription?.cancel();

    // Emitir lista vacía inicialmente para evitar spinner eterno
    _pendingRequestsStreamController.add([]);

    _pendingRequestsSubscription = _friendService.watchMyPendingFriendRequests().listen(
      (requests) {
        _cachedPendingRequests = requests;
        _pendingRequestsStreamController.add(requests);
      },
      onError: (e) {
        ReleaseLogger.error('Error en stream de solicitudes pendientes: $e', tag: 'ParentContacts');
        _cachedPendingRequests = [];
        _pendingRequestsStreamController.add([]);
      },
    );
  }

  void _emitProcessedContacts() {
    final userId = currentUserId;
    if (userId == null) return;

    final processed = _processAndSortContacts(_allContacts, userId);
    _cachedContacts = processed;

    // Pre-computar separaciones para evitar recálculos en getters
    _cachedChildren = processed.where((c) => c.isChild).toList();
    _cachedOthers = processed.where((c) => !c.isChild).toList();
    _cachedFriends = processed.where((c) => c.isFriend).toList();

    _contactsStreamController.add(processed);
  }

  // ═══════════════════════════════════════════════════════════════
  // PROCESSING & SORTING
  // ═══════════════════════════════════════════════════════════════

  List<ProcessedContact> _processAndSortContacts(List<Contact> contacts, String userId) {
    final result = <ProcessedContact>[];

    for (final contact in contacts) {
      // Filtrar contactos no válidos
      if (!_shouldIncludeContact(contact, userId)) continue;

      final otherUserId = contact.getOtherUserId(userId);
      if (otherUserId.isEmpty) continue;

      // Obtener nombre de la DB (denormalizado del contacto) - usado para ordenar
      final dbName = contact.getOtherUserName(userId) ?? 'Usuario';

      // Obtener alias del cache (puede ser null si no hay alias personalizado)
      final cachedName = _userCache.getDisplayName(otherUserId, fallback: dbName);
      final alias = cachedName != dbName ? cachedName : null;

      // Filtrar por búsqueda (busca en ambos nombres)
      if (_searchQuery.isNotEmpty) {
        final matchesDbName = dbName.toLowerCase().contains(_searchQuery);
        final matchesAlias = alias?.toLowerCase().contains(_searchQuery) ?? false;
        if (!matchesDbName && !matchesAlias) continue;
      }

      // Datos del cache (pueden ser null si no están cargados aún)
      final userData = _userCache.getUserDataSync(otherUserId);
      final photoURL = contact.getOtherUserPhotoURL(userId) ?? userData?['photoURL'] as String?;
      final phone = userData?['phone'] as String? ?? contact.phones[otherUserId];
      final isOnline = userData?['isOnline'] as bool? ?? false;

      // Calcular edad
      int? age;
      final birthDate = userData?['birthDate'];
      if (birthDate != null) {
        age = _calculateAge(birthDate);
      }

      // Obtener estado de amistad
      final isFriend = contact.isFriend;
      final friendStatus = contact.getFriendStatusForUser(userId);

      result.add(ProcessedContact(
        contact: contact,
        oderId: otherUserId,
        dbName: dbName,
        alias: alias,
        photoURL: photoURL,
        phone: phone,
        age: age,
        isChild: _linkedChildrenIds.contains(otherUserId),
        isOnline: isOnline,
        isFriend: isFriend,
        friendStatus: friendStatus,
      ));
    }

    // Ordenar alfabéticamente por nombre de DB (no por alias)
    result.sort((a, b) => a.dbName.toLowerCase().compareTo(b.dbName.toLowerCase()));

    return result;
  }

  bool _shouldIncludeContact(Contact contact, String userId) {
    // Solo contactos aprobados o links padre-hijo
    if (contact.status != 'approved' && !contact.isParentChildLink) {
      return false;
    }

    // Excluir bloqueados
    final otherUserId = contact.getOtherUserId(userId);
    if (_blockedIds.contains(otherUserId)) return false;
    if (contact.blocked) return false;

    // Filtrar por discoveredBy
    if (!contact.isParentChildLink &&
        contact.discoveredBy != null &&
        contact.discoveredBy != userId) {
      return false;
    }

    return true;
  }

  int? _calculateAge(dynamic birthDate) {
    DateTime? birthDateTime;
    if (birthDate is DateTime) {
      birthDateTime = birthDate;
    } else if (birthDate is String) {
      birthDateTime = DateTime.tryParse(birthDate);
    }

    if (birthDateTime == null) return null;

    final now = DateTime.now();
    int age = now.year - birthDateTime.year;
    if (now.month < birthDateTime.month ||
        (now.month == birthDateTime.month && now.day < birthDateTime.day)) {
      age--;
    }
    return age;
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAMS
  // ═══════════════════════════════════════════════════════════════

  /// Stream de contactos procesados, filtrados y ordenados
  Stream<List<ProcessedContact>> get contactsStream => _contactsStreamController.stream;

  /// Obtener contactos separados por tipo (children vs others)
  Stream<({List<ProcessedContact> children, List<ProcessedContact> others})> get separatedContactsStream {
    return contactsStream.map((contacts) {
      final children = contacts.where((c) => c.isChild).toList();
      final others = contacts.where((c) => !c.isChild).toList();
      return (children: children, others: others);
    });
  }

  /// Stream de amigos (contactos donde isFriend == true)
  Stream<List<ProcessedContact>> get friendsStream {
    return contactsStream.map((contacts) =>
      contacts.where((c) => c.isFriend).toList()
    );
  }

  /// Contactos cacheados (para initialData de StreamBuilder)
  List<ProcessedContact> get cachedContacts => _cachedContacts;

  /// Amigos cacheados (para initialData de StreamBuilder)
  List<ProcessedContact> get cachedFriends => _cachedFriends;

  /// Contactos separados cacheados (children vs others)
  ({List<ProcessedContact> children, List<ProcessedContact> others}) get cachedSeparatedContacts =>
      (children: _cachedChildren, others: _cachedOthers);

  // ═══════════════════════════════════════════════════════════════
  // SEARCH
  // ═══════════════════════════════════════════════════════════════

  void setSearchQuery(String query) {
    _searchQuery = query.toLowerCase();
    _emitProcessedContacts();
  }

  // ═══════════════════════════════════════════════════════════════
  // SYNC & CONSENT
  // ═══════════════════════════════════════════════════════════════

  /// Verificar si el usuario ha dado consentimiento para sincronizar contactos
  Future<bool> hasConsent() async {
    return await _syncService.hasConsent();
  }

  /// Establecer el consentimiento del usuario
  Future<void> setConsent(bool granted) async {
    await _syncService.setConsent(granted);
  }

  /// Sincronizar contactos del dispositivo
  ///
  /// [skipConsentCheck] - Omitir verificación de consentimiento (usar cuando
  ///                      se acaba de obtener consentimiento en el mismo flujo)
  Future<bool> syncContacts({bool skipConsentCheck = false}) async {
    try {
      await _syncService.syncContacts(force: true, skipConsentCheck: skipConsentCheck);
      return true;
    } catch (e) {
      ReleaseLogger.error('Error sincronizando contactos: $e', tag: 'ParentContacts');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Desvincular un hijo
  Future<bool> unlinkChild(String childId) async {
    return await Parent(id: parentId, name: '').unlinkChild(childId);
  }

  // ═══════════════════════════════════════════════════════════════
  // FRIEND ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Stream de solicitudes de amistad pendientes recibidas
  Stream<List<Contact>> get pendingFriendRequestsStream {
    return _pendingRequestsStreamController.stream;
  }

  /// Solicitudes pendientes cacheadas (para initialData de StreamBuilder)
  List<Contact> get cachedPendingRequests => _cachedPendingRequests;

  /// Enviar solicitud de amistad
  Future<void> sendFriendRequest(String otherUserId) async {
    try {
      await _friendService.sendFriendRequest(otherUserId);
    } catch (e) {
      ReleaseLogger.error('Error enviando solicitud de amistad: $e', tag: 'ParentContacts');
      rethrow;
    }
  }

  /// Aceptar solicitud de amistad
  Future<void> acceptFriendRequest(String otherUserId) async {
    try {
      await _friendService.acceptFriendRequest(otherUserId);
    } catch (e) {
      ReleaseLogger.error('Error aceptando solicitud de amistad: $e', tag: 'ParentContacts');
      rethrow;
    }
  }

  /// Rechazar solicitud de amistad
  Future<void> rejectFriendRequest(String otherUserId) async {
    try {
      await _friendService.rejectFriendRequest(otherUserId);
    } catch (e) {
      ReleaseLogger.error('Error rechazando solicitud de amistad: $e', tag: 'ParentContacts');
      rethrow;
    }
  }

  /// Eliminar amigo (silencioso - el otro usuario no es notificado)
  Future<void> removeFriend(String otherUserId) async {
    try {
      await _friendService.removeFriend(otherUserId);
    } catch (e) {
      ReleaseLogger.error('Error eliminando amigo: $e', tag: 'ParentContacts');
      rethrow;
    }
  }

  /// Obtener estado de amistad con otro usuario
  Future<String> getFriendStatus(String otherUserId) async {
    return await _friendService.getFriendStatus(otherUserId);
  }

  /// Contar solicitudes de amistad pendientes
  Future<int> countPendingFriendRequests() async {
    return await _friendService.countMyPendingFriendRequests();
  }

  // ═══════════════════════════════════════════════════════════════
  // BATCH UPDATE (para actualizar datos de contactos visibles)
  // ═══════════════════════════════════════════════════════════════

  /// Actualizar datos de usuarios visibles en batch
  Future<void> batchUpdateVisibleUsers(Set<String> userIds) async {
    if (userIds.isEmpty) return;

    final toUpdate = userIds.where((id) => id.isNotEmpty).toList();
    if (toUpdate.isEmpty) return;

    // Dividir en batches de 30 (límite de whereIn de Firestore)
    const batchSize = 30;
    for (var i = 0; i < toUpdate.length; i += batchSize) {
      final batch = toUpdate.sublist(i, min(i + batchSize, toUpdate.length));
      await _userCache.batchRefreshUsers(batch);
    }

    // Re-emitir con datos actualizados
    _emitProcessedContacts();
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener datos de usuario del cache
  Map<String, dynamic>? getUserData(String userId) {
    return _userCache.getUserDataSync(userId);
  }

  // ═══════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════

  void dispose() {
    _contactsSubscription?.cancel();
    _linkedChildrenSubscription?.cancel();
    _blockedSubscription?.cancel();
    _pendingRequestsSubscription?.cancel();
    _contactsStreamController.close();
    _pendingRequestsStreamController.close();
  }
}
