import 'dart:async';
import 'dart:math' show min;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../models/contact.dart';
import '../services/contacts/cancel_pending_contact_service.dart';
import '../services/contacts/delete_contact_service.dart';
import '../services/contacts/list_contacts_service.dart';
import '../services/contacts/request_contact_approval_service.dart';
import '../services/contacts/resend_contact_request_service.dart';
import '../services/contacts_sync_service.dart';
import '../services/block_service.dart';
import '../services/user_cache_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de contactos de niños
///
/// Arquitectura: Screen → Controller → Service → Model
/// El Controller SOLO expone métodos que el Screen necesita
/// El Controller maneja TODO el filtrado y ordenamiento
///
/// Implementa lazy loading: carga inicial + cargar más al scrollear
class ChildContactsController {
  final String childId;

  // Services atómicos
  final CancelPendingContactService _cancelPendingService;
  final DeleteContactService _deleteContactService;
  final ListContactsService _listContactsService;
  final RequestContactApprovalService _requestApprovalService;
  final ResendContactRequestService _resendRequestService;
  final ContactsSyncService _syncService;
  final BlockService _blockService;
  final UserCacheService _userCache;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;
  String _searchQuery = '';
  List<Contact> _allContacts = []; // Todos los contactos cargados
  List<Contact>? _cachedContacts; // Cache para filtrar sin recrear stream

  // Paginación
  static const int _pageSize = 50;
  DocumentSnapshot? _lastDocument;
  bool _hasMoreContacts = true;
  bool _isLoadingMore = false;

  // Streams
  StreamSubscription? _contactsSubscription;
  final _contactsStreamController = StreamController<List<Contact>>.broadcast();

  ChildContactsController({
    required this.childId,
    CancelPendingContactService? cancelPendingService,
    DeleteContactService? deleteContactService,
    ListContactsService? listContactsService,
    RequestContactApprovalService? requestApprovalService,
    ResendContactRequestService? resendRequestService,
    ContactsSyncService? syncService,
    BlockService? blockService,
    UserCacheService? userCache,
    firebase_auth.FirebaseAuth? auth,
  })  : _cancelPendingService = cancelPendingService ?? CancelPendingContactService(),
        _deleteContactService = deleteContactService ?? DeleteContactService(),
        _listContactsService = listContactsService ?? ListContactsService(),
        _requestApprovalService = requestApprovalService ?? RequestContactApprovalService(),
        _resendRequestService = resendRequestService ?? ResendContactRequestService(),
        _syncService = syncService ?? ContactsSyncService(),
        _blockService = blockService ?? BlockService(),
        _userCache = userCache ?? UserCacheService(),
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;

  /// Indica si hay más contactos por cargar
  bool get hasMoreContacts => _hasMoreContacts;

  /// Indica si está cargando más contactos
  bool get isLoadingMore => _isLoadingMore;

  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════

