import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';

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
