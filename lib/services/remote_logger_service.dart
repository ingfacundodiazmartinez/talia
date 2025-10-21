import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Servicio para enviar logs al backend para debugging en producción
///
/// Solo envía logs por HTTP si el usuario tiene debug: true en Firestore
class RemoteLoggerService {
  static final RemoteLoggerService _instance = RemoteLoggerService._internal();
  factory RemoteLoggerService() => _instance;
  RemoteLoggerService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Estado de debug del usuario (cached)
  bool? _isDebugEnabled;
  String? _cachedUserId;
  Timer? _debugCheckTimer;

  // Cola de logs pendientes de enviar
  final List<Map<String, dynamic>> _pendingLogs = [];
  Timer? _batchSendTimer;

  // URL del backoffice para enviar logs
  static const String _backendUrl = 'https://talia-backoffice-858375352661.us-central1.run.app/api/v1/app-logs';

  /// Inicializar el servicio
  Future<void> initialize() async {
    try {
      // Verificar estado de debug del usuario actual
      await _checkDebugStatus();

      // Revisar cada 5 minutos si cambió el estado de debug
      _debugCheckTimer = Timer.periodic(Duration(minutes: 5), (_) {
        _checkDebugStatus();
      });

      // Enviar logs en batch cada 20 segundos
      _batchSendTimer = Timer.periodic(Duration(seconds: 20), (_) {
        _sendPendingLogs();
      });

      // NO sobrescribir debugPrint - causa loop infinito
      // TODO: Si queremos capturar todos los debugPrint, necesitamos otra estrategia
      // _overrideDebugPrint();

      developer.log('✅ RemoteLoggerService inicializado', name: 'RemoteLogger');

      // ENVIAR LOG DE PRUEBA INMEDIATO para verificar conectividad
      log('🧪 RemoteLoggerService TEST - App iniciada', level: 'INFO');

      // Enviar inmediatamente para diagnóstico (sin esperar 20 segundos)
      Future.delayed(Duration(seconds: 3), () {
        _sendPendingLogs();
      });
    } catch (e) {
      developer.log('❌ Error inicializando RemoteLoggerService: $e', name: 'RemoteLogger');
    }
  }

