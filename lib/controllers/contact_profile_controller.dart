import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:intl/intl.dart';
import '../services/block_service.dart';
import '../services/contact_alias_service.dart';
import '../services/favorite_service.dart';
import '../calls_v2/controllers/call_controller.dart' as calls_v2;
import '../models/child.dart';
import '../models/contact_user.dart';

/// Controller para manejar la lógica del perfil de contacto
///
/// Responsabilidades:
/// - Gestión de información del contacto
/// - Operaciones de bloqueo/desbloqueo
/// - Gestión de alias y favoritos
/// - Coordinación de llamadas de video/audio
/// - Acceso a datos del usuario y perfil
class ContactProfileController {
  final String contactId;
  final String contactName;
  final String chatId;

  // Servicios privados
  final BlockService _blockService;
  final ContactAliasService _aliasService;
  final FavoriteService _favoriteService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado del controlador
  bool _isBlocked = false;
  bool _isLoadingBlockStatus = true;
  bool _isFavorite = false;
  bool _isLoadingFavoriteStatus = true;
  String? _contactAlias;
  ContactUser? _contactUser;
  List<Map<String, dynamic>> _favoriteMessages = [];
  List<Map<String, dynamic>> _childParents = [];
  bool _isLoadingFavorites = true;
  bool _hasError = false;

  // Subscripciones
  StreamSubscription? _contactDataSubscription;
  StreamSubscription? _blockStatusSubscription;

  // Callbacks para comunicación con el screen
  Function(bool)? onBlockStatusChanged;
  Function(bool)? onFavoriteStatusChanged;
  Function(String?)? onAliasChanged;
  Function(ContactUser?)? onContactDataChanged;
  Function(String)? onError;
  Function(String)? onSuccess;

  // Constructor
  ContactProfileController({
    required this.contactId,
    required this.contactName,
    required this.chatId,
    BlockService? blockService,
    ContactAliasService? aliasService,
    FavoriteService? favoriteService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _blockService = blockService ?? BlockService(),
       _aliasService = aliasService ?? ContactAliasService(),
       _favoriteService = favoriteService ?? FavoriteService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para el estado
  bool get isBlocked => _isBlocked;
  bool get isLoadingBlockStatus => _isLoadingBlockStatus;
  bool get isFavorite => _isFavorite;
  bool get isLoadingFavoriteStatus => _isLoadingFavoriteStatus;
  String? get contactAlias => _contactAlias;
  ContactUser? get contactUser => _contactUser;
  List<Map<String, dynamic>> get favoriteMessages => _favoriteMessages;
  List<Map<String, dynamic>> get childParents => _childParents;
  bool get isLoadingFavorites => _isLoadingFavorites;
  bool get hasError => _hasError;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Inicializar el controller
  Future<void> initialize() async {
    // Cargar estados iniciales en paralelo
    await Future.wait([
      _loadBlockStatus(),
      _loadFavoriteStatus(),
      _loadContactAlias(),
      _loadContactData(),
    ]);

    // Cargar datos adicionales después de cargar los datos del contacto
    await Future.wait([loadFavoriteMessages(), loadChildParents()]);

    // Configurar listeners para actualizaciones en tiempo real
    _setupContactDataListener();
  }

  /// Cargar estado de bloqueo
  Future<void> _loadBlockStatus() async {
    try {
      _isBlocked = await _blockService.isBlocked(contactId);
      _isLoadingBlockStatus = false;
      onBlockStatusChanged?.call(_isBlocked);
    } catch (e) {
      _isLoadingBlockStatus = false;
      onError?.call('Error verificando estado de bloqueo');
    }
  }

  /// Cargar estado de favorito
  Future<void> _loadFavoriteStatus() async {
    try {
      // Note: We'll load favorite status later when we have message context
      _isFavorite = false; // Initialize as false for now
      _isLoadingFavoriteStatus = false;
      onFavoriteStatusChanged?.call(_isFavorite);
    } catch (e) {
      _isLoadingFavoriteStatus = false;
      onError?.call('Error verificando favoritos');
    }
  }

  /// Cargar alias del contacto
  Future<void> _loadContactAlias() async {
    try {
      final displayName = await _aliasService.getDisplayName(
        contactId,
        contactName,
      );
      _contactAlias = displayName != contactName ? displayName : null;
      onAliasChanged?.call(_contactAlias);
    } catch (e) {
      onError?.call('Error cargando alias del contacto');
    }
  }

  /// Cargar datos del contacto
  Future<void> _loadContactData() async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(contactId)
          .get();
      if (snapshot.exists) {
        final data = snapshot.data()!;
        _contactUser = ContactUser.fromFirestore(data, contactId, customAlias: _contactAlias);
        onContactDataChanged?.call(_contactUser);
      }
    } catch (e) {
      onError?.call('Error cargando información del contacto');
    }
  }

