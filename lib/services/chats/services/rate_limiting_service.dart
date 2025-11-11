import 'dart:async';
import 'dart:collection';

import '../utils/chat_exceptions.dart';
import '../../../utils/release_logger.dart';

/// Servicio de rate limiting para operaciones de chat
///
/// Responsabilidades:
/// - Rate limiting por usuario y operación
/// - Throttling de mensajes consecutivos
/// - Cooldown periods entre operaciones
/// - Métricas de uso y bloqueos
class RateLimitingService {
  // Configuraciones de límites
  static const Map<String, RateLimit> _rateLimits = {
    'send_message': RateLimit(maxCount: 30, windowDuration: Duration(minutes: 1)),
    'create_group': RateLimit(maxCount: 5, windowDuration: Duration(minutes: 5)),
    'add_member': RateLimit(maxCount: 20, windowDuration: Duration(minutes: 5)),
    'edit_message': RateLimit(maxCount: 10, windowDuration: Duration(minutes: 1)),
    'delete_message': RateLimit(maxCount: 10, windowDuration: Duration(minutes: 1)),
    'forward_message': RateLimit(maxCount: 20, windowDuration: Duration(minutes: 5)),
  };

  // Storage en memoria de contadores por usuario
  final Map<String, Map<String, LinkedHashMap<DateTime, int>>> _userCounters = {};

  // Throttling específico para mensajes
  final Map<String, DateTime> _lastMessageTime = {};
  final Duration _messageThrottleDuration = Duration(milliseconds: 500);

  // Métricas
  int _totalBlocks = 0;
  int _totalRequests = 0;

  // Singleton
  static RateLimitingService? _instance;
  factory RateLimitingService() => _instance ??= RateLimitingService._internal();
  RateLimitingService._internal();

  // ═══════════════════════════════════════════════════════════════
  // RATE LIMITING VALIDATION
  // ═══════════════════════════════════════════════════════════════

  /// Validar si operación está dentro del rate limit
  Future<void> checkRateLimit({
    required String userId,
    required String operation,
    Map<String, dynamic>? metadata,
  }) async {
    _totalRequests++;

    final rateLimit = _rateLimits[operation];
    if (rateLimit == null) {
      ReleaseLogger.warning('Rate limit no configurado para operación: $operation');
      return;
    }

    // Limpiar ventana de tiempo antigua
    await _cleanupOldEntries(userId, operation, rateLimit.windowDuration);

    // Contar operaciones en la ventana actual
    final currentCount = _getCurrentCount(userId, operation);

    if (currentCount >= rateLimit.maxCount) {
      _totalBlocks++;

      final retryAfter = _calculateRetryAfter(userId, operation, rateLimit);

      ReleaseLogger.warning(
        'Rate limit excedido para $operation por usuario $userId: $currentCount/${rateLimit.maxCount}',
        tag: 'RateLimit',
      );

      throw RateLimitException(
        'Has realizado demasiadas operaciones de $operation. Intenta nuevamente en ${retryAfter.inSeconds} segundos.',
        operation: operation,
        retryAfter: retryAfter,
        currentCount: currentCount,
        maxAllowed: rateLimit.maxCount,
      );
    }

    // Registrar operación actual
    _recordOperation(userId, operation);

    ReleaseLogger.info(
      'Rate limit OK para $operation: ${currentCount + 1}/${rateLimit.maxCount}',
      tag: 'RateLimit',
    );
  }

  /// Throttling específico para mensajes (prevenir spam)
  Future<void> checkMessageThrottle(String userId) async {
    final lastTime = _lastMessageTime[userId];
    if (lastTime != null) {
      final timeSinceLastMessage = DateTime.now().difference(lastTime);
      if (timeSinceLastMessage < _messageThrottleDuration) {
        final waitTime = _messageThrottleDuration - timeSinceLastMessage;

        ReleaseLogger.warning(
          'Usuario $userId enviando mensajes muy rápido. Esperando ${waitTime.inMilliseconds}ms',
          tag: 'MessageThrottle',
        );

        throw RateLimitException(
          'Estás enviando mensajes muy rápido. Espera un momento antes de enviar otro.',
          operation: 'message_throttle',
          retryAfter: waitTime,
          currentCount: 1,
          maxAllowed: 1,
        );
      }
    }

    _lastMessageTime[userId] = DateTime.now();
  }

  // ═══════════════════════════════════════════════════════════════
  // SPECIFIC VALIDATION METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Validar rate limit para envío de mensajes
  Future<void> validateMessageSending(String userId) async {
    await checkMessageThrottle(userId);
    await checkRateLimit(userId: userId, operation: 'send_message');
  }

  /// Validar rate limit para creación de grupos
  Future<void> validateGroupCreation(String userId) async {
    await checkRateLimit(userId: userId, operation: 'create_group');
  }

  /// Validar rate limit para agregar miembros
  Future<void> validateAddMember(String userId, {int memberCount = 1}) async {
    // Rate limit escalado por número de miembros
    for (int i = 0; i < memberCount; i++) {
      await checkRateLimit(userId: userId, operation: 'add_member');
    }
  }

  /// Validar rate limit para edición de mensajes
  Future<void> validateMessageEditing(String userId) async {
    await checkRateLimit(userId: userId, operation: 'edit_message');
  }

  /// Validar rate limit para eliminación de mensajes
  Future<void> validateMessageDeletion(String userId) async {
    await checkRateLimit(userId: userId, operation: 'delete_message');
  }

