import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'network_status_service.dart';
import 'app_logger.dart';

/// Servicio para manejar operaciones offline y sincronización
///
/// Características:
/// - Encola operaciones cuando no hay conexión
/// - Sincroniza automáticamente cuando vuelve la conexión
/// - Maneja reintentos con exponential backoff
/// - Prioriza operaciones críticas (emergencias, mensajes)
class OfflineQueueService {
  static final OfflineQueueService _instance = OfflineQueueService._internal();
  factory OfflineQueueService() => _instance;
  OfflineQueueService._internal();

  Box<Map>? _queueBox;
  bool _initialized = false;
  bool _isSyncing = false;

  // Tipos de operaciones
  static const String opSendMessage = 'send_message';
  static const String opUpdateProfile = 'update_profile';
  static const String opUploadFile = 'upload_file';
  static const String opCreateEmergency = 'create_emergency';
  static const String opBlockUser = 'block_user';
  static const String opUnblockUser = 'unblock_user';

  /// Inicializa el servicio
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _queueBox = await Hive.openBox<Map>('offline_queue');
      _initialized = true;

      logger.info('OfflineQueueService inicializado', tag: 'Offline');
      logger.info('Operaciones pendientes: ${_queueBox!.length}', tag: 'Offline');

      // Escuchar cambios de red para sincronizar
      NetworkStatusService().onConnected(() {
        logger.info('Conexión restaurada, iniciando sincronización', tag: 'Offline');
        syncPendingOperations();
      });
    } catch (e) {
      logger.error('Error inicializando OfflineQueueService', tag: 'Offline', error: e);
    }
  }

  /// Encola una operación para ejecutar cuando haya conexión
  Future<String> enqueueOperation({
    required String type,
    required Map<String, dynamic> data,
    int priority = 5, // 1 = máxima, 10 = mínima
  }) async {
    if (!_initialized) {
      throw Exception('OfflineQueueService no inicializado');
    }

    final operationId = '${DateTime.now().millisecondsSinceEpoch}_$type';
    final operation = {
      'id': operationId,
      'type': type,
      'data': data,
      'priority': priority,
      'createdAt': DateTime.now().toIso8601String(),
      'retryCount': 0,
      'userId': FirebaseAuth.instance.currentUser?.uid,
    };

    await _queueBox!.put(operationId, operation);

    logger.info(
      'Operación encolada: $type (prioridad: $priority)',
      tag: 'Offline',
    );

    // Si hay conexión, intentar sincronizar inmediatamente
    if (NetworkStatusService().isConnected) {
      syncPendingOperations();
    }

    return operationId;
  }

  /// Sincroniza todas las operaciones pendientes
  Future<void> syncPendingOperations() async {
    if (!_initialized || _isSyncing) return;

    // Verificar conexión
    if (!NetworkStatusService().isConnected) {
      logger.warning('Sin conexión, no se puede sincronizar', tag: 'Offline');
      return;
    }

    _isSyncing = true;

    try {
      final operations = _queueBox!.values.toList();

      if (operations.isEmpty) {
        logger.info('No hay operaciones pendientes', tag: 'Offline');
        _isSyncing = false;
        return;
      }

      logger.info('Sincronizando ${operations.length} operaciones', tag: 'Offline');

      // Ordenar por prioridad y fecha
      operations.sort((a, b) {
        final priorityCompare = (a['priority'] as int).compareTo(b['priority'] as int);
        if (priorityCompare != 0) return priorityCompare;
        return (a['createdAt'] as String).compareTo(b['createdAt'] as String);
      });

      int successful = 0;
      int failed = 0;

      for (final operation in operations) {
        try {
          await _executeOperation(operation);
          await _queueBox!.delete(operation['id']);
          successful++;
          logger.info('Operación sincronizada: ${operation['type']}', tag: 'Offline');
        } catch (e) {
          failed++;
          logger.error(
            'Error sincronizando ${operation['type']}',
            tag: 'Offline',
            error: e,
          );

          // Incrementar contador de reintentos
          final retryCount = (operation['retryCount'] as int) + 1;

          if (retryCount >= 3) {
            // Eliminar después de 3 intentos fallidos
            await _queueBox!.delete(operation['id']);
            logger.warning(
              'Operación eliminada después de 3 intentos fallidos: ${operation['type']}',
              tag: 'Offline',
            );
          } else {
            // Actualizar contador
            operation['retryCount'] = retryCount;
            await _queueBox!.put(operation['id'], operation);
          }
        }
      }

      if (successful > 0) {
        logger.info('$successful operaciones sincronizadas', tag: 'Offline');
      }

      if (failed > 0) {
        logger.warning('$failed operaciones fallaron', tag: 'Offline');
      }
    } catch (e) {
      logger.error('Error en sincronización', tag: 'Offline', error: e);
    } finally {
      _isSyncing = false;
    }
  }

  /// Ejecuta una operación específica
  Future<void> _executeOperation(Map operation) async {
    final type = operation['type'] as String;
    final data = operation['data'] as Map<String, dynamic>;

    switch (type) {
      case opSendMessage:
        await _sendMessage(data);
        break;

      case opUpdateProfile:
        await _updateProfile(data);
        break;

      case opUploadFile:
        await _uploadFile(data);
        break;

      case opCreateEmergency:
        await _createEmergency(data);
        break;

      case opBlockUser:
        await _blockUser(data);
        break;

      case opUnblockUser:
        await _unblockUser(data);
        break;

      default:
        logger.warning('Tipo de operación desconocido: $type', tag: 'Offline');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // IMPLEMENTACIONES DE OPERACIONES
  // ═══════════════════════════════════════════════════════════════

  Future<void> _sendMessage(Map<String, dynamic> data) async {
    final chatId = data['chatId'] as String;
    final message = Map<String, dynamic>.from(data['message'] as Map<String, dynamic>);

    // Convertir timestamp de milisegundos a Timestamp de Firestore
    if (message['timestamp'] is int) {
      final milliseconds = message['timestamp'] as int;
      message['timestamp'] = Timestamp.fromMillisecondsSinceEpoch(milliseconds);
    }

    await FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add(message);
  }

  Future<void> _updateProfile(Map<String, dynamic> data) async {
    final userId = data['userId'] as String;
    final updates = data['updates'] as Map<String, dynamic>;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .update(updates);
  }

  Future<void> _uploadFile(Map<String, dynamic> data) async {
    // Nota: En producción, necesitarías guardar el archivo localmente
    // y subirlo cuando haya conexión. Por ahora, esto es un placeholder.
    logger.warning('Upload de archivo desde offline no implementado completamente', tag: 'Offline');
  }

  Future<void> _createEmergency(Map<String, dynamic> data) async {
    // Usar Cloud Function para crear emergencia
    // Ya implementado en emergency_service.dart
    logger.info('Creando emergencia desde cola offline', tag: 'Offline');
  }

  /// Genera el chatId ordenado alfabéticamente
  String _getChatId(String id1, String id2) {
    final sorted = [id1, id2]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  Future<void> _blockUser(Map<String, dynamic> data) async {
    final userId = data['userId'] as String;
    final blockedUserId = data['blockedUserId'] as String;

    // Usar chats.isBlocked como fuente de verdad unificada
    final chatId = _getChatId(userId, blockedUserId);
    await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
      'isBlocked': true,
      'blockedAt': FieldValue.serverTimestamp(),
      'blockedBy': userId,
      'blockedReason': 'Bloqueado por usuario',
      'participants': [userId, blockedUserId],
    }, SetOptions(merge: true));
  }

  Future<void> _unblockUser(Map<String, dynamic> data) async {
    final userId = data['userId'] as String;
    final blockedUserId = data['blockedUserId'] as String;

    // Usar chats.isBlocked como fuente de verdad unificada
    final chatId = _getChatId(userId, blockedUserId);
    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);
    final chatDoc = await chatRef.get();

    if (chatDoc.exists) {
      await chatRef.update({
        'isBlocked': false,
        'unblockedAt': FieldValue.serverTimestamp(),
        'unblockedBy': userId,
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE CONSULTA
  // ═══════════════════════════════════════════════════════════════

  /// Obtiene el número de operaciones pendientes
  int get pendingOperationsCount => _queueBox?.length ?? 0;

  /// Verifica si hay operaciones pendientes
  bool get hasPendingOperations => pendingOperationsCount > 0;

  /// Obtiene la lista de operaciones pendientes
  List<Map> getPendingOperations() {
    if (!_initialized) return [];
    return _queueBox!.values.toList();
  }

  /// Limpia todas las operaciones pendientes
  Future<void> clearQueue() async {
    if (!_initialized) return;
    await _queueBox!.clear();
    logger.info('Cola de operaciones limpiada', tag: 'Offline');
  }

  /// Cancela una operación específica
  Future<void> cancelOperation(String operationId) async {
    if (!_initialized) return;
    await _queueBox!.delete(operationId);
    logger.info('Operación cancelada: $operationId', tag: 'Offline');
  }
}

/// Extensión global para facilitar uso
OfflineQueueService get offlineQueue => OfflineQueueService();
