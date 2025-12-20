import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../utils/release_logger.dart';

/// Cache local para preferencias de chat por usuario
///
/// Almacena datos que NO necesitan estar en Firestore porque:
/// - Solo afectan la UI local del usuario
/// - No se comparten entre usuarios
/// - No requieren sincronización multi-dispositivo crítica
///
/// Datos almacenados:
/// - archived: Set de chatIds archivados
/// - muted: Map de chatId -> DateTime (hasta cuando está silenciado)
/// - unreadCounts: Map de chatId -> int
/// - clearedAt: Map de chatId -> DateTime (mensajes anteriores no se muestran)
///
/// Beneficios vs Firestore:
/// - Operaciones instantáneas (sin latencia de red)
/// - Funciona offline nativamente
/// - Menos escrituras a Firestore = menos costo ($$$)
/// - Documentos más pequeños = menos bandwidth
class ChatPreferencesCache {
  static final ChatPreferencesCache _instance = ChatPreferencesCache._internal();
  factory ChatPreferencesCache() => _instance;
  ChatPreferencesCache._internal();

  static const String _boxName = 'chat_preferences';

  // Keys para los diferentes tipos de preferencias
  static const String _archivedKey = 'archived';
  static const String _mutedKey = 'muted';
  static const String _unreadCountsKey = 'unread_counts';
  static const String _clearedAtKey = 'cleared_at';
  static const String _deletedKey = 'deleted';
  static const String _lastSyncKey = 'last_sync';

  Box? _box;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  // ═══════════════════════════════════════════════════════════════
  // INITIALIZATION
  // ═══════════════════════════════════════════════════════════════