  /// Validar rate limit para forward de mensajes
  Future<void> validateMessageForwarding(String userId, {int targetCount = 1}) async {
    // Rate limit escalado por número de destinos
    for (int i = 0; i < targetCount; i++) {
      await checkRateLimit(userId: userId, operation: 'forward_message');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE HELPER METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Limpiar entradas antiguas fuera de la ventana de tiempo
  Future<void> _cleanupOldEntries(String userId, String operation, Duration windowDuration) async {
    if (!_userCounters.containsKey(userId)) return;
    if (!_userCounters[userId]!.containsKey(operation)) return;

    final cutoffTime = DateTime.now().subtract(windowDuration);
    final operationMap = _userCounters[userId]![operation]!;

    // Remover entradas más antiguas que cutoffTime
    operationMap.removeWhere((time, count) => time.isBefore(cutoffTime));
  }

  /// Obtener count actual en la ventana de tiempo
  int _getCurrentCount(String userId, String operation) {
    if (!_userCounters.containsKey(userId)) return 0;
    if (!_userCounters[userId]!.containsKey(operation)) return 0;

    final operationMap = _userCounters[userId]![operation]!;
    return operationMap.values.fold(0, (sum, count) => sum + count);
  }

  /// Registrar nueva operación
  void _recordOperation(String userId, String operation) {
    _userCounters.putIfAbsent(userId, () => {});
    _userCounters[userId]!.putIfAbsent(operation, () => LinkedHashMap<DateTime, int>());

    final now = DateTime.now();
    _userCounters[userId]![operation]![now] = 1;
  }

  /// Calcular tiempo hasta poder retry
  Duration _calculateRetryAfter(String userId, String operation, RateLimit rateLimit) {
    if (!_userCounters.containsKey(userId)) return Duration.zero;
    if (!_userCounters[userId]!.containsKey(operation)) return Duration.zero;

    final operationMap = _userCounters[userId]![operation]!;
    if (operationMap.isEmpty) return Duration.zero;

    // Tiempo de la operación más antigua en la ventana
    final oldestTime = operationMap.keys.first;
    final retryTime = oldestTime.add(rateLimit.windowDuration);
    final now = DateTime.now();

    return retryTime.isAfter(now) ? retryTime.difference(now) : Duration.zero;
  }

  // ═══════════════════════════════════════════════════════════════
  // METRICS & ADMINISTRATION
  // ═══════════════════════════════════════════════════════════════

  /// Obtener métricas del rate limiting
  Map<String, dynamic> getMetrics() {
    final activeUsers = _userCounters.keys.length;
    final totalOperations = _userCounters.values
        .expand((userOps) => userOps.values)
        .expand((opMap) => opMap.values)
        .fold(0, (sum, count) => sum + count);

    return {
      'totalRequests': _totalRequests,
      'totalBlocks': _totalBlocks,
      'blockRate': _totalRequests > 0 ? _totalBlocks / _totalRequests : 0.0,
      'activeUsers': activeUsers,
      'totalOperations': totalOperations,
      'rateLimitConfig': _rateLimits.map(
        (op, limit) => MapEntry(op, {
          'maxCount': limit.maxCount,
          'windowMinutes': limit.windowDuration.inMinutes,
        }),
      ),
    };
  }

  /// Obtener estado del rate limit para un usuario específico
  Map<String, dynamic> getUserLimitStatus(String userId) {
    if (!_userCounters.containsKey(userId)) {
      return {'status': 'clean', 'operations': {}};
    }

    final userOps = <String, dynamic>{};
    for (final entry in _userCounters[userId]!.entries) {
      final operation = entry.key;
      final count = entry.value.values.fold(0, (sum, c) => sum + c);
      final limit = _rateLimits[operation];

      userOps[operation] = {
        'currentCount': count,
        'maxCount': limit?.maxCount ?? 0,
        'remaining': (limit?.maxCount ?? 0) - count,
        'isLimited': limit != null && count >= limit.maxCount,
      };
    }

    return {
      'status': 'active',
      'operations': userOps,
    };
  }

  /// Reset rate limits para un usuario (admin)
  void resetUserLimits(String userId) {
    _userCounters.remove(userId);
    _lastMessageTime.remove(userId);
    ReleaseLogger.info('Rate limits reseteados para usuario $userId', tag: 'RateLimit');
  }

  /// Reset todas las métricas (admin)
  void resetAllMetrics() {
    _userCounters.clear();
    _lastMessageTime.clear();
    _totalBlocks = 0;
    _totalRequests = 0;
    ReleaseLogger.info('Todas las métricas de rate limiting reseteadas', tag: 'RateLimit');
  }

  /// Limpiar datos antiguos (mantenimiento)
  Future<void> performMaintenance() async {
    final cutoffTime = DateTime.now().subtract(Duration(hours: 24));

    for (final userId in _userCounters.keys.toList()) {
      for (final operation in _userCounters[userId]!.keys.toList()) {
        _userCounters[userId]![operation]!.removeWhere(
          (time, count) => time.isBefore(cutoffTime),
        );

        if (_userCounters[userId]![operation]!.isEmpty) {
          _userCounters[userId]!.remove(operation);
        }
      }

      if (_userCounters[userId]!.isEmpty) {
        _userCounters.remove(userId);
      }
    }

    // Limpiar throttling data antigua
    _lastMessageTime.removeWhere(
      (userId, time) => DateTime.now().difference(time) > Duration(minutes: 5),
    );

    ReleaseLogger.info('Mantenimiento de rate limiting completado', tag: 'RateLimit');
  }
}

/// Configuración de rate limit para una operación
class RateLimit {
  final int maxCount;
  final Duration windowDuration;

  const RateLimit({
    required this.maxCount,
    required this.windowDuration,
  });

  @override
  String toString() {
    return 'RateLimit($maxCount per ${windowDuration.inMinutes}min)';
  }
}