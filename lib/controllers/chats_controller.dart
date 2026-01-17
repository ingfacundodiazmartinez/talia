import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/chat.dart';
import '../services/chats/chat_services.dart';
import '../utils/release_logger.dart';

/// Controller unificado para chats
///
/// Coordina entre Screen y los servicios atómicos de chat.
/// Sigue el patrón: Screen → Controller → Service → Model
///
/// Responsabilidades:
/// - Exponer streams para la UI
/// - Coordinar llamadas a servicios atómicos
/// - Manejar estado de búsqueda y filtros
/// - Gestionar subscriptions
class ChatsController with ChangeNotifier {
  // === DEPENDENCIAS ===
  final FirebaseAuth _auth;
  final ListChatsService _listChatsService;
  final GetChatService _getChatService;
  final SearchChatsService _searchService;
  final CreateChatService _createChatService;
  final ArchiveChatService _archiveService;
  final UnarchiveChatService _unarchiveService;
  final MuteChatService _muteService;
  final UnmuteChatService _unmuteService;
  final DeleteChatService _deleteService;
  final ClearChatService _clearService;
  final ChatPreferencesCache _preferencesCache;

  // === ESTADO ===
  String? _searchQuery;
  bool _showArchived = false;
  bool _isLoading = false;
  String? _error;

  // === STREAMS ===
  StreamSubscription? _chatsSubscription;
  final _chatsController = StreamController<List<Chat>>.broadcast();

  // === GETTERS ===
  String? get currentUserId => _auth.currentUser?.uid;
  String? get searchQuery => _searchQuery;
  bool get showArchived => _showArchived;
  bool get isLoading => _isLoading;
  String? get error => _error;
  Stream<List<Chat>> get chatsStream => _chatsController.stream;