  /// Inicializar el cache
  /// Debe llamarse en main.dart después de Hive.initFlutter()
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _box = await Hive.openBox(_boxName);
      _isInitialized = true;
      ReleaseLogger.log('ChatPreferencesCache inicializado', tag: 'ChatCache');
    } catch (e) {
      ReleaseLogger.error(
        'Error inicializando ChatPreferencesCache: $e',
        tag: 'ChatCache',
      );
    }
  }

  /// Asegurar que el cache está inicializado
  Future<void> _ensureInitialized() async {
    if (!_isInitialized || _box == null) {
      await initialize();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ARCHIVED CHATS
  // ═══════════════════════════════════════════════════════════════

  /// Archivar un chat
  Future<void> archiveChat(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final archived = Set<String>.from(_box!.get(_archivedKey) ?? []);
    archived.add(chatId);
    await _box!.put(_archivedKey, archived.toList());

    ReleaseLogger.log('Chat archivado: $chatId', tag: 'ChatCache');
  }

  /// Desarchivar un chat
  Future<void> unarchiveChat(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final archived = Set<String>.from(_box!.get(_archivedKey) ?? []);
    archived.remove(chatId);
    await _box!.put(_archivedKey, archived.toList());

    ReleaseLogger.log('Chat desarchivado: $chatId', tag: 'ChatCache');
  }

  /// Verificar si un chat está archivado
  bool isArchived(String chatId) {
    if (_box == null) return false;

    final archived = Set<String>.from(_box!.get(_archivedKey) ?? []);
    return archived.contains(chatId);
  }

  /// Obtener todos los chats archivados
  Set<String> getArchivedChats() {
    if (_box == null) return {};
    return Set<String>.from(_box!.get(_archivedKey) ?? []);
  }

  // ═══════════════════════════════════════════════════════════════
  // MUTED CHATS
  // ═══════════════════════════════════════════════════════════════

  /// Silenciar un chat
  /// [until] es opcional. Si es null, se silencia indefinidamente.
  Future<void> muteChat(String chatId, {DateTime? until}) async {
    await _ensureInitialized();
    if (_box == null) return;

    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});

    // Si until es null, usar una fecha muy lejana (silenciado indefinidamente)
    final mutedUntil = until ?? DateTime(2100, 1, 1);
    muted[chatId] = mutedUntil.millisecondsSinceEpoch;
    await _box!.put(_mutedKey, muted);

    // ✅ Sincronizar con SharedPreferences para que Android nativo pueda leerlo
    await _syncMutedChatsToNative();

    ReleaseLogger.log(
      'Chat silenciado: $chatId hasta ${until ?? "indefinidamente"}',
      tag: 'ChatCache',
    );
  }

  /// Desilenciar un chat
  Future<void> unmuteChat(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});
    muted.remove(chatId);
    await _box!.put(_mutedKey, muted);

    // ✅ Sincronizar con SharedPreferences para que Android nativo pueda leerlo
    await _syncMutedChatsToNative();

    ReleaseLogger.log('Chat desilenciado: $chatId', tag: 'ChatCache');
  }

  /// ✅ Sincronizar lista de chats silenciados con SharedPreferences (Android nativo)
  ///
  /// El servicio nativo MyFirebaseMessagingService lee esta lista para
  /// no mostrar notificaciones de chats silenciados cuando la app está en background.
  Future<void> _syncMutedChatsToNative() async {
    try {
      final mutedChatIds = getMutedChats().keys.toList();
      final prefs = await SharedPreferences.getInstance();

      // Guardar como lista de strings separadas por coma
      // Android lo lee como: sharedPrefs.getString("flutter.muted_chat_ids", "")
      await prefs.setString('muted_chat_ids', mutedChatIds.join(','));

      ReleaseLogger.log(
        'Muted chats sincronizados con SharedPreferences: ${mutedChatIds.length} chats',
        tag: 'ChatCache',
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error sincronizando muted chats con SharedPreferences: $e',
        tag: 'ChatCache',
      );
    }
  }

  /// Verificar si un chat está silenciado
  bool isMuted(String chatId) {
    if (_box == null) return false;

    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});
    if (!muted.containsKey(chatId)) return false;

    final mutedUntil = DateTime.fromMillisecondsSinceEpoch(muted[chatId] as int);
    return DateTime.now().isBefore(mutedUntil);
  }

  /// Obtener fecha hasta cuando está silenciado (null si no está silenciado)
  DateTime? getMutedUntil(String chatId) {
    if (_box == null) return null;

    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});
    if (!muted.containsKey(chatId)) return null;

    final mutedUntil = DateTime.fromMillisecondsSinceEpoch(muted[chatId] as int);
    if (DateTime.now().isAfter(mutedUntil)) return null;

    return mutedUntil;
  }

  /// Obtener todos los chats silenciados
  Map<String, DateTime> getMutedChats() {
    if (_box == null) return {};

    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});
    final now = DateTime.now();
    final result = <String, DateTime>{};

    for (final entry in muted.entries) {
      final mutedUntil = DateTime.fromMillisecondsSinceEpoch(entry.value as int);
      if (now.isBefore(mutedUntil)) {
        result[entry.key] = mutedUntil;
      }
    }

    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // UNREAD COUNTS
  // ═══════════════════════════════════════════════════════════════

  /// Establecer contador de mensajes no leídos
  Future<void> setUnreadCount(String chatId, int count) async {
    await _ensureInitialized();
    if (_box == null) return;

    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    counts[chatId] = count;
    await _box!.put(_unreadCountsKey, counts);
  }

  /// Incrementar contador de mensajes no leídos
  Future<void> incrementUnreadCount(String chatId, {int by = 1}) async {
    await _ensureInitialized();
    if (_box == null) return;

    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    final current = (counts[chatId] as int?) ?? 0;
    counts[chatId] = current + by;
    await _box!.put(_unreadCountsKey, counts);
  }

  /// Marcar chat como leído (resetear contador a 0)
  Future<void> markAsRead(String chatId) async {
    await setUnreadCount(chatId, 0);
    ReleaseLogger.log('Chat marcado como leído: $chatId', tag: 'ChatCache');
  }

  /// Obtener contador de mensajes no leídos
  int getUnreadCount(String chatId) {
    if (_box == null) return 0;

    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    return (counts[chatId] as int?) ?? 0;
  }

  /// Obtener total de mensajes no leídos
  int getTotalUnreadCount() {
    if (_box == null) return 0;

    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    int total = 0;
    for (final count in counts.values) {
      total += (count as int?) ?? 0;
    }
    return total;
  }

  /// Obtener todos los contadores de mensajes no leídos
  Map<String, int> getAllUnreadCounts() {
    if (_box == null) return {};

    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    return counts.map((k, v) => MapEntry(k, (v as int?) ?? 0));
  }

  // ═══════════════════════════════════════════════════════════════
  // CLEARED AT (Para limpiar historial de chat)
  // ═══════════════════════════════════════════════════════════════

  /// Establecer timestamp de "chat limpiado"
  /// Mensajes anteriores a este timestamp no se mostrarán
  Future<void> setClearedAt(String chatId, DateTime clearedAt) async {
    await _ensureInitialized();
    if (_box == null) return;

    final cleared = Map<String, dynamic>.from(_box!.get(_clearedAtKey) ?? {});
    cleared[chatId] = clearedAt.millisecondsSinceEpoch;
    await _box!.put(_clearedAtKey, cleared);

    ReleaseLogger.log('Chat limpiado: $chatId desde $clearedAt', tag: 'ChatCache');
  }

  /// Obtener timestamp de "chat limpiado"
  DateTime? getClearedAt(String chatId) {
    if (_box == null) return null;

    final cleared = Map<String, dynamic>.from(_box!.get(_clearedAtKey) ?? {});
    if (!cleared.containsKey(chatId)) return null;

    return DateTime.fromMillisecondsSinceEpoch(cleared[chatId] as int);
  }

  /// Limpiar el timestamp de "chat limpiado" (restaurar historial completo)
  Future<void> clearClearedAt(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final cleared = Map<String, dynamic>.from(_box!.get(_clearedAtKey) ?? {});
    cleared.remove(chatId);
    await _box!.put(_clearedAtKey, cleared);
  }

  // ═══════════════════════════════════════════════════════════════
  // DELETED CHATS (Soft delete local)
  // ═══════════════════════════════════════════════════════════════

  /// Marcar chat como eliminado (soft delete local)
  Future<void> deleteChat(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final deleted = Set<String>.from(_box!.get(_deletedKey) ?? []);
    deleted.add(chatId);
    await _box!.put(_deletedKey, deleted.toList());

    ReleaseLogger.log('Chat eliminado (local): $chatId', tag: 'ChatCache');
  }

  /// Restaurar chat eliminado
  Future<void> restoreChat(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    final deleted = Set<String>.from(_box!.get(_deletedKey) ?? []);
    deleted.remove(chatId);
    await _box!.put(_deletedKey, deleted.toList());

    ReleaseLogger.log('Chat restaurado: $chatId', tag: 'ChatCache');
  }

  /// Verificar si un chat está eliminado
  bool isDeleted(String chatId) {
    if (_box == null) return false;

    final deleted = Set<String>.from(_box!.get(_deletedKey) ?? []);
    return deleted.contains(chatId);
  }

  /// Obtener todos los chats eliminados
  Set<String> getDeletedChats() {
    if (_box == null) return {};
    return Set<String>.from(_box!.get(_deletedKey) ?? []);
  }

  // ═══════════════════════════════════════════════════════════════
  // SYNC TIMESTAMP
  // ═══════════════════════════════════════════════════════════════

  /// Guardar timestamp de última sincronización
  Future<void> setLastSyncTime(DateTime time) async {
    await _ensureInitialized();
    if (_box == null) return;
    await _box!.put(_lastSyncKey, time.millisecondsSinceEpoch);
  }

  /// Obtener timestamp de última sincronización
  DateTime? getLastSyncTime() {
    if (_box == null) return null;
    final timestamp = _box!.get(_lastSyncKey) as int?;
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  // ═══════════════════════════════════════════════════════════════
  // BULK OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Aplicar filtros a una lista de chats
  /// Retorna la lista filtrada según preferencias locales
  List<T> applyFilters<T>({
    required List<T> chats,
    required String Function(T) getChatId,
    bool includeArchived = false,
    bool includeDeleted = false,
  }) {
    return chats.where((chat) {
      final chatId = getChatId(chat);

      // Filtrar eliminados
      if (!includeDeleted && isDeleted(chatId)) return false;

      // Filtrar archivados
      if (!includeArchived && isArchived(chatId)) return false;

      return true;
    }).toList();
  }

  /// Obtener preferencias de un chat específico
  ChatPreferences getPreferencesFor(String chatId) {
    return ChatPreferences(
      chatId: chatId,
      isArchived: isArchived(chatId),
      isMuted: isMuted(chatId),
      mutedUntil: getMutedUntil(chatId),
      unreadCount: getUnreadCount(chatId),
      clearedAt: getClearedAt(chatId),
      isDeleted: isDeleted(chatId),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar todas las preferencias de un chat
  Future<void> clearPreferencesFor(String chatId) async {
    await _ensureInitialized();
    if (_box == null) return;

    // Remover de archived
    final archived = Set<String>.from(_box!.get(_archivedKey) ?? []);
    archived.remove(chatId);
    await _box!.put(_archivedKey, archived.toList());

    // Remover de muted
    final muted = Map<String, dynamic>.from(_box!.get(_mutedKey) ?? {});
    muted.remove(chatId);
    await _box!.put(_mutedKey, muted);

    // Remover de unread counts
    final counts = Map<String, dynamic>.from(_box!.get(_unreadCountsKey) ?? {});
    counts.remove(chatId);
    await _box!.put(_unreadCountsKey, counts);

    // Remover de cleared at
    final cleared = Map<String, dynamic>.from(_box!.get(_clearedAtKey) ?? {});
    cleared.remove(chatId);
    await _box!.put(_clearedAtKey, cleared);

    // Remover de deleted
    final deleted = Set<String>.from(_box!.get(_deletedKey) ?? []);
    deleted.remove(chatId);
    await _box!.put(_deletedKey, deleted.toList());

    ReleaseLogger.log('Preferencias limpiadas para: $chatId', tag: 'ChatCache');
  }

  /// Limpiar todo el cache (usar con cuidado)
  Future<void> clearAll() async {
    await _ensureInitialized();
    if (_box == null) return;

    await _box!.clear();
    ReleaseLogger.log('Cache de preferencias limpiado completamente', tag: 'ChatCache');
  }

  /// Cerrar el cache (llamar en dispose de la app)
  Future<void> close() async {
    if (_box != null && _box!.isOpen) {
      await _box!.close();
      _isInitialized = false;
      _box = null;
    }
  }
}

/// Clase que agrupa las preferencias de un chat
class ChatPreferences {
  final String chatId;
  final bool isArchived;
  final bool isMuted;
  final DateTime? mutedUntil;
  final int unreadCount;
  final DateTime? clearedAt;
  final bool isDeleted;

  const ChatPreferences({
    required this.chatId,
    required this.isArchived,
    required this.isMuted,
    this.mutedUntil,
    required this.unreadCount,
    this.clearedAt,
    required this.isDeleted,
  });

  @override
  String toString() {
    return 'ChatPreferences(chatId: $chatId, archived: $isArchived, muted: $isMuted, unread: $unreadCount)';
  }
}
