import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// Servicio para exportación de datos personales (GDPR/CCPA)
///
/// Ofrece dos tipos de export:
/// - Rápido: Datos básicos en segundos (perfil, configuraciones, metadata)
/// - Completo: Todos los datos incluyendo mensajes y archivos (vía Cloud Function)
class DataExportService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  DataExportService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  String? get _currentUserId => _auth.currentUser?.uid;

  /// Export rápido: Solo datos ligeros (< 5 segundos)
  ///
  /// Incluye:
  /// - Perfil completo
  /// - Configuraciones de privacidad
  /// - Configuraciones de notificaciones
  /// - Metadata de mensajes (sin contenido)
  /// - Metadata de ubicaciones
  /// - Contactos aprobados
  /// - Notificaciones recientes
  Future<QuickExportResult> performQuickExport() async {
    if (_currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final Map<String, dynamic> exportData = {
      'export_info': {
        'type': 'quick_export',
        'version': '2.0',
        'exported_at': DateTime.now().toIso8601String(),
        'user_id': _currentUserId,
      },
    };

    // Recopilar datos en paralelo
    await Future.wait([
      _collectProfile(exportData),
      _collectSettings(exportData),
      _collectNotificationPreferences(exportData),
      _collectMessageMetadata(exportData),
      _collectLocationMetadata(exportData),
      _collectContacts(exportData),
      _collectRecentNotifications(exportData),
    ]);

    // Crear archivos
    final jsonFile = await _createJsonFile(exportData, 'quick');
    final readmeFile = await _createReadmeFile('quick');

    return QuickExportResult(
      jsonFile: jsonFile,
      readmeFile: readmeFile,
      dataSummary: _createDataSummary(exportData),
    );
  }

  /// Solicita export completo (procesado por Cloud Function)
  ///
  /// Incluye todo lo del export rápido más:
  /// - Contenido completo de mensajes
  /// - Archivos multimedia (imágenes, audios, videos)
  /// - Ubicaciones completas con timestamps
  /// - Historial completo de notificaciones
  /// - Logs de actividad
  Future<String> requestFullExport() async {
    if (_currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    // Crear solicitud en Firestore
    final requestDoc = await _firestore.collection('data_export_requests').add({
      'userId': _currentUserId,
      'type': 'full_export',
      'status': 'pending',
      'requestedAt': FieldValue.serverTimestamp(),
      'includeMedia': true,
      'includeMessages': true,
      'includeLocations': true,
    });

    // La Cloud Function procesará esta solicitud y enviará una notificación
    return requestDoc.id;
  }

  /// Obtiene el estado de una solicitud de export completo
  Future<ExportRequest?> getExportRequestStatus(String requestId) async {
    final doc = await _firestore
        .collection('data_export_requests')
        .doc(requestId)
        .get();

    if (!doc.exists) return null;

    final data = doc.data()!;
    return ExportRequest.fromFirestore(doc.id, data);
  }

  /// Obtiene todas las solicitudes de export del usuario
  Stream<List<ExportRequest>> getUserExportRequests() {
    if (_currentUserId == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('data_export_requests')
        .where('userId', isEqualTo: _currentUserId)
        .orderBy('requestedAt', descending: true)
        .limit(10)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => ExportRequest.fromFirestore(doc.id, doc.data()))
          .toList();
    });
  }

  // ============================================================================
  // ENCRYPTED CACHE EXPORT/IMPORT (Para migración entre dispositivos)
  // ============================================================================

  static const String _cacheBoxName = 'messages_cache';
  static const String _backupVersion = '1.0.0';

  /// Obtener el directorio de backups (crea si no existe)
  Future<Directory> _getBackupsDirectory() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final backupsDir = Directory('${appDocDir.path}/Talia/Backups');

    if (!await backupsDir.exists()) {
      await backupsDir.create(recursive: true);
      print('📁 [CacheExport] Creado directorio de backups: ${backupsDir.path}');
    }

    return backupsDir;
  }

  /// Exportar cache local encriptado para migración entre dispositivos
  ///
  /// [password] - Contraseña para encriptar los datos
  /// [onProgress] - Callback para reportar progreso (0.0 a 1.0)
  ///
  /// Returns: Ruta del archivo generado o null si hay error
  Future<String?> exportEncryptedCache({
    required String password,
    Function(double progress)? onProgress,
  }) async {
    try {
      if (_currentUserId == null) {
        throw Exception('Usuario no autenticado');
      }

      onProgress?.call(0.1);
      print('📦 [CacheExport] Iniciando exportación de cache...');

      // 1. Obtener datos del cache
      final messagesBox = await Hive.openBox(_cacheBoxName);
      final allData = <String, dynamic>{};

      for (final key in messagesBox.keys) {
        // Skip metadata keys
        if (key.toString().startsWith('_')) continue;

        final value = messagesBox.get(key);
        if (value != null) {
          allData[key.toString()] = value;
        }
      }

      onProgress?.call(0.3);
      print('📊 [CacheExport] Recopilados ${allData.length} mensajes del cache');

      // 2. Crear estructura de exportación con metadata
      final exportData = {
        'version': _backupVersion,
        'exportDate': DateTime.now().toIso8601String(),
        'userId': _currentUserId,
        'messageCount': allData.length,
        'data': allData,
      };

      onProgress?.call(0.5);

      // 3. Convertir a JSON
      final jsonData = json.encode(exportData);
      final jsonBytes = utf8.encode(jsonData);
      print('💾 [CacheExport] Tamaño del backup: ${(jsonBytes.length / 1024 / 1024).toStringAsFixed(2)} MB');

      onProgress?.call(0.6);

      // 4. Encriptar datos con AES-256-GCM
      final encryptedData = _encryptData(jsonBytes, password);

      onProgress?.call(0.8);

      // 5. Guardar archivo en carpeta fija
      final backupsDir = await _getBackupsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'talia_backup_$timestamp.talia';
      final filePath = '${backupsDir.path}/$fileName';

      final file = File(filePath);
      await file.writeAsBytes(encryptedData);

      onProgress?.call(1.0);
      print('✅ [CacheExport] Backup creado exitosamente: $filePath');

      return filePath;
    } catch (e) {
      print('❌ [CacheExport] Error exportando cache: $e');
      return null;
    }
  }

  /// Importar cache desde archivo encriptado
  ///
  /// [filePath] - Ruta del archivo .talia
  /// [password] - Contraseña para desencriptar
  /// [onProgress] - Callback para reportar progreso (0.0 a 1.0)
  ///
  /// Returns: true si la importación fue exitosa
  Future<bool> importEncryptedCache({
    required String filePath,
    required String password,
    Function(double progress)? onProgress,
  }) async {
    try {
      if (_currentUserId == null) {
        throw Exception('Usuario no autenticado');
      }

      onProgress?.call(0.1);
      print('📥 [CacheImport] Iniciando importación desde: $filePath');

      // 1. Leer archivo
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Archivo no encontrado');
      }

      final encryptedData = await file.readAsBytes();
      onProgress?.call(0.2);

      // 2. Desencriptar
      final decryptedBytes = _decryptData(encryptedData, password);
      if (decryptedBytes == null) {
        throw Exception('Contraseña incorrecta o archivo corrupto');
      }

      onProgress?.call(0.4);

      // 3. Parsear JSON
      final jsonString = utf8.decode(decryptedBytes);
      final Map<String, dynamic> importData = json.decode(jsonString);

      // 4. Validar estructura
      if (importData['version'] == null || importData['data'] == null) {
        throw Exception('Formato de backup inválido');
      }

      onProgress?.call(0.5);
      print('📊 [CacheImport] Versión del backup: ${importData['version']}');
      print('📊 [CacheImport] Fecha de exportación: ${importData['exportDate']}');
      print('📊 [CacheImport] Mensajes a importar: ${importData['messageCount']}');

      // 5. Verificar que el backup sea del mismo usuario
      if (importData['userId'] != _currentUserId) {
        print('⚠️ [CacheImport] Advertencia: El backup es de un usuario diferente');
        print('   Backup userId: ${importData['userId']}');
        print('   Current userId: $_currentUserId');
      }

      onProgress?.call(0.6);

      // 6. Importar datos al cache
      final messagesBox = await Hive.openBox(_cacheBoxName);
      final data = importData['data'] as Map<String, dynamic>;

      int importedCount = 0;
      final totalItems = data.length;

      for (final entry in data.entries) {
        await messagesBox.put(entry.key, entry.value);
        importedCount++;

        // Reportar progreso durante la importación
        if (importedCount % 100 == 0) {
          final progress = 0.6 + (0.4 * (importedCount / totalItems));
          onProgress?.call(progress);
        }
      }

      onProgress?.call(1.0);
      print('✅ [CacheImport] Importados $importedCount mensajes correctamente');

      return true;
    } catch (e) {
      print('❌ [CacheImport] Error importando cache: $e');
      return false;
    }
  }

  /// Listar archivos de backup disponibles
  Future<List<BackupFileInfo>> listAvailableBackups() async {
    try {
      final backupsDir = await _getBackupsDirectory();
      final files = backupsDir
          .listSync()
          .where((file) => file.path.endsWith('.talia'))
          .map((file) => File(file.path))
          .toList();

      // Ordenar por fecha de modificación (más reciente primero)
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

      final backupInfoList = <BackupFileInfo>[];
      for (final file in files) {
        final stat = file.statSync();
        final fileName = file.path.split('/').last;

        backupInfoList.add(BackupFileInfo(
          filePath: file.path,
          fileName: fileName,
          fileSize: stat.size,
          lastModified: stat.modified,
        ));
      }

      print('📋 [CacheExport] Encontrados ${backupInfoList.length} backups');
      return backupInfoList;
    } catch (e) {
      print('❌ [CacheExport] Error listando backups: $e');
      return [];
    }
  }

  /// Compartir archivo de backup
  Future<void> shareBackupFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await Share.shareXFiles(
          [XFile(filePath)],
          subject: 'Talia Backup',
          text: 'Backup encriptado de Talia - Guarda este archivo de forma segura',
        );
        print('📤 [CacheExport] Compartiendo archivo: $filePath');
      }
    } catch (e) {
      print('❌ [CacheExport] Error compartiendo archivo: $e');
    }
  }

  /// Obtener información de un archivo de backup sin desencriptarlo completamente
  Future<Map<String, dynamic>?> getBackupInfo(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      final fileSize = await file.length();
      final lastModified = await file.lastModified();

      return {
        'filePath': filePath,
        'fileName': filePath.split('/').last,
        'fileSize': fileSize,
        'fileSizeMB': (fileSize / 1024 / 1024).toStringAsFixed(2),
        'lastModified': lastModified.toIso8601String(),
      };
    } catch (e) {
      print('❌ [CacheExport] Error obteniendo info del backup: $e');
      return null;
    }
  }

  /// Eliminar archivo de backup
  Future<bool> deleteBackupFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        print('🗑️ [CacheExport] Backup eliminado: $filePath');
        return true;
      }
      return false;
    } catch (e) {
      print('❌ [CacheExport] Error eliminando backup: $e');
      return false;
    }
  }

  // ==========================================================================
  // MÉTODOS DE ENCRIPTACIÓN
  // ==========================================================================

  /// Encriptar datos usando AES-256-GCM con password
  List<int> _encryptData(List<int> data, String password) {
    // Generar salt aleatorio
    final salt = encrypt_lib.IV.fromSecureRandom(16);

    // Derivar key desde password usando PBKDF2
    final key = _deriveKeyFromPassword(password, salt.bytes);

    // Generar IV aleatorio para AES
    final iv = encrypt_lib.IV.fromSecureRandom(16);

    // Crear encriptador AES-256-GCM
    final encrypter = encrypt_lib.Encrypter(
      encrypt_lib.AES(key, mode: encrypt_lib.AESMode.gcm),
    );

    // Encriptar
    final encrypted = encrypter.encryptBytes(data, iv: iv);

    // Estructura del archivo: [salt(16)] [iv(16)] [encrypted_data]
    final result = <int>[];
    result.addAll(salt.bytes);
    result.addAll(iv.bytes);
    result.addAll(encrypted.bytes);

    return result;
  }

  /// Desencriptar datos usando AES-256-GCM con password
  List<int>? _decryptData(List<int> encryptedData, String password) {
    try {
      // Extraer salt, iv y datos encriptados
      if (encryptedData.length < 32) {
        throw Exception('Datos encriptados inválidos');
      }

      final salt = encryptedData.sublist(0, 16);
      final iv = encrypt_lib.IV(Uint8List.fromList(encryptedData.sublist(16, 32)));
      final encrypted = encryptedData.sublist(32);

      // Derivar key desde password usando el mismo salt
      final key = _deriveKeyFromPassword(password, salt);

      // Crear desencriptador
      final encrypter = encrypt_lib.Encrypter(
        encrypt_lib.AES(key, mode: encrypt_lib.AESMode.gcm),
      );

      // Desencriptar
      final decrypted = encrypter.decryptBytes(
        encrypt_lib.Encrypted(Uint8List.fromList(encrypted)),
        iv: iv,
      );

      return decrypted;
    } catch (e) {
      print('❌ [Decrypt] Error desencriptando: $e');
      return null;
    }
  }

  /// Derivar key de 256 bits desde password usando PBKDF2
  encrypt_lib.Key _deriveKeyFromPassword(String password, List<int> salt) {
    const iterations = 10000;
    final passwordBytes = utf8.encode(password);

    // PBKDF2 con SHA-256
    final pbkdf2 = _Pbkdf2(
      iterations: iterations,
      bits: 256,
    );

    final keyBytes = pbkdf2.deriveKey(
      secretKey: passwordBytes,
      nonce: salt,
    );

    return encrypt_lib.Key(Uint8List.fromList(keyBytes));
  }

  // ============================================================================
  // Métodos de recopilación de datos (privados)
  // ============================================================================

  Future<void> _collectProfile(Map<String, dynamic> exportData) async {
    try {
      final userDoc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .get();

      if (userDoc.exists) {
        final data = Map<String, dynamic>.from(userDoc.data()!);

        // Remover datos sensibles del sistema
        data.remove('fcmToken');
        data.remove('deviceTokens');

        // Convertir Timestamps a strings
        data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate().toIso8601String();
        data['updatedAt'] = (data['updatedAt'] as Timestamp?)?.toDate().toIso8601String();

        exportData['profile'] = data;
      }
    } catch (e) {
      exportData['profile'] = {'error': 'Error recopilando perfil: $e'};
    }
  }

  Future<void> _collectSettings(Map<String, dynamic> exportData) async {
    try {
      final userDoc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;
        exportData['privacy_settings'] = {
          'twoFactorEnabled': data['twoFactorEnabled'] ?? false,
          'showOnlineStatus': data['showOnlineStatus'] ?? true,
          'allowScreenshots': data['allowScreenshots'] ?? false,
        };
      }
    } catch (e) {
      exportData['privacy_settings'] = {'error': 'Error recopilando configuraciones: $e'};
    }
  }

  Future<void> _collectNotificationPreferences(Map<String, dynamic> exportData) async {
    try {
      final doc = await _firestore
          .collection('notification_preferences')
          .doc(_currentUserId)
          .get();

      if (doc.exists) {
        exportData['notification_preferences'] = doc.data();
      } else {
        exportData['notification_preferences'] = {'note': 'Usando valores por defecto'};
      }
    } catch (e) {
      exportData['notification_preferences'] = {'error': 'Error recopilando preferencias: $e'};
    }
  }

  Future<void> _collectMessageMetadata(Map<String, dynamic> exportData) async {
    try {
      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: _currentUserId)
          .get();

      final chatsMetadata = <Map<String, dynamic>>[];
      for (var chatDoc in chatsQuery.docs) {
        final chatData = chatDoc.data();

        // Contar mensajes
        final messagesCount = await chatDoc.reference
            .collection('messages')
            .count()
            .get();

        chatsMetadata.add({
          'chatId': chatDoc.id,
          'participants': chatData['participants'],
          'createdAt': (chatData['createdAt'] as Timestamp?)?.toDate().toIso8601String(),
          'lastMessageAt': (chatData['lastMessageAt'] as Timestamp?)?.toDate().toIso8601String(),
          'totalMessages': messagesCount.count,
          'note': 'El contenido completo de mensajes está disponible en Export Completo',
        });
      }

      exportData['messages_metadata'] = {
        'totalChats': chatsMetadata.length,
        'chats': chatsMetadata,
      };
    } catch (e) {
      exportData['messages_metadata'] = {'error': 'Error recopilando metadata de mensajes: $e'};
    }
  }

  Future<void> _collectLocationMetadata(Map<String, dynamic> exportData) async {
    try {
      final userDoc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .get();

      if (userDoc.exists) {
        final data = userDoc.data()!;

        exportData['location_metadata'] = {
          'hasSharedLocation': data['lastLocation'] != null,
          'lastLocationSharedAt': data['lastLocationUpdate'] != null
              ? (data['lastLocationUpdate'] as Timestamp).toDate().toIso8601String()
              : null,
          'note': 'El historial completo de ubicaciones está disponible en Export Completo',
        };
      }
    } catch (e) {
      exportData['location_metadata'] = {'error': 'Error recopilando metadata de ubicaciones: $e'};
    }
  }

  Future<void> _collectContacts(Map<String, dynamic> exportData) async {
    try {
      final contactsQuery = await _firestore
          .collection('contacts')
          .where('users', arrayContains: _currentUserId)
          .get();

      final contacts = <Map<String, dynamic>>[];
      for (var doc in contactsQuery.docs) {
        final data = doc.data();
        contacts.add({
          'contactId': doc.id,
          'users': data['users'],
          'status': data['status'],
          'createdAt': (data['createdAt'] as Timestamp?)?.toDate().toIso8601String(),
        });
      }

      exportData['contacts'] = {
        'totalContacts': contacts.length,
        'contacts': contacts,
      };
    } catch (e) {
      exportData['contacts'] = {'error': 'Error recopilando contactos: $e'};
    }
  }

  Future<void> _collectRecentNotifications(Map<String, dynamic> exportData) async {
    try {
      final notificationsQuery = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: _currentUserId)
          .orderBy('timestamp', descending: true)
          .limit(50)
          .get();

      final notifications = notificationsQuery.docs.map((doc) {
        final data = doc.data();
        return {
          'notificationId': doc.id,
          'type': data['type'],
          'title': data['title'],
          'body': data['body'],
          'timestamp': (data['timestamp'] as Timestamp?)?.toDate().toIso8601String(),
          'read': data['read'] ?? false,
        };
      }).toList();

      exportData['recent_notifications'] = {
        'count': notifications.length,
        'notifications': notifications,
        'note': 'Mostrando las últimas 50 notificaciones. El historial completo está en Export Completo',
      };
    } catch (e) {
      exportData['recent_notifications'] = {'error': 'Error recopilando notificaciones: $e'};
    }
  }

  Future<File> _createJsonFile(Map<String, dynamic> data, String type) async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'talia_${type}_export_$timestamp.json';
    final file = File('${directory.path}/$fileName');

    final jsonString = JsonEncoder.withIndent('  ').convert(data);
    await file.writeAsString(jsonString);

    return file;
  }

  Future<File> _createReadmeFile(String type) async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'README_$timestamp.txt';
    final file = File('${directory.path}/$fileName');

    final content = type == 'quick' ? _getQuickExportReadme() : _getFullExportReadme();
    await file.writeAsString(content);

    return file;
  }

  String _getQuickExportReadme() {
    return '''
════════════════════════════════════════════════════════════
TALIA - EXPORTACIÓN RÁPIDA DE DATOS PERSONALES
════════════════════════════════════════════════════════════

Fecha de exportación: ${DateTime.now().toString()}
Tipo: Export Rápido
Versión: 2.0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 CONTENIDO DE ESTE EXPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Este export incluye tus datos básicos y metadata:

✓ Perfil: Información personal y configuraciones
✓ Privacidad: Configuraciones de privacidad y seguridad
✓ Notificaciones: Preferencias de notificaciones
✓ Mensajes: Metadata de conversaciones (sin contenido)
✓ Ubicaciones: Metadata de ubicaciones compartidas
✓ Contactos: Lista de contactos aprobados
✓ Notificaciones: Últimas 50 notificaciones recibidas

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📦 ¿NECESITAS MÁS DATOS?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

El Export Completo incluye:
- Contenido completo de mensajes
- Archivos multimedia (imágenes, audios, videos)
- Historial completo de ubicaciones
- Todas las notificaciones
- Logs de actividad

Para solicitarlo:
Configuración → Privacidad y Seguridad → Descargar Mis Datos → Export Completo

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔒 INFORMACIÓN DE SEGURIDAD
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  Este archivo contiene información personal sensible
⚠️  No lo compartas con terceros
⚠️  Guárdalo en un lugar seguro
⚠️  Elimínalo cuando ya no lo necesites

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📜 CUMPLIMIENTO LEGAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Este export cumple con:
- GDPR (Reglamento General de Protección de Datos)
- CCPA (California Consumer Privacy Act)
- Derecho de portabilidad de datos

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💬 SOPORTE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

¿Preguntas sobre tu export?
Contacta a: support@talia.com

════════════════════════════════════════════════════════════
''';
  }

  String _getFullExportReadme() {
    return '''
[README para Export Completo - se generará en Cloud Function]
''';
  }

  Map<String, dynamic> _createDataSummary(Map<String, dynamic> exportData) {
    return {
      'totalSections': exportData.length - 1, // -1 por export_info
      'hasProfile': exportData.containsKey('profile'),
      'hasMessages': exportData.containsKey('messages_metadata'),
      'hasContacts': exportData.containsKey('contacts'),
      'hasNotifications': exportData.containsKey('recent_notifications'),
    };
  }
}