  /// Configurar listener para cambios en datos del contacto
  void _setupContactDataListener() {
    _contactDataSubscription = _firestore
        .collection('users')
        .doc(contactId)
        .snapshots()
        .listen(
          (snapshot) {
            if (snapshot.exists) {
              final data = snapshot.data()!;
              _contactUser = ContactUser.fromFirestore(data, contactId, customAlias: _contactAlias);
              onContactDataChanged?.call(_contactUser);
            }
          },
          onError: (error) {
            onError?.call('Error actualizando información del contacto');
          },
        );
  }

  /// Alternar estado de bloqueo
  Future<bool> toggleBlock() async {
    try {
      if (_isBlocked) {
        // Desbloquear
        await _blockService.unblockContact(contactId);
        _isBlocked = false;
        onBlockStatusChanged?.call(false);
        onSuccess?.call('Contacto desbloqueado exitosamente');
        return true;
      } else {
        // Bloquear
        await _blockService.blockContact(contactId);
        _isBlocked = true;
        onBlockStatusChanged?.call(true);
        onSuccess?.call('Contacto bloqueado exitosamente');
        return true;
      }
    } catch (e) {
      onError?.call(
        'Error ${_isBlocked ? 'desbloqueando' : 'bloqueando'} contacto',
      );
      return false;
    }
  }

  /// Alternar estado de favorito para un mensaje específico
  Future<bool> toggleMessageFavorite(String messageId) async {
    try {
      await _favoriteService.toggleFavorite(
        chatId: chatId,
        messageId: messageId,
        isGroupChat: false,
      );
      onSuccess?.call('Estado de favorito actualizado');
      return true;
    } catch (e) {
      onError?.call('Error actualizando favorito');
      return false;
    }
  }

  /// Actualizar alias del contacto
  Future<bool> updateContactAlias(String? newAlias) async {
    try {
      if (newAlias == null) {
        await _aliasService.removeAlias(contactId);
      } else {
        await _aliasService.setAlias(contactId, newAlias);
      }
      _contactAlias = newAlias;
      onAliasChanged?.call(newAlias);
      onSuccess?.call('Alias actualizado exitosamente');
      return true;
    } catch (e) {
      onError?.call('Error actualizando alias');
      return false;
    }
  }