  /// Verificar si el usuario tiene debug habilitado
  Future<void> _checkDebugStatus() async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        developer.log('[RemoteLogger] ⚠️ No hay usuario autenticado, debug deshabilitado', name: 'RemoteLogger');
        _isDebugEnabled = false;
        _cachedUserId = null;
        return;
      }

      developer.log('[RemoteLogger] 🔍 Verificando debug status para usuario ${currentUser.uid}', name: 'RemoteLogger');

      // Si cambió el usuario, resetear cache
      if (_cachedUserId != currentUser.uid) {
        developer.log('[RemoteLogger] 👤 Usuario cambió, reseteando cache', name: 'RemoteLogger');
        _isDebugEnabled = null;
        _cachedUserId = currentUser.uid;
      }

      // Obtener estado de debug desde Firestore
      final userDoc = await _firestore.collection('users').doc(currentUser.uid).get();
      final userData = userDoc.data();

      developer.log('[RemoteLogger] 📄 Documento Firestore existe: ${userDoc.exists}', name: 'RemoteLogger');
      developer.log('[RemoteLogger] 📄 Campo debug: ${userData?['debug']}', name: 'RemoteLogger');

      _isDebugEnabled = userData?['debug'] == true;

      if (_isDebugEnabled == true) {
        developer.log('[RemoteLogger] 🐛 ✅ Debug mode ENABLED para usuario ${currentUser.uid}', name: 'RemoteLogger');
        developer.log('🐛 Debug mode ENABLED - Los logs se enviarán a $_backendUrl', name: 'RemoteLogger');
      } else {
        developer.log('[RemoteLogger] ⚠️ Debug mode DISABLED para usuario ${currentUser.uid}', name: 'RemoteLogger');
      }
    } catch (e) {
      developer.log('[RemoteLogger] ❌ Error verificando debug status: $e', name: 'RemoteLogger');
      _isDebugEnabled = false;
    }
  }

  /// Sobrescribir debugPrint global
  void _overrideDebugPrint() {
    // Guardar la función original
    final originalDebugPrint = debugPrint;

    // Sobrescribir con nuestra versión
    debugPrint = (String? message, {int? wrapWidth}) {
      // Llamar a la original para mantener el comportamiento normal
      originalDebugPrint?.call(message, wrapWidth: wrapWidth);

      // Enviar al backend si debug está habilitado
      if (message != null) {
        log(message, level: 'DEBUG');
      }
    };
  }

  /// Método principal para loggear
  void log(
    String message, {
    String level = 'INFO',
    Map<String, dynamic>? extraData,
    StackTrace? stackTrace,
  }) {
    // Siempre imprimir en consola
    final timestamp = DateTime.now().toIso8601String();
    final logPrefix = _getLogPrefix(level);
    debugPrint('$logPrefix [$timestamp] $message');

    // Solo enviar al backend si debug está habilitado
    if (_isDebugEnabled != true) {
      return;
    }

    // Agregar a la cola de logs pendientes (formato del backend)
    _pendingLogs.add({
      'timestamp': timestamp,
      'level': level.toUpperCase(), // DEBUG, INFO, WARNING, ERROR, FATAL
      'message': message,
      'userId': _cachedUserId,
      'metadata': extraData,
      'stackTrace': stackTrace?.toString(),
      'platform': _getPlatform(), // IOS, ANDROID, WEB, UNKNOWN
    });

    developer.log('[RemoteLogger] 📝 Log agregado a cola (${_pendingLogs.length} pendientes)', name: 'RemoteLogger');

    // Si hay 1000 logs, enviar inmediatamente
    if (_pendingLogs.length >= 1000) {
      developer.log('[RemoteLogger] 🚨 Cola llena (1000 logs), enviando inmediatamente', name: 'RemoteLogger');
      _sendPendingLogs();
    }
  }

  /// Obtener prefijo del log según el nivel
  String _getLogPrefix(String level) {
    switch (level.toUpperCase()) {
      case 'ERROR':
        return '❌';
      case 'WARNING':
        return '⚠️';
      case 'INFO':
        return 'ℹ️';
      case 'DEBUG':
        return '🐛';
      case 'SUCCESS':
        return '✅';
      default:
        return '📝';
    }
  }

  /// Obtener plataforma actual (enum AppPlatform del backend)
  String _getPlatform() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'IOS';
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      return 'ANDROID';
    } else if (kIsWeb) {
      return 'WEB';
    } else {
      return 'UNKNOWN';
    }
  }

  /// Enviar logs pendientes al backend
  Future<void> _sendPendingLogs() async {
    if (_pendingLogs.isEmpty) {
      return;
    }

    // Solo enviar si debug está habilitado
    if (_isDebugEnabled != true) {
      developer.log('[RemoteLogger] ⚠️ Debug deshabilitado, limpiando ${_pendingLogs.length} logs', name: 'RemoteLogger');
      _pendingLogs.clear();
      return;
    }

    // Copiar y limpiar la cola
    final logsToSend = List<Map<String, dynamic>>.from(_pendingLogs);
    _pendingLogs.clear();

    developer.log('[RemoteLogger] 📤 Enviando ${logsToSend.length} logs a $_backendUrl', name: 'RemoteLogger');

    try {
      final response = await http.post(
        Uri.parse(_backendUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(logsToSend), // Enviar array directo
      ).timeout(Duration(seconds: 5));

      developer.log('[RemoteLogger] 📬 Response status: ${response.statusCode}', name: 'RemoteLogger');

      if (response.statusCode != 200 && response.statusCode != 202) {
        developer.log('[RemoteLogger] ⚠️ Error enviando logs: ${response.statusCode} - ${response.body}', name: 'RemoteLogger');
        // Re-agregar logs a la cola si falló (máximo 500 para evitar memoria infinita)
        if (_pendingLogs.length < 500) {
          _pendingLogs.addAll(logsToSend);
        }
      } else {
        developer.log('[RemoteLogger] ✅ Logs enviados exitosamente (${logsToSend.length} logs)', name: 'RemoteLogger');
      }
    } catch (e, stack) {
      developer.log('[RemoteLogger] ❌ Error en HTTP request: $e', name: 'RemoteLogger');
      developer.log('[RemoteLogger] Stack trace: $stack', name: 'RemoteLogger');
      // Re-agregar logs a la cola si falló (máximo 500 para evitar memoria infinita)
      if (_pendingLogs.length < 500) {
        _pendingLogs.addAll(logsToSend);
      }
    }
  }

  /// Limpiar recursos
  void dispose() {
    _debugCheckTimer?.cancel();
    _batchSendTimer?.cancel();
    _sendPendingLogs(); // Enviar logs pendientes antes de cerrar
  }
}

/// Instancia global del logger para acceso rápido
final appLogger = RemoteLoggerService();