/// Resultado del export rápido
class QuickExportResult {
  final File jsonFile;
  final File readmeFile;
  final Map<String, dynamic> dataSummary;

  QuickExportResult({
    required this.jsonFile,
    required this.readmeFile,
    required this.dataSummary,
  });
}

/// Representa una solicitud de export completo
class ExportRequest {
  final String id;
  final String userId;
  final String type;
  final ExportStatus status;
  final DateTime requestedAt;
  final DateTime? completedAt;
  final String? downloadUrl;
  final DateTime? expiresAt;
  final String? error;

  ExportRequest({
    required this.id,
    required this.userId,
    required this.type,
    required this.status,
    required this.requestedAt,
    this.completedAt,
    this.downloadUrl,
    this.expiresAt,
    this.error,
  });

  factory ExportRequest.fromFirestore(String id, Map<String, dynamic> data) {
    return ExportRequest(
      id: id,
      userId: data['userId'] ?? '',
      type: data['type'] ?? 'full_export',
      status: _parseStatus(data['status']),
      requestedAt: (data['requestedAt'] as Timestamp).toDate(),
      completedAt: data['completedAt'] != null
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
      downloadUrl: data['downloadUrl'],
      expiresAt: data['expiresAt'] != null
          ? (data['expiresAt'] as Timestamp).toDate()
          : null,
      error: data['error'],
    );
  }

