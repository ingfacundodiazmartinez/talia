import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/block_service.dart';
import '../services/contact_alias_service.dart';
import '../services/favorite_service.dart';
import '../services/video_call_service.dart';
import '../models/user.dart';
import '../models/child.dart';

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
  final VideoCallService _videoCallService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado del controlador
  bool _isBlocked = false;
  bool _isLoadingBlockStatus = true;
  bool _isFavorite = false;
  bool _isLoadingFavoriteStatus = true;
  String? _contactAlias;
  Map<String, dynamic>? _contactData;
  Map<String, dynamic>? _contactProfile;

  // Subscripciones
  StreamSubscription? _contactDataSubscription;
  StreamSubscription? _blockStatusSubscription;

  // Callbacks para comunicación con el screen
  Function(bool)? onBlockStatusChanged;
  Function(bool)? onFavoriteStatusChanged;
  Function(String?)? onAliasChanged;
  Function(Map<String, dynamic>?)? onContactDataChanged;
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
    VideoCallService? videoCallService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _blockService = blockService ?? BlockService(),
       _aliasService = aliasService ?? ContactAliasService(),
       _favoriteService = favoriteService ?? FavoriteService(),
       _videoCallService = videoCallService ?? VideoCallService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para el estado
  bool get isBlocked => _isBlocked;
  bool get isLoadingBlockStatus => _isLoadingBlockStatus;
  bool get isFavorite => _isFavorite;
  bool get isLoadingFavoriteStatus => _isLoadingFavoriteStatus;
  String? get contactAlias => _contactAlias;
  Map<String, dynamic>? get contactData => _contactData;
  Map<String, dynamic>? get contactProfile => _contactProfile;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Inicializar el controller
  Future<void> initialize() async {
    print('🏗️ [ContactProfileController] Inicializando para contactId: $contactId');

    // Cargar estados iniciales en paralelo
    await Future.wait([
      _loadBlockStatus(),
      _loadFavoriteStatus(),
      _loadContactAlias(),
      _loadContactData(),
    ]);

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
      print('❌ [ContactProfileController] Error cargando estado de bloqueo: $e');
      _isLoadingBlockStatus = false;
      onError?.call('Error verificando estado de bloqueo');
    }
  }

  /// Cargar estado de favorito
  Future<void> _loadFavoriteStatus() async {
    try {
      _isFavorite = await _favoriteService.isFavorite(contactId);
      _isLoadingFavoriteStatus = false;
      onFavoriteStatusChanged?.call(_isFavorite);
    } catch (e) {
      print('❌ [ContactProfileController] Error cargando estado de favorito: $e');
      _isLoadingFavoriteStatus = false;
      onError?.call('Error verificando favoritos');
    }
  }

  /// Cargar alias del contacto
  Future<void> _loadContactAlias() async {
    try {
      _contactAlias = await _aliasService.getContactAlias(contactId);
      onAliasChanged?.call(_contactAlias);
    } catch (e) {
      print('❌ [ContactProfileController] Error cargando alias: $e');
      onError?.call('Error cargando alias del contacto');
    }
  }

  /// Cargar datos del contacto
  Future<void> _loadContactData() async {
    try {
      final snapshot = await _firestore.collection('users').doc(contactId).get();
      if (snapshot.exists) {
        _contactData = snapshot.data();
        _contactProfile = _contactData;
        onContactDataChanged?.call(_contactData);
      }
    } catch (e) {
      print('❌ [ContactProfileController] Error cargando datos del contacto: $e');
      onError?.call('Error cargando información del contacto');
    }
  }

  /// Configurar listener para cambios en datos del contacto
  void _setupContactDataListener() {
    _contactDataSubscription = _firestore
        .collection('users')
        .doc(contactId)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        _contactData = snapshot.data();
        _contactProfile = _contactData;
        onContactDataChanged?.call(_contactData);
      }
    }, onError: (error) {
      print('❌ [ContactProfileController] Error en listener de datos: $error');
      onError?.call('Error actualizando información del contacto');
    });
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
      print('❌ [ContactProfileController] Error cambiando estado de bloqueo: $e');
      onError?.call('Error ${_isBlocked ? 'desbloqueando' : 'bloqueando'} contacto');
      return false;
    }
  }

  /// Alternar estado de favorito
  Future<bool> toggleFavorite() async {
    try {
      if (_isFavorite) {
        // Quitar de favoritos
        await _favoriteService.removeFavorite(contactId);
        _isFavorite = false;
        onFavoriteStatusChanged?.call(false);
        onSuccess?.call('Contacto removido de favoritos');
        return true;
      } else {
        // Agregar a favoritos
        await _favoriteService.addFavorite(contactId);
        _isFavorite = true;
        onFavoriteStatusChanged?.call(true);
        onSuccess?.call('Contacto agregado a favoritos');
        return true;
      }
    } catch (e) {
      print('❌ [ContactProfileController] Error cambiando estado de favorito: $e');
      onError?.call('Error actualizando favoritos');
      return false;
    }
  }

  /// Actualizar alias del contacto
  Future<bool> updateContactAlias(String? newAlias) async {
    try {
      await _aliasService.setContactAlias(contactId, newAlias);
      _contactAlias = newAlias;
      onAliasChanged?.call(newAlias);
      onSuccess?.call('Alias actualizado exitosamente');
      return true;
    } catch (e) {
      print('❌ [ContactProfileController] Error actualizando alias: $e');
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

      await _videoCallService.startCall(
        receiverId: contactId,
        isVideo: true,
      );

      onSuccess?.call('Videollamada iniciada');
      return true;
    } catch (e) {
      print('❌ [ContactProfileController] Error iniciando videollamada: $e');
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

      await _videoCallService.startCall(
        receiverId: contactId,
        isVideo: false,
      );

      onSuccess?.call('Llamada de audio iniciada');
      return true;
    } catch (e) {
      print('❌ [ContactProfileController] Error iniciando llamada de audio: $e');
      onError?.call('Error iniciando llamada de audio');
      return false;
    }
  }

  /// Obtener información del usuario como modelo
  Future<User?> getContactAsUser() async {
    try {
      if (_contactData == null) {
        await _loadContactData();
      }

      if (_contactData != null) {
        return User.fromFirestore(_contactData!);
      }
      return null;
    } catch (e) {
      print('❌ [ContactProfileController] Error creando modelo User: $e');
      return null;
    }
  }

  /// Obtener información del contacto como Child (si aplicable)
  Future<Child?> getContactAsChild() async {
    try {
      if (_contactData == null) {
        await _loadContactData();
      }

      if (_contactData != null && _contactData!['role'] == 'child') {
        return Child.fromMap(_contactData!);
      }
      return null;
    } catch (e) {
      print('❌ [ContactProfileController] Error creando modelo Child: $e');
      return null;
    }
  }

  /// Verificar si el contacto es un niño
  bool isContactChild() {
    return _contactData?['role'] == 'child';
  }

  /// Obtener edad del contacto
  int? getContactAge() {
    if (_contactData == null) return null;

    final birthDateField = _contactData!['birthDate'];
    if (birthDateField == null) return null;

    try {
      DateTime birthDate;
      if (birthDateField is Timestamp) {
        birthDate = birthDateField.toDate();
      } else if (birthDateField is String) {
        birthDate = DateTime.parse(birthDateField);
      } else {
        return null;
      }

      final now = DateTime.now();
      int age = now.year - birthDate.year;
      if (now.month < birthDate.month ||
          (now.month == birthDate.month && now.day < birthDate.day)) {
        age--;
      }
      return age;
    } catch (e) {
      print('❌ [ContactProfileController] Error calculando edad: $e');
      return null;
    }
  }

  /// Obtener nombre para mostrar (alias o nombre real)
  String getDisplayName() {
    if (_contactAlias != null && _contactAlias!.isNotEmpty) {
      return _contactAlias!;
    }
    return _contactData?['name'] ?? contactName;
  }

  /// Obtener foto de perfil URL
  String? getPhotoURL() {
    return _contactData?['photoURL'] as String?;
  }

  /// Obtener teléfono del contacto
  String? getPhoneNumber() {
    return _contactData?['phone'] as String?;
  }

  /// Obtener email del contacto
  String? getEmail() {
    return _contactData?['email'] as String?;
  }

  /// Obtener fecha de registro
  DateTime? getJoinDate() {
    final createdAt = _contactData?['createdAt'];
    if (createdAt is Timestamp) {
      return createdAt.toDate();
    }
    return null;
  }

  /// Verificar si el contacto está online
  bool isContactOnline() {
    final lastSeen = _contactData?['lastSeen'];
    if (lastSeen is Timestamp) {
      final lastSeenDate = lastSeen.toDate();
      final now = DateTime.now();
      final difference = now.difference(lastSeenDate);
      return difference.inMinutes < 5; // Online si estuvo activo en los últimos 5 minutos
    }
    return false;
  }

  /// Obtener última vez visto
  DateTime? getLastSeen() {
    final lastSeen = _contactData?['lastSeen'];
    if (lastSeen is Timestamp) {
      return lastSeen.toDate();
    }
    return null;
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

  /// Limpiar recursos
  void dispose() {
    print('🧹 [ContactProfileController] Disposing controller');
    _contactDataSubscription?.cancel();
    _blockStatusSubscription?.cancel();
  }
}