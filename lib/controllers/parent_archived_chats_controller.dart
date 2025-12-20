import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../models/chat.dart';
import '../services/chats/chat_services.dart';
import '../services/contact_alias_service.dart';
import '../services/block_service.dart';
import '../utils/release_logger.dart';

/// Controller para la pantalla de chats archivados de padres
///
/// Responsabilidades:
/// - Gestionar autenticación de usuario
/// - Obtener información de usuarios (Firestore)
/// - Manejar operaciones de archivado/desarchivado
/// - Proporcionar streams de servicios
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
///
/// ✅ CORREGIDO: Usa ChatPreferencesCache (Hive) en vez de Firestore
class ParentArchivedChatsController {
  // Servicios privados
  final ListChatsService _listChatsService;
  final UnarchiveChatService _unarchiveService;
  final ChatPreferencesCache _preferencesCache;
  final ContactAliasService _aliasService;
  final BlockService _blockService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  String? _currentUserId;
  StreamSubscription? _chatsSubscription;
  final _archivedChatsController = StreamController<List<Chat>>.broadcast();

  /// Constructor
  ParentArchivedChatsController({
    ListChatsService? listChatsService,
    UnarchiveChatService? unarchiveService,
    ChatPreferencesCache? preferencesCache,
    ContactAliasService? aliasService,
    BlockService? blockService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  })  : _listChatsService = listChatsService ?? ListChatsService(),
        _unarchiveService = unarchiveService ?? UnarchiveChatService(),
        _preferencesCache = preferencesCache ?? ChatPreferencesCache(),
        _aliasService = aliasService ?? ContactAliasService(),
        _blockService = blockService ?? BlockService(),
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  String get currentUserIdSafe => currentUserId ?? '';
  bool get isUserAuthenticated => currentUserId != null;
  Stream<List<Chat>> get archivedChatsStream => _archivedChatsController.stream;

  /// Inicializar el controller
  void initialize() {
    try {
      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.warning('Usuario no autenticado en ParentArchivedChatsController', tag: 'ArchivedChats');
      } else {
        ReleaseLogger.log('ParentArchivedChatsController inicializado para usuario: $_currentUserId', tag: 'ArchivedChats');
        _startListeningChats();
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando ParentArchivedChatsController: $e', tag: 'ArchivedChats');
    }
  }

  /// ✅ Escuchar chats y filtrar archivados desde Hive
  void _startListeningChats() {
    _chatsSubscription?.cancel();

    _chatsSubscription = _listChatsService
        .call(includeArchived: true)
        .listen(
          (chats) {
            // Filtrar solo los archivados usando el cache de Hive
            final archived = chats.where((c) => _preferencesCache.isArchived(c.id)).toList();
            _archivedChatsController.add(archived);
          },
          onError: (e) {
            ReleaseLogger.error('Error en stream de chats archivados: $e', tag: 'ArchivedChats');
          },
        );
  }

  /// Refrescar la lista
  void refresh() {
    _startListeningChats();
  }

  /// Desarchivar chat
  Future<bool> unarchiveChat(String chatId) async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para desarchivar chat', tag: 'ArchivedChats');
        return false;
      }

      final result = await _unarchiveService.call(chatId: chatId);

      if (result.success) {
        ReleaseLogger.log('Chat $chatId desarchivado exitosamente', tag: 'ArchivedChats');
        refresh(); // Refrescar la lista
      } else {
        ReleaseLogger.error('Error desarchivando chat $chatId: ${result.message}', tag: 'ArchivedChats');
      }

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error desarchivando chat: $e', tag: 'ArchivedChats');
      return false;
    }
  }

  /// Obtener información de usuario desde Firestore
  Future<DocumentSnapshot> getUserDocument(String userId) async {
    try {
      return await _firestore
          .collection('users')
          .doc(userId)
          .get();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo documento de usuario $userId: $e', tag: 'ArchivedChats');
      rethrow;
    }
  }

  /// Stream para observar alias/nombre de contacto
  Stream<String> watchDisplayName(String userId, String realName) {
    try {
      return _aliasService.watchDisplayName(userId, realName);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de nombre de usuario: $e', tag: 'ArchivedChats');
      return Stream.value(realName);
    }
  }

  /// Stream para verificar si un usuario está bloqueado
  Stream<bool> isBlockedStream(String userId) {
    try {
      return _blockService.isBlockedStream(userId);
    } catch (e) {
      ReleaseLogger.error('Error creando stream de bloqueo: $e', tag: 'ArchivedChats');
      return Stream.value(false);
    }
  }

  /// Verificar si un chat fue limpiado
  bool isChatCleared(String chatId) {
    final clearedAt = _preferencesCache.getClearedAt(chatId);
    return clearedAt != null;
  }

  /// Obtener el otro participante de un chat
  String getOtherParticipant(List<String> participants) {
    try {
      final userId = currentUserIdSafe;
      return participants.firstWhere(
        (id) => id != userId,
        orElse: () => '',
      );
    } catch (e) {
      ReleaseLogger.error('Error obteniendo otro participante: $e', tag: 'ArchivedChats');
      return '';
    }
  }

  /// Formatear datos de usuario para UI
  Map<String, dynamic> formatUserData(DocumentSnapshot userSnapshot) {
    try {
      if (!userSnapshot.exists) {
        return {
          'realName': 'Usuario',
          'isOnline': false,
          'photoURL': null,
        };
      }

      final userData = userSnapshot.data() as Map<String, dynamic>?;
      if (userData == null) {
        return {
          'realName': 'Usuario',
          'isOnline': false,
          'photoURL': null,
        };
      }

      return {
        'realName': userData['name'] ?? 'Usuario',
        'isOnline': userData['isOnline'] ?? false,
        'photoURL': userData['photoURL'],
      };
    } catch (e) {
      ReleaseLogger.error('Error formateando datos de usuario: $e', tag: 'ArchivedChats');
      return {
        'realName': 'Usuario',
        'isOnline': false,
        'photoURL': null,
      };
    }
  }

  /// Logging para operaciones
  void logChatOperation(String operation, String chatId) {
    ReleaseLogger.log('$operation para chat: $chatId', tag: 'ArchivedChats');
  }

  /// Logging para errores
  void logError(String message, dynamic error) {
    ReleaseLogger.error('$message: $error', tag: 'ArchivedChats');
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ParentArchivedChatsController', tag: 'ArchivedChats');
    _chatsSubscription?.cancel();
    _archivedChatsController.close();
  }
}