  ChatsController({
    FirebaseAuth? auth,
    ListChatsService? listChatsService,
    GetChatService? getChatService,
    SearchChatsService? searchService,
    CreateChatService? createChatService,
    ArchiveChatService? archiveService,
    UnarchiveChatService? unarchiveService,
    MuteChatService? muteService,
    UnmuteChatService? unmuteService,
    DeleteChatService? deleteService,
    ClearChatService? clearService,
    ChatPreferencesCache? preferencesCache,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _listChatsService = listChatsService ?? ListChatsService(),
        _getChatService = getChatService ?? GetChatService(),
        _searchService = searchService ?? SearchChatsService(),
        _createChatService = createChatService ?? CreateChatService(),
        _archiveService = archiveService ?? ArchiveChatService(),
        _unarchiveService = unarchiveService ?? UnarchiveChatService(),
        _muteService = muteService ?? MuteChatService(),
        _unmuteService = unmuteService ?? UnmuteChatService(),
        _deleteService = deleteService ?? DeleteChatService(),
        _clearService = clearService ?? ClearChatService(),
        _preferencesCache = preferencesCache ?? ChatPreferencesCache();

  // === INICIALIZACIÓN ===

  /// Inicializar controller y comenzar a escuchar chats
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _startListeningChats();
      _error = null;
    } catch (e) {
      _error = 'Error inicializando chats: $e';
      ReleaseLogger.error(_error!, tag: 'ChatsController');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _startListeningChats() async {
    _chatsSubscription?.cancel();

    // Usar el servicio de lista con filtros
    _chatsSubscription = _listChatsService
        .call(includeArchived: _showArchived)
        .listen(
          (chats) {
            // Aplicar filtros locales adicionales
            final filtered = _applyFilters(chats);
            _chatsController.add(filtered);
          },
          onError: (e) {
            ReleaseLogger.error('Error en stream de chats: $e', tag: 'ChatsController');
            _error = 'Error cargando chats';
            notifyListeners();
          },
        );
  }

  List<Chat> _applyFilters(List<Chat> chats) {
    var result = chats;

    // Filtrar por archivados usando el cache
    if (!_showArchived) {
      result = result.where((c) => !_preferencesCache.isArchived(c.id)).toList();
    } else {
      result = result.where((c) => _preferencesCache.isArchived(c.id)).toList();
    }

    // Filtrar por búsqueda
    if (_searchQuery != null && _searchQuery!.isNotEmpty) {
      final query = _searchQuery!.toLowerCase();
      result = result.where((c) {
        final name = c.displayName.toLowerCase();
        final lastMsg = c.lastMessage?.toLowerCase() ?? '';
        return name.contains(query) || lastMsg.contains(query);
      }).toList();
    }

    return result;
  }

  // === ACCIONES DE UI ===

  /// Cambiar query de búsqueda
  void setSearchQuery(String? query) {
    _searchQuery = query;
    notifyListeners();
    _refreshStream();
  }

  /// Toggle mostrar archivados
  void toggleShowArchived() {
    _showArchived = !_showArchived;
    notifyListeners();
    _refreshStream();
  }

  /// Forzar refresh de la lista
  Future<void> refresh() async {
    await _startListeningChats();
  }

  void _refreshStream() {
    _startListeningChats();
  }

  // === OPERACIONES DE CHAT ===

  /// Obtener un chat específico
  Future<Chat?> getChat(String chatId) async {
    return await _getChatService.call(chatId);
  }

  /// Stream de un chat específico
  Stream<Chat?> watchChat(String chatId) {
    return _getChatService.watch(chatId);
  }

  /// Crear o navegar a chat con usuario
  Future<({bool success, String? chatId, bool isNew, String message})> createOrNavigateToChat({
    required String otherUserId,
  }) async {
    return await _createChatService.call(otherUserId: otherUserId);
  }

  /// Buscar chats
  Future<List<Chat>> searchChats(String query) async {
    return await _searchService.call(query: query);
  }

  // === ACCIONES DE CHAT ===

  /// Archivar chat
  Future<bool> archiveChat(String chatId) async {
    final result = await _archiveService.call(chatId: chatId);

    if (result.success) {
      _refreshStream();
    }

    return result.success;
  }

  /// Desarchivar chat
  Future<bool> unarchiveChat(String chatId) async {
    final result = await _unarchiveService.call(chatId: chatId);

    if (result.success) {
      _refreshStream();
    }

    return result.success;
  }

  /// Silenciar chat
  Future<bool> muteChat(String chatId, {Duration? duration}) async {
    final result = await _muteService.call(
      chatId: chatId,
      duration: duration,
    );

    if (result.success) {
      notifyListeners();
    }

    return result.success;
  }

  /// Desilenciar chat
  Future<bool> unmuteChat(String chatId) async {
    final result = await _unmuteService.call(chatId: chatId);

    if (result.success) {
      notifyListeners();
    }

    return result.success;
  }

  /// Verificar si chat está silenciado
  bool isChatMuted(String chatId) {
    return _preferencesCache.isMuted(chatId);
  }

  /// Verificar si chat está archivado
  bool isChatArchived(String chatId) {
    return _preferencesCache.isArchived(chatId);
  }

  /// Eliminar chat (soft delete)
  Future<bool> deleteChat(String chatId) async {
    final result = await _deleteService.call(chatId: chatId);

    if (result.success) {
      _refreshStream();
    }

    return result.success;
  }

  /// Limpiar historial de chat
  Future<bool> clearChat(String chatId) async {
    final result = await _clearService.call(chatId: chatId);
    return result.success;
  }

  // === HELPERS ===

  /// Generar chatId entre dos usuarios
  String getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  /// Formatear tiempo de último mensaje
  String formatLastMessageTime(DateTime? time) {
    if (time == null) return '';

    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays > 0) {
      if (diff.inDays == 1) return 'Ayer';
      if (diff.inDays < 7) return '${diff.inDays}d';
      return '${time.day}/${time.month}';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}h';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  /// Obtener conteo de no leídos para un chat
  int getUnreadCount(String chatId) {
    return _preferencesCache.getUnreadCount(chatId);
  }

  // === CLEANUP ===

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    _chatsController.close();
    super.dispose();
  }
}