  Future<void> initialize() async {
    try {
      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado', tag: 'ChildContacts');
        return;
      }

      await _userCache.initialize();
      await _syncService.initialize();
      _startContactsStream();
    } catch (e) {
      ReleaseLogger.error('Error inicializando ChildContactsController: $e', tag: 'ChildContacts');
    }
  }

  void _startContactsStream() {
    final userId = currentUserId;
    if (userId == null) return;

    _contactsSubscription?.cancel();

    // Stream para actualizaciones en tiempo real
    // Los contactos se agregan al cache conforme llegan
    _contactsSubscription = _listContactsService.watchByUser(userId).listen(
      (contacts) {
        _allContacts = contacts;
        _cachedContacts = contacts;
        _contactsStreamController.add(_filterAndSort(contacts, userId));
      },
      onError: (e) {
        ReleaseLogger.error('Error en stream de contactos: $e', tag: 'ChildContacts');
        _contactsStreamController.addError(e);
      },
    );
  }

  /// Cargar más contactos (lazy loading)
  /// Retorna true si se cargaron más, false si no hay más
  Future<bool> loadMoreContacts() async {
    if (_isLoadingMore || !_hasMoreContacts) return false;

    final userId = currentUserId;
    if (userId == null) return false;

    _isLoadingMore = true;

    try {
      final newContacts = await _listContactsService.getPage(
        userId,
        limit: _pageSize,
        startAfter: _lastDocument,
      );

      if (newContacts.isEmpty) {
        _hasMoreContacts = false;
        _isLoadingMore = false;
        return false;
      }

      // Obtener el último documento para la siguiente página
      final lastContact = newContacts.last;
      _lastDocument = await _getDocumentSnapshot(lastContact.id);

      // Agregar nuevos contactos (evitar duplicados)
      final existingIds = _allContacts.map((c) => c.id).toSet();
      final uniqueNewContacts = newContacts.where((c) => !existingIds.contains(c.id));
      _allContacts.addAll(uniqueNewContacts);
      _cachedContacts = _allContacts;

      // Emitir lista actualizada
      _contactsStreamController.add(_filterAndSort(_allContacts, userId));

      _hasMoreContacts = newContacts.length >= _pageSize;
      _isLoadingMore = false;
      return true;
    } catch (e) {
      ReleaseLogger.error('Error cargando más contactos: $e', tag: 'ChildContacts');
      _isLoadingMore = false;
      return false;
    }
  }

  Future<DocumentSnapshot?> _getDocumentSnapshot(String contactId) async {
    try {
      return await FirebaseFirestore.instance
          .collection('contacts')
          .doc(contactId)
          .get();
    } catch (e) {
      return null;
    }
  }

  /// Obtener el nombre a mostrar para un contacto internamente
  /// Usa phone del perfil o del campo phones, y nombre denormalizado como fallback
  String _getDisplayNameForContact(Contact contact, String userId) {
    final otherUserId = contact.getOtherUserId(userId);
    final userData = _userCache.getUserDataSync(otherUserId);
    final phone = userData?['phone'] as String? ?? contact.phones[otherUserId] ?? '';
    final contactName = contact.getOtherUserName(userId);
    return getDisplayName(otherUserId, phoneHint: phone, contactNameHint: contactName);
  }

  List<Contact> _filterAndSort(List<Contact> contacts, String userId) {
    var filtered = contacts.where((c) {
      // Permitir siempre links padre-hijo (no requieren estar en agenda)
      final isParentChild = c.isParentChildLink;

      // Solo contactos reales (excepto parent-child links)
      if (!c.isRealContact && !isParentChild) return false;

      // Excluir bloqueados (ahora está en el modelo Contact)
      if (c.blocked) return false;

      // IMPORTANTE: Solo mostrar contactos donde yo tengo al otro en mi agenda
      // Si discoveredBy está seteado y NO soy yo, significa que el otro me descubrió
      // pero yo NO lo tengo en mi agenda, entonces no debo verlo
      // Esto aplica a TODOS los estados (potential, pending, approved, etc.)
      // EXCEPCIÓN: Los links padre-hijo siempre se muestran
      if (!isParentChild && c.discoveredBy != null && c.discoveredBy != userId) {
        return false;
      }

      // Filtrar por búsqueda
      if (_searchQuery.isNotEmpty) {
        final name = _getDisplayNameForContact(c, userId).toLowerCase();
        if (!name.contains(_searchQuery)) return false;
      }

      return true;
    }).toList();

    // Ordenar alfabéticamente
    filtered.sort((a, b) {
      final nameA = _getDisplayNameForContact(a, userId);
      final nameB = _getDisplayNameForContact(b, userId);
      return nameA.toLowerCase().compareTo(nameB.toLowerCase());
    });

    return filtered;
  }

  // ═══════════════════════════════════════════════════════════════
  // STREAMS (lo que el Screen necesita)
  // ═══════════════════════════════════════════════════════════════

  /// Stream de contactos filtrados y ordenados
  Stream<List<Contact>> getContactsStream() => _contactsStreamController.stream;

  // ═══════════════════════════════════════════════════════════════
  // SEARCH
  // ═══════════════════════════════════════════════════════════════

  /// Actualizar query de búsqueda
  void setSearchQuery(String query) {
    _searchQuery = query.toLowerCase();
    // Re-filtrar desde cache (sin recrear stream de Firestore)
    _refilterFromCache();
  }

  /// Re-filtra contactos desde cache sin recrear subscription
  void _refilterFromCache() {
    final userId = currentUserId;
    if (userId == null || _cachedContacts == null) return;

    _contactsStreamController.add(_filterAndSort(_cachedContacts!, userId));
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
      ReleaseLogger.error('Error sincronizando contactos: $e', tag: 'ChildContacts');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ACTIONS (delegan a Services atómicos)
  // ═══════════════════════════════════════════════════════════════

  /// Solicitar aprobación de un contacto potential
  Future<({bool success, String message})> requestApproval(String contactDocId) async {
    final result = await _requestApprovalService.call(contactDocId);
    return (success: result.success, message: result.message);
  }

  /// Cancelar un contacto pendiente
  Future<bool> cancelPending(String contactId) async {
    return await _cancelPendingService.call(contactId);
  }

  /// Reenviar solicitud de contacto
  Future<({bool success, String message})> resendRequest(String otherUserId) async {
    return await _resendRequestService.call(otherUserId);
  }

  /// Eliminar un contacto rechazado
  Future<bool> deleteRejected(String contactId) async {
    return await _deleteContactService.call(contactId);
  }

  /// Bloquear un contacto
  Future<void> blockContact(String contactId) async {
    await _blockService.blockContact(contactId);
  }

  /// Desbloquear un contacto
  Future<void> unblockContact(String contactId) async {
    await _blockService.unblockContact(contactId);
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS (datos para el Screen)
  // ═══════════════════════════════════════════════════════════════

  /// Obtener nombre a mostrar para un contacto
  /// Prioridad: agenda del SO > alias > nombre Firestore > nombre contacto > fallback
  ///
  /// @param userId: ID del otro usuario
  /// @param phoneHint: Teléfono para buscar en agenda (opcional)
  /// @param contactNameHint: Nombre denormalizado del contacto (opcional)
  String getDisplayName(String userId, {String? phoneHint, String? contactNameHint}) {
    // Usar el nombre del contacto como fallback si está disponible
    final fallback = (contactNameHint != null && contactNameHint.isNotEmpty)
        ? contactNameHint
        : 'Usuario';

    return _userCache.getDisplayName(userId, fallback: fallback, phoneHint: phoneHint);
  }

  /// Obtener nombre de la DB y alias por separado
  /// Retorna: (dbName: nombre denormalizado del contacto, alias: nombre del cache si es diferente)
  ({String dbName, String? alias}) getNameParts(
    String userId, {
    String? phoneHint,
    String? contactNameHint,
  }) {
    // Nombre de la DB (denormalizado del contacto)
    final dbName = (contactNameHint != null && contactNameHint.isNotEmpty)
        ? contactNameHint
        : 'Usuario';

    // Nombre del cache (puede incluir alias de agenda o personalizado)
    final cachedName = _userCache.getDisplayName(userId, fallback: dbName, phoneHint: phoneHint);

    // El alias es diferente del dbName solo si hay un nombre personalizado
    final alias = cachedName != dbName ? cachedName : null;

    return (dbName: dbName, alias: alias);
  }

  /// Obtener datos de usuario (para foto, etc)
  Map<String, dynamic>? getUserData(String odId) {
    return _userCache.getUserDataSync(odId);
  }

  /// Intentar resolver y guardar el nombre de la agenda para un contacto
  /// Llamar esto cuando se detecta que el nombre es "Usuario"
  Future<String?> resolveAndCacheLocalName(String userId, String? phoneNumber) async {
    if (phoneNumber == null || phoneNumber.isEmpty) return null;

    // Ya tiene localName guardado?
    final existingLocalName = _userCache.getLocalName(userId);
    if (existingLocalName != null && existingLocalName.isNotEmpty) {
      return existingLocalName;
    }

    // Resolver desde la agenda del dispositivo
    final localName = await _syncService.resolveDeviceName(phoneNumber);
    if (localName != null && localName.isNotEmpty) {
      await _userCache.setLocalName(userId, localName);
      return localName;
    }

    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  // BATCH UPDATE (para actualizar fotos de contactos visibles)
  // ═══════════════════════════════════════════════════════════════

  /// Actualizar datos de usuarios visibles en batch
  /// Divide en batches de 30 (límite de whereIn de Firestore)
  Future<void> batchUpdateVisibleUsers(Set<String> userIds) async {
    if (userIds.isEmpty) return;

    final toUpdate = userIds.where((id) => id.isNotEmpty).toList();
    if (toUpdate.isEmpty) return;

    // Dividir en batches de 30
    const batchSize = 30;
    for (var i = 0; i < toUpdate.length; i += batchSize) {
      final batch = toUpdate.sublist(i, min(i + batchSize, toUpdate.length));
      await _userCache.batchRefreshUsers(batch);
    }

    // ✅ NO llamar a _refilterFromCache() aquí para evitar ciclo infinito:
    // rebuild → trackVisibleContact → timer 2s → batchUpdate → refilter → rebuild...
    // Los widgets que necesitan los datos actualizados (fotos) usan SyncedUserAvatar
    // que se actualiza automáticamente via ContactPhotoCacheService
  }

  // ═══════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════

  void dispose() {
    _contactsSubscription?.cancel();
    _contactsStreamController.close();
  }
}
