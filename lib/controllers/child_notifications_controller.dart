import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import '../utils/release_logger.dart';
import '../services/notification_cache_service.dart';

/// Controller para la pantalla de notificaciones de un hijo específico
///
/// Responsabilidades:
/// - Gestionar paginación de notificaciones
/// - Filtrar notificaciones por hijo específico
/// - Manejar operaciones de marcado como leído (batch operations)
/// - Proporcionar streams de notificaciones
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls en screens
class ChildNotificationsController {
  final String childId;
  final String childName;

  // Servicios privados
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final NotificationCacheService _cacheService;

  // Estado interno
  String? _currentUserId;

  // Paginación (para compatibilidad con streams de Firestore durante transición)
  static const int _pageSize = 20;
  DocumentSnapshot? _lastDocument;
  bool _isLoadingMore = false;
  bool _hasMoreData = true;
  final List<DocumentSnapshot> _notifications = [];

  // Tracking de notificaciones marcadas como leídas
  final Set<String> _markedAsRead = {};

  // Cache de notificaciones locales
  List<Map<String, dynamic>> _cachedNotifications = [];
  bool _isSyncing = false;

  /// Constructor
  ChildNotificationsController({
    required this.childId,
    required this.childName,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    NotificationCacheService? cacheService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _cacheService = cacheService ?? NotificationCacheService();

  // Getters
  String? get currentUserId => _currentUserId ?? _auth.currentUser?.uid;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMoreData => _hasMoreData;
  bool get isSyncing => _isSyncing;
  List<DocumentSnapshot> get notifications => List.unmodifiable(_notifications);
  List<Map<String, dynamic>> get cachedNotifications => List.unmodifiable(_cachedNotifications);

  /// Inicializar el controller
  void initialize() {
    try {
      _currentUserId = _auth.currentUser?.uid;
      if (_currentUserId == null) {
        ReleaseLogger.warning('Usuario no autenticado en ChildNotificationsController', tag: 'ChildNotifications');
      } else {
        ReleaseLogger.log('ChildNotificationsController inicializado para hijo: $childName ($childId)', tag: 'ChildNotifications');
      }
    } catch (e) {
      ReleaseLogger.error('Error inicializando ChildNotificationsController: $e', tag: 'ChildNotifications');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE CACHE LOCAL (NUEVA ARQUITECTURA)
  // ═══════════════════════════════════════════════════════════════

  /// Sincronizar notificaciones de Firestore al cache local
  ///
  /// Flujo simplificado (sin eliminación manual - TTL se encarga):
  /// 1. Leer notificaciones de Firestore
  /// 2. Cachear localmente las nuevas
  /// 3. Retornar lista desde cache local
  ///
  /// Nota: Las notificaciones se eliminan automáticamente por TTL (deleteAt)
  /// configurado en Cloud Functions. No eliminamos manualmente para evitar
  /// el doble de escrituras en Firestore.
  Future<List<Map<String, dynamic>>> syncAndGetNotifications() async {
    if (_isSyncing) {
      ReleaseLogger.log('Ya sincronizando, retornando cache actual', tag: 'ChildNotifications');
      return getNotificationsFromCache();
    }

    _isSyncing = true;
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para sync', tag: 'ChildNotifications');
        return getNotificationsFromCache();
      }

      ReleaseLogger.log('Iniciando sync de notificaciones para $childName...', tag: 'ChildNotifications');

      // 1. Leer notificaciones de Firestore
      final firestoreSnapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      ReleaseLogger.log('Encontradas ${firestoreSnapshot.docs.length} notificaciones en Firestore', tag: 'ChildNotifications');

      int cachedCount = 0;

      // 2. Procesar cada notificación - solo cachear, NO eliminar
      for (final doc in firestoreSnapshot.docs) {
        final data = doc.data();
        final notificationId = doc.id;

        // ✅ FIX: Filtrar notificaciones con hideFromUI (story_approval_request, contact_request)
        // Estas se manejan en sus propias secciones (Historias Pendientes, Whitelist)
        if (data['hideFromUI'] == true) {
          continue;
        }

        // Verificar si ya está cacheada
        if (_cacheService.isNotificationCached(userId, notificationId)) {
          // Ya cacheada, skip (TTL eliminará de Firestore automáticamente)
          continue;
        }

        // Cachear la notificación
        final saved = await _cacheService.saveNotification(
          notificationId: notificationId,
          userId: userId,
          type: data['type'] as String? ?? 'unknown',
          title: data['title'] as String? ?? '',
          body: data['body'] as String? ?? '',
          data: data['data'] as Map<String, dynamic>?,
          priority: data['priority'] as String?,
          childId: data['childId'] as String? ?? (data['data'] as Map<String, dynamic>?)?['childId'] as String?,
        );

        if (saved) {
          cachedCount++;
        }
      }

      ReleaseLogger.log('Sync completado: $cachedCount nuevas notificaciones cacheadas', tag: 'ChildNotifications');

      // 3. Retornar desde cache local
      return getNotificationsFromCache();
    } catch (e) {
      ReleaseLogger.error('Error en sync de notificaciones: $e', tag: 'ChildNotifications');
      // En caso de error, retornar lo que tengamos en cache
      return getNotificationsFromCache();
    } finally {
      _isSyncing = false;
    }
  }

  /// Obtener notificaciones del cache local filtradas por hijo
  List<Map<String, dynamic>> getNotificationsFromCache() {
    final userId = currentUserId;
    if (userId == null) {
      ReleaseLogger.warning('Usuario no autenticado para obtener cache', tag: 'ChildNotifications');
      return [];
    }

    // Obtener notificaciones filtradas por este hijo
    final notifications = _cacheService.getNotificationsForChild(userId, childId);

    // Filtrar notificaciones de chat (solo queremos alertas/solicitudes)
    final filteredNotifications = notifications.where((notif) {
      final type = notif['type'] as String?;
      return type != 'chat_message' && type != 'group_message';
    }).toList();

    ReleaseLogger.log('Cache local: ${filteredNotifications.length} notificaciones para $childName', tag: 'ChildNotifications');

    _cachedNotifications = filteredNotifications;
    return filteredNotifications;
  }

  /// Obtener conteo de no leídas del cache
  int getUnreadCountFromCache() {
    final userId = currentUserId;
    if (userId == null) return 0;

    return _cacheService.getUnreadCountForChild(userId, childId);
  }

  /// Marcar notificación como leída en cache local
  Future<bool> markAsReadInCache(String notificationId) async {
    final userId = currentUserId;
    if (userId == null) return false;

    final success = await _cacheService.markAsRead(userId, notificationId);
    if (success) {
      _markedAsRead.add(notificationId);
      // Actualizar cache local
      getNotificationsFromCache();
    }
    return success;
  }

  /// Marcar todas las notificaciones del hijo como leídas en cache
  Future<int> markAllAsReadInCache() async {
    final userId = currentUserId;
    if (userId == null) return 0;

    final count = await _cacheService.markAllAsReadForChild(userId, childId);
    if (count > 0) {
      // Actualizar cache local
      getNotificationsFromCache();
    }
    return count;
  }

  /// Separar notificaciones cacheadas en leídas y no leídas
  Map<String, List<Map<String, dynamic>>> separateCachedReadUnread() {
    final notifications = getNotificationsFromCache();

    final unreadNotifications = notifications.where((notif) {
      return notif['read'] != true;
    }).toList();

    final readNotifications = notifications.where((notif) {
      return notif['read'] == true;
    }).toList();

    ReleaseLogger.log('Cache separado: ${unreadNotifications.length} no leídas, ${readNotifications.length} leídas', tag: 'ChildNotifications');

    return {
      'unread': unreadNotifications,
      'read': readNotifications,
    };
  }

  /// Formatear timestamp desde cache (milliseconds)
  String formatCachedTimestamp(int milliseconds) {
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inDays == 0) {
        if (difference.inHours == 0) {
          if (difference.inMinutes == 0) {
            return 'Ahora';
          }
          return 'Hace ${difference.inMinutes} min';
        }
        return 'Hace ${difference.inHours}h';
      } else if (difference.inDays == 1) {
        return 'Ayer ${_formatTime(date)}';
      } else if (difference.inDays < 7) {
        return 'Hace ${difference.inDays} días';
      } else {
        return _formatDate(date);
      }
    } catch (e) {
      ReleaseLogger.error('Error formateando timestamp cacheado: $e', tag: 'ChildNotifications');
      return 'Fecha desconocida';
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS DE FIRESTORE (LEGACY - PARA COMPATIBILIDAD)
  // ═══════════════════════════════════════════════════════════════

  /// Stream principal de notificaciones (primeras 50)
  Stream<QuerySnapshot> getNotificationsStream() {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para stream de notificaciones', tag: 'ChildNotifications');
        return Stream.empty();
      }

      // Nota: El filtrado de hideFromUI se hace en filterNotificationsForChild()
      // ya que QuerySnapshot no permite modificar sus docs
      return _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .orderBy('timestamp', descending: true)
          .limit(50)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error creando stream de notificaciones: $e', tag: 'ChildNotifications');
      return Stream.empty();
    }
  }