  static ExportStatus _parseStatus(String? status) {
    switch (status) {
      case 'pending':
        return ExportStatus.pending;
      case 'processing':
        return ExportStatus.processing;
      case 'completed':
        return ExportStatus.completed;
      case 'failed':
        return ExportStatus.failed;
      case 'expired':
        return ExportStatus.expired;
      default:
        return ExportStatus.pending;
    }
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  bool get canDownload {
    return status == ExportStatus.completed &&
           downloadUrl != null &&
           !isExpired;
  }
}

/// Estados posibles de una solicitud de export
enum ExportStatus {
  pending,      // Esperando procesamiento
  processing,   // En proceso
  completed,    // Completado y listo para descargar
  failed,       // Falló el procesamiento
  expired,      // Link de descarga expirado
}

/// Información de un archivo de backup
class BackupFileInfo {
  final String filePath;
  final String fileName;
  final int fileSize;
  final DateTime lastModified;

  BackupFileInfo({
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    required this.lastModified,
  });

  String get fileSizeMB => (fileSize / 1024 / 1024).toStringAsFixed(2);

  String get formattedDate {
    final now = DateTime.now();
    final difference = now.difference(lastModified);

    if (difference.inDays == 0) {
      return 'Hoy a las ${lastModified.hour.toString().padLeft(2, '0')}:${lastModified.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Ayer a las ${lastModified.hour.toString().padLeft(2, '0')}:${lastModified.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays < 7) {
      return 'Hace ${difference.inDays} días';
    } else {
      return '${lastModified.day}/${lastModified.month}/${lastModified.year}';
    }
  }
}

// ==========================================================================
// PBKDF2 IMPLEMENTATION (Para derivación de keys desde password)
// ==========================================================================

class _Pbkdf2 {
  final int iterations;
  final int bits;

  _Pbkdf2({
    required this.iterations,
    required this.bits,
  });

  List<int> deriveKey({
    required List<int> secretKey,
    required List<int> nonce,
  }) {
    // SHA-256 tiene un blockSize de 64 bytes (512 bits)
    const hashOutputSize = 32; // SHA-256 produce 32 bytes
    final blockCount = (bits + hashOutputSize * 8 - 1) ~/ (hashOutputSize * 8);
    final result = <int>[];

    for (var i = 1; i <= blockCount; i++) {
      result.addAll(_f(secretKey, nonce, i));
    }

    return result.sublist(0, bits ~/ 8);
  }

  List<int> _f(List<int> password, List<int> salt, int blockIndex) {
    final hmac = Hmac(sha256, password);

    // U1 = PRF(password, salt || INT_32_BE(i))
    final saltAndIndex = [...salt, ...Uint8List(4)..buffer.asByteData().setUint32(0, blockIndex, Endian.big)];
    var u = hmac.convert(saltAndIndex).bytes;
    final result = List<int>.from(u);

    // U2...Uc
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return result;
  }
}
