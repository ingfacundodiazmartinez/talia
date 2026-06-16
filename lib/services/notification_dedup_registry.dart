import 'dart:collection';

/// Registry unificado para deduplicación de notificaciones.
///
/// Antes había 5+ sets distintos (`_processedMessageIds`, `_processedCallIds`,
/// `_processedNotificationIds`, `_globalShownNotificationIds`, etc.) con
/// semánticas y bounds inconsistentes. Esta clase los reemplaza con un único
/// store namespaced + TTL + LRU.
///
/// Uso:
/// ```
/// final dedup = NotificationDedupRegistry.instance;
/// if (dedup.tryAcquire(DedupNs.shown, messageId)) {
///   // primera vez que vemos este mensaje en este namespace
/// }
/// ```
///
/// Namespaces actuales:
/// - `shown`: notificación mostrada al usuario (StreamDetector + FCM compiten,
///   gana el primero, segundo skipea).
/// - `processedMessage`: mensajes ya procesados internamente (unread count,
///   read receipts).
/// - `processedCall`: callIds ya procesados (background handler).
/// - `tap`: notificaciones tapeadas (evita navegación duplicada cuando
///   múltiples handlers compiten al abrir desde notificación).
enum DedupNs {
  shown,
  processedMessage,
  processedCall,
  tap,
}

class NotificationDedupRegistry {
  NotificationDedupRegistry._();
  static final NotificationDedupRegistry instance = NotificationDedupRegistry._();

  /// Configuración por namespace.
  static const Map<DedupNs, _NsConfig> _config = {
    DedupNs.shown: _NsConfig(maxSize: 500, ttl: Duration(minutes: 5)),
    DedupNs.processedMessage: _NsConfig(maxSize: 1000, ttl: Duration(minutes: 10)),
    DedupNs.processedCall: _NsConfig(maxSize: 200, ttl: Duration(minutes: 30)),
    // ✅ FIX: 30s (era 5s). En cold start desde tap compiten varios handlers
    // (getInitialMessage, pending_notification_data, method channel nativo)
    // con delays de 500ms + init diferido post-frame; en devices lentos el
    // segundo handler llegaba después de los 5s y navegaba DOS veces (doble
    // pantalla de chat en el stack).
    DedupNs.tap: _NsConfig(maxSize: 100, ttl: Duration(seconds: 30)),
  };

  /// Almacenamiento por namespace. Usamos LinkedHashMap como LRU: insertion
  /// order se preserva, los más viejos están al principio.
  final Map<DedupNs, LinkedHashMap<String, int>> _stores = {
    // ignore: prefer_collection_literals — LinkedHashMap insertion-order is critical for LRU
    for (final ns in DedupNs.values) ns: LinkedHashMap<String, int>(),
  };

  /// Intenta adquirir el "derecho" a procesar [key] en [ns].
  ///
  /// Retorna `true` si es la primera vez que vemos esta key en este namespace
  /// (y por lo tanto, el caller debe procesar). Retorna `false` si ya estaba
  /// (es duplicado, skipear).
  ///
  /// La entry queda registrada con timestamp para TTL. Si la key estaba pero
  /// expiró, se considera nueva y se renueva.
  bool tryAcquire(DedupNs ns, String key) {
    if (key.isEmpty) return true; // No deduplicar keys vacías
    final store = _stores[ns]!;
    final cfg = _config[ns]!;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Si ya existe Y no expiró, es duplicado.
    final existing = store[key];
    if (existing != null && (now - existing) < cfg.ttl.inMilliseconds) {
      return false;
    }

    // Insertar/refrescar. Removemos primero para que vaya al final de la LRU.
    store.remove(key);
    store[key] = now;

    // Enforcement de LRU: si excede maxSize, drop el más viejo (primero).
    while (store.length > cfg.maxSize) {
      store.remove(store.keys.first);
    }

    return true;
  }

  /// Marca una key como procesada (idempotente con `tryAcquire`, pero sin
  /// retornar valor — útil cuando ya sabés que es nueva o querés forzar).
  void mark(DedupNs ns, String key) {
    tryAcquire(ns, key);
  }

  /// Chequeo no-mutativo: ¿está la key registrada (y vigente)?
  bool contains(DedupNs ns, String key) {
    if (key.isEmpty) return false;
    final store = _stores[ns]!;
    final ts = store[key];
    if (ts == null) return false;
    final cfg = _config[ns]!;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - ts) < cfg.ttl.inMilliseconds;
  }

  /// Quita explícitamente una key (ej. al cerrar sesión).
  void remove(DedupNs ns, String key) {
    _stores[ns]?.remove(key);
  }

  /// Limpia un namespace completo (ej. al cerrar sesión).
  void clearNamespace(DedupNs ns) {
    _stores[ns]?.clear();
  }

  /// Limpia TODO (ej. logout).
  void clearAll() {
    for (final store in _stores.values) {
      store.clear();
    }
  }

  /// Tamaño actual de un namespace (debug/metrics).
  int sizeOf(DedupNs ns) => _stores[ns]?.length ?? 0;
}

class _NsConfig {
  final int maxSize;
  final Duration ttl;
  const _NsConfig({required this.maxSize, required this.ttl});
}