  /// Cargar más notificaciones (paginación)
  Future<bool> loadMoreNotifications() async {
    if (_isLoadingMore || !_hasMoreData) return false;

    try {
      _isLoadingMore = true;
      ReleaseLogger.log('Cargando más notificaciones...', tag: 'ChildNotifications');

      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para cargar más notificaciones', tag: 'ChildNotifications');
        return false;
      }

      Query query = _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .orderBy('timestamp', descending: true)
          .limit(_pageSize);

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (snapshot.docs.isEmpty) {
        _hasMoreData = false;
        ReleaseLogger.log('No hay más notificaciones para cargar', tag: 'ChildNotifications');
        return false;
      }

      _lastDocument = snapshot.docs.last;
      _notifications.addAll(snapshot.docs);

      if (snapshot.docs.length < _pageSize) {
        _hasMoreData = false;
      }

      ReleaseLogger.log('Cargadas ${snapshot.docs.length} notificaciones adicionales', tag: 'ChildNotifications');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error cargando más notificaciones: $e', tag: 'ChildNotifications');
      return false;
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Filtrar notificaciones para este hijo específico
  List<DocumentSnapshot> filterNotificationsForChild(List<DocumentSnapshot> allDocs) {
    try {
      ReleaseLogger.log('Filtrando ${allDocs.length} notificaciones para hijo: $childName', tag: 'ChildNotifications');

      final childNotifications = allDocs.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final notifData = data['data'] as Map<String, dynamic>?;
        final type = data['type'] as String?;

        // ✅ FIX: Filtrar notificaciones con hideFromUI (story_approval_request, contact_request)
        // Estas se manejan en sus propias secciones (Historias Pendientes, Whitelist)
        if (data['hideFromUI'] == true) {
          return false;
        }

        // Excluir notificaciones de chat
        if (type == 'chat_message') {
          return false;
        }

        // ✅ FIX: Verificar si la notificación está relacionada con este hijo
        // SOLO usar campos que realmente identifican al hijo:
        // - notifData['childId']: La notificación es SOBRE este hijo
        // - notifData['senderId']: La notificación fue ENVIADA por este hijo
        // NO usar data['senderId'] ya que puede ser cualquier remitente (causa falsos positivos)
        final isRelated = notifData?['childId'] == childId ||
               notifData?['senderId'] == childId;

        return isRelated;
      }).toList();

      ReleaseLogger.log('Encontradas ${childNotifications.length} notificaciones para $childName', tag: 'ChildNotifications');
      return childNotifications;
    } catch (e) {
      ReleaseLogger.error('Error filtrando notificaciones: $e', tag: 'ChildNotifications');
      return [];
    }
  }

  /// Separar notificaciones en leídas y no leídas
  Map<String, List<DocumentSnapshot>> separateReadUnread(List<DocumentSnapshot> notifications) {
    try {
      final unreadNotifications = notifications.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return !(data['read'] as bool? ?? false);
      }).toList();

      final readNotifications = notifications.where((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return data['read'] as bool? ?? false;
      }).toList();

      ReleaseLogger.log('Separadas: ${unreadNotifications.length} no leídas, ${readNotifications.length} leídas', tag: 'ChildNotifications');

      return {
        'unread': unreadNotifications,
        'read': readNotifications,
      };
    } catch (e) {
      ReleaseLogger.error('Error separando notificaciones: $e', tag: 'ChildNotifications');
      return {'unread': [], 'read': []};
    }
  }

  /// Marcar notificación individual como leída
  Future<bool> markAsRead(String notificationId) async {
    try {
      await _firestore.collection('notifications').doc(notificationId).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });

      _markedAsRead.add(notificationId);
      ReleaseLogger.log('Notificación $notificationId marcada como leída', tag: 'ChildNotifications');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error marcando notificación como leída: $e', tag: 'ChildNotifications');
      return false;
    }
  }

  /// Marcar notificaciones visibles como leídas automáticamente
  Future<int> markVisibleNotificationsAsRead() async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.warning('Usuario no autenticado para marcar notificaciones', tag: 'ChildNotifications');
        return 0;
      }

      // Obtener notificaciones no leídas del hijo actual
      final unreadSnapshot = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .limit(10) // Solo las primeras 10 visibles
          .get();

      final batch = _firestore.batch();
      int markedCount = 0;

      for (final doc in unreadSnapshot.docs) {
        final data = doc.data();
        final notifData = data['data'] as Map<String, dynamic>?;

        // Filtrar notificaciones de chat
        if (data['type'] == 'chat_message') {
          continue;
        }

        // ✅ FIX: Verificar si está relacionada con este hijo
        // SOLO usar campos que realmente identifican al hijo
        final isRelatedToChild = notifData?['childId'] == childId ||
            notifData?['senderId'] == childId;

        if (isRelatedToChild && !_markedAsRead.contains(doc.id)) {
          batch.update(doc.reference, {
            'read': true,
            'readAt': FieldValue.serverTimestamp(),
          });
          _markedAsRead.add(doc.id);
          markedCount++;
        }
      }

      if (markedCount > 0) {
        await batch.commit();
        ReleaseLogger.log('Marcadas $markedCount notificaciones como leídas automáticamente', tag: 'ChildNotifications');
      }

      return markedCount;
    } catch (e) {
      ReleaseLogger.error('Error marcando notificaciones visibles: $e', tag: 'ChildNotifications');
      return 0;
    }
  }

  /// Marcar todas las notificaciones del hijo como leídas
  ///
  /// Optimizado para evitar N+1 queries:
  /// - Procesa en batches de 500 (límite de Firestore)
  /// - Limita queries para evitar timeouts
  Future<int> markAllAsRead() async {
    try {
      final userId = currentUserId;
      if (userId == null) {
        ReleaseLogger.error('Usuario no autenticado para marcar todas como leídas', tag: 'ChildNotifications');
        return 0;
      }

      int totalMarked = 0;
      const int batchLimit = 500; // Límite de Firestore para batch writes
      const int queryLimit = 200; // Límite por query para evitar timeouts

      // Procesar en múltiples iteraciones si hay muchas notificaciones
      bool hasMore = true;

      while (hasMore) {
        // Obtener notificaciones no leídas en batches pequeños
        final notificationsSnapshot = await _firestore
            .collection('notifications')
            .where('userId', isEqualTo: userId)
            .where('read', isEqualTo: false)
            .limit(queryLimit)
            .get();

        if (notificationsSnapshot.docs.isEmpty) {
          hasMore = false;
          break;
        }

        final batch = _firestore.batch();
        int batchCount = 0;

        for (final doc in notificationsSnapshot.docs) {
          final data = doc.data();
          final notifData = data['data'] as Map<String, dynamic>?;

          // Filtrar notificaciones de chat (ya no se guardan en DB, pero por compatibilidad)
          if (data['type'] == 'chat_message' || data['type'] == 'group_message') {
            continue;
          }

          // ✅ FIX: Verificar si la notificación está relacionada con este hijo
          // SOLO usar campos que realmente identifican al hijo
          final isRelatedToChild = notifData?['childId'] == childId ||
              notifData?['senderId'] == childId;

          if (isRelatedToChild) {
            batch.update(doc.reference, {
              'read': true,
              'readAt': FieldValue.serverTimestamp(),
            });
            batchCount++;
            totalMarked++;

            // Si llegamos al límite del batch, hacer commit y crear nuevo
            if (batchCount >= batchLimit) {
              break;
            }
          }
        }

        if (batchCount > 0) {
          await batch.commit();
          ReleaseLogger.log('Batch commit: $batchCount notificaciones marcadas', tag: 'ChildNotifications');
        }

        // Si obtuvimos menos de queryLimit, no hay más
        if (notificationsSnapshot.docs.length < queryLimit) {
          hasMore = false;
        }
      }

      ReleaseLogger.log('Total marcadas: $totalMarked notificaciones como leídas para hijo: $childName', tag: 'ChildNotifications');
      return totalMarked;
    } catch (e) {
      ReleaseLogger.error('Error marcando todas las notificaciones como leídas: $e', tag: 'ChildNotifications');
      return 0;
    }
  }

  /// Formatear timestamp de notificación
  String formatTimestamp(Timestamp timestamp) {
    try {
      final date = timestamp.toDate();
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inDays == 0) {
        if (difference.inHours == 0) {
          if (difference.inMinutes == 0) {
            return 'Ahora';
          }
          return 'Hace ${difference.inMinutes} min';
        }
        return 'Hace ${difference.inHours}h';
      } else if (difference.inDays == 1) {
        return 'Ayer ${_formatTime(date)}';
      } else if (difference.inDays < 7) {
        return 'Hace ${difference.inDays} días';
      } else {
        return _formatDate(date);
      }
    } catch (e) {
      ReleaseLogger.error('Error formateando timestamp: $e', tag: 'ChildNotifications');
      return 'Fecha desconocida';
    }
  }

  String _formatTime(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${_formatTime(date)}';
  }

  /// Verificar si el usuario está autenticado
  bool get isUserAuthenticated => currentUserId != null;

  /// Obtener estilos de notificación
  NotificationStyle getNotificationStyle(String type, String priority) {
    switch (type) {
      case 'contact_request':
        return NotificationStyle(
          color: const Color(0xFF2196F3), // Blue
          icon: Icons.person_add,
          label: 'Solicitud de Contacto',
        );
      case 'story_approval_request':
        return NotificationStyle(
          color: const Color(0xFF9C27B0), // Purple
          icon: Icons.photo_library,
          label: 'Historia Pendiente',
        );
      case 'group_approval_request':
        return NotificationStyle(
          color: const Color(0xFF00BCD4), // Cyan
          icon: Icons.group_add,
          label: 'Solicitud de Grupo',
        );
      case 'story_approved':
        return NotificationStyle(
          color: const Color(0xFF4CAF50), // Green
          icon: Icons.check_circle,
          label: 'Historia Aprobada',
        );
      case 'story_rejected':
        return NotificationStyle(
          color: const Color(0xFFFF9800), // Orange
          icon: Icons.cancel,
          label: 'Historia Rechazada',
        );
      case 'bullying_alert':
      case 'activity_alert':
        return NotificationStyle(
          color: const Color(0xFFF44336), // Red
          icon: Icons.warning,
          label: type == 'bullying_alert' ? 'Alerta de Bullying' : 'Alerta de Actividad',
        );
      case 'contact_approved':
        return NotificationStyle(
          color: const Color(0xFF4CAF50), // Green
          icon: Icons.check_circle,
          label: 'Contacto Aprobado',
        );
      case 'whitelist_change':
        return NotificationStyle(
          color: const Color(0xFF3F51B5), // Indigo
          icon: Icons.shield,
          label: 'Cambio en Familia',
        );
      default:
        return NotificationStyle(
          color: priority == 'high' ? const Color(0xFFFF9800) : const Color(0xFF2196F3),
          icon: Icons.notifications,
          label: 'Notificación',
        );
    }
  }

  /// Verificar si un tipo de notificación tiene acciones
  bool hasAction(String type) {
    return [
      'contact_request',
      'story_approval_request',
      'group_approval_request',
    ].contains(type);
  }

  /// Obtener label de acción para tipo de notificación
  String getActionLabel(String type) {
    switch (type) {
      case 'contact_request':
        return 'Ver Solicitud';
      case 'story_approval_request':
        return 'Revisar Historia';
      case 'group_approval_request':
        return 'Ver Solicitudes';
      default:
        return 'Ver Detalles';
    }
  }

  /// Logging para depuración
  void logDebugInfo(String message) {
    ReleaseLogger.log(message, tag: 'ChildNotifications');
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChildNotificationsController for child: $childName', tag: 'ChildNotifications');
    _notifications.clear();
    _markedAsRead.clear();
  }
}

/// Clase auxiliar para estilos de notificaciones
class NotificationStyle {
  final Color color;
  final IconData icon;
  final String label;

  const NotificationStyle({
    required this.color,
    required this.icon,
    required this.label,
  });
}