  /// Iniciar videollamada
  Future<bool> startVideoCall() async {
    try {
      if (_isBlocked) {
        onError?.call('No puedes llamar a un contacto bloqueado');
        return false;
      }

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        onError?.call('Usuario no autenticado');
        return false;
      }

      final callController = calls_v2.CallController();
      final result = await callController.createCall(
        participantIds: [contactId],
        isVideo: true,
        isGroup: false,
      );

      if (result.success) {
        onSuccess?.call('Videollamada iniciada');
        return true;
      } else {
        onError?.call(result.error ?? 'Error iniciando videollamada');
        return false;
      }
    } catch (e) {
      onError?.call('Error iniciando videollamada');
      return false;
    }
  }

  /// Iniciar llamada de audio
  Future<bool> startAudioCall() async {
    try {
      if (_isBlocked) {
        onError?.call('No puedes llamar a un contacto bloqueado');
        return false;
      }

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        onError?.call('Usuario no autenticado');
        return false;
      }

      final callController = calls_v2.CallController();
      final result = await callController.createCall(
        participantIds: [contactId],
        isVideo: false,
        isGroup: false,
      );

      if (result.success) {
        onSuccess?.call('Llamada de audio iniciada');
        return true;
      } else {
        onError?.call(result.error ?? 'Error iniciando llamada de audio');
        return false;
      }
    } catch (e) {
      onError?.call('Error iniciando llamada de audio');
      return false;
    }
  }

  /// Verificar si el contacto es un niño
  bool isContactChild() {
    return _contactUser?.isChild ?? false;
  }

  /// Obtener información del contacto como Child (si aplicable)
  Future<Child?> getContactAsChild() async {
    try {
      if (_contactUser == null) {
        await _loadContactData();
      }

      if (isContactChild()) {
        // Convert ContactUser back to Map for Child.fromMap
        final contactData = {
          'name': _contactUser!.name,
          'role': _contactUser!.role,
          'birthDate': _contactUser!.birthDate,
          'photoURL': _contactUser!.photoURL,
          'phone': _contactUser!.phone,
          'email': _contactUser!.email,
          'createdAt': _contactUser!.createdAt,
          'lastSeen': _contactUser!.lastSeen,
        };
        return Child.fromMap(contactId, contactData);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Obtener edad del contacto
  int? getContactAge() {
    return _contactUser?.age;
  }

  /// Obtener nombre para mostrar (alias o nombre real)
  String getDisplayName() {
    return _contactUser?.getDisplayName(customAlias: _contactAlias) ?? contactName;
  }

  /// Obtener foto de perfil URL
  String? getPhotoURL() {
    return _contactUser?.photoURL;
  }

  /// Obtener teléfono del contacto
  String? getPhoneNumber() {
    return _contactUser?.phone;
  }

  /// Obtener email del contacto
  String? getEmail() {
    return _contactUser?.email;
  }

  /// Obtener fecha de registro
  DateTime? getJoinDate() {
    return _contactUser?.joinDate;
  }

  /// Verificar si el contacto está online
  bool isContactOnline() {
    return _contactUser?.isOnline ?? false;
  }

  /// Obtener última vez visto
  DateTime? getLastSeen() {
    return _contactUser?.lastSeen;
  }

  /// Stream de datos del contacto para actualizaciones en tiempo real
  Stream<DocumentSnapshot> getContactDataStream() {
    return _firestore.collection('users').doc(contactId).snapshots();
  }

  /// Stream de mensajes del chat para la galería de medios
  Stream<QuerySnapshot> getChatMediaStream() {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .where('type', whereIn: ['image', 'video'])
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots();
  }

  /// Métodos para alias
  Future<void> setContactAlias(String alias) async {
    await updateContactAlias(alias);
  }

  Future<void> removeContactAlias() async {
    await updateContactAlias(null);
  }

  /// Métodos para bloquear/desbloquear individualmente
  Future<void> blockContact() async {
    await toggleBlock();
  }

  Future<void> unblockContact() async {
    await toggleBlock();
  }

  /// Cargar mensajes favoritos
  Future<void> loadFavoriteMessages() async {
    try {
      _isLoadingFavorites = true;
      _hasError = false;

      final stream = _favoriteService.getFavoriteMessagesStream(
        chatId: chatId,
        isGroupChat: false,
      );

      final snapshot = await stream.first;

      // Convertir Timestamp a String para que la pantalla no dependa de Firestore
      _favoriteMessages = snapshot.map((message) {
        final Map<String, dynamic> processedMessage = Map.from(message);

        // Convertir Timestamp a String formateado
        if (processedMessage['timestamp'] is Timestamp) {
          final timestamp = processedMessage['timestamp'] as Timestamp;
          processedMessage['formattedTime'] = DateFormat(
            'dd/MM/yyyy HH:mm',
          ).format(timestamp.toDate());
          processedMessage.remove('timestamp'); // Remover el Timestamp original
        }

        return processedMessage;
      }).toList();

      _isLoadingFavorites = false;
    } catch (e) {
      _hasError = true;
      _isLoadingFavorites = false;
      onError?.call('Error cargando mensajes favoritos');
    }
  }

  /// Recargar favoritos
  Future<void> reloadFavorites() async {
    await loadFavoriteMessages();
  }

  /// Cargar padres del niño si aplica
  Future<void> loadChildParents() async {
    try {
      if (isContactChild()) {
        final child = Child(id: contactId, name: contactName);
        _childParents = await child.getParents();
      } else {
        _childParents = [];
      }
    } catch (e) {
      _childParents = [];
      onError?.call('Error cargando información de padres');
    }
  }

  /// Limpiar recursos
  void dispose() {
    _contactDataSubscription?.cancel();
    _blockStatusSubscription?.cancel();
  }
}
