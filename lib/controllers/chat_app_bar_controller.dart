import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/whitelist/set_own_moderation_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio del ChatAppBar
///
/// Responsabilidades:
/// - Verificar si el usuario puede modificar moderación
/// - Obtener datos del contacto en tiempo real
/// - Gestionar moderación IA para usuarios adultos
/// - Abstraer operaciones Firebase del widget
class ChatAppBarController {
  // Firebase services
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final SetOwnModerationService _moderationService;

  // Estado interno
  bool _canModifyModeration = false;
  bool _isLoading = true;
  String? _chatId;

  // Estado de moderación
  bool _moderationEnabled = false;
  String _moderationLevel = 'medium';
  bool _isLoadingModeration = false;

  // Streams controllers para notificar cambios
  final StreamController<bool> _canModifyModerationController = StreamController<bool>.broadcast();
  final StreamController<bool> _isLoadingController = StreamController<bool>.broadcast();
  final StreamController<ModerationState> _moderationStateController = StreamController<ModerationState>.broadcast();

  /// Constructor
  ChatAppBarController({
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    SetOwnModerationService? moderationService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _moderationService = moderationService ?? SetOwnModerationService();

  // Getters para estado actual
  bool get canModifyModeration => _canModifyModeration;
  bool get isLoading => _isLoading;
  bool get moderationEnabled => _moderationEnabled;
  String get moderationLevel => _moderationLevel;
  bool get isLoadingModeration => _isLoadingModeration;

  // Streams para escuchar cambios
  Stream<bool> get canModifyModerationStream => _canModifyModerationController.stream;
  Stream<bool> get isLoadingStream => _isLoadingController.stream;
  Stream<ModerationState> get moderationStateStream => _moderationStateController.stream;

  /// Inicializar controller
  Future<void> initialize({String? chatId}) async {
    _chatId = chatId;

    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        _updateLoadingState(false);
        return;
      }

      ReleaseLogger.log('Inicializando ChatAppBarController para chat: $chatId', tag: 'ChatAppBar');

      // Verificar permisos de moderación
      await _checkModerationPermissions(currentUserId);

      _updateLoadingState(false);
    } catch (e) {
      ReleaseLogger.error('Error inicializando controller: $e', tag: 'ChatAppBar');
      _updateLoadingState(false);
    }
  }

  /// Verificar si el usuario puede modificar moderación
  Future<void> _checkModerationPermissions(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) {
        _updateCanModifyModeration(false);
        return;
      }

      final userData = userDoc.data();
      final role = userData?['role'] as String? ?? 'adult';

      // Si es niño, verificar si tiene padres vinculados
      if (role == 'child') {
        final parentLinks = await _firestore
            .collection('parent_children')
            .where('childId', isEqualTo: userId)
            .where('status', isEqualTo: 'approved')
            .limit(1)
            .get();

        // Si tiene padres, no puede modificar moderación
        if (parentLinks.docs.isNotEmpty) {
          ReleaseLogger.log('Usuario $userId es niño supervisado, no puede modificar moderación', tag: 'ChatAppBar');
          _updateCanModifyModeration(false);
          return;
        }
      }

      // Adulto, padre, o niño sin padres → puede modificar
      ReleaseLogger.log('Usuario $userId puede modificar moderación (role: $role)', tag: 'ChatAppBar');
      _updateCanModifyModeration(true);

      // Cargar estado actual de moderación
      if (_chatId != null) {
        await _loadCurrentModeration();
      }
    } catch (e) {
      ReleaseLogger.error('Error verificando permisos moderación: $e', tag: 'ChatAppBar');
      _updateCanModifyModeration(false);
    }
  }

  /// Cargar estado actual de moderación
  Future<void> _loadCurrentModeration() async {
    if (_chatId == null) return;

    try {
      final result = await _moderationService.getCurrentModeration(
        contactId: _chatId!,
      );

      _moderationEnabled = result.enabled;
      _moderationLevel = result.level;
      _emitModerationState();
    } catch (e) {
      ReleaseLogger.error('Error cargando moderación: $e', tag: 'ChatAppBar');
    }
  }

  /// Obtener stream de datos del contacto
  Stream<DocumentSnapshot> getContactDataStream(String contactId) {
    try {
      ReleaseLogger.log('Obteniendo stream de datos del contacto $contactId', tag: 'ChatAppBar');

      return _firestore
          .collection('users')
          .doc(contactId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream del contacto $contactId: $e', tag: 'ChatAppBar');
      rethrow;
    }
  }

  /// Extraer datos del contacto del snapshot
  Map<String, dynamic> extractContactData(DocumentSnapshot? snapshot) {
    if (snapshot?.data() == null) {
      return {
        'photoURL': '',
        'isOnline': false,
        'name': '',
        'lastSeen': null,
        'hideLastSeen': false,
      };
    }

    final userData = snapshot!.data() as Map<String, dynamic>;
    return {
      'photoURL': userData['photoURL'] as String? ?? '',
      'isOnline': userData['isOnline'] ?? false,
      'name': userData['name'] as String? ?? '',
      'lastSeen': userData['lastSeen'] as Timestamp?,
      'hideLastSeen': userData['hideLastSeen'] ?? false,
    };
  }

  /// Formatear última vez visto para mostrar en UI
  String formatLastSeen(Timestamp? lastSeen) {
    if (lastSeen == null) return 'Desconectado';

    final lastSeenDate = lastSeen.toDate();
    final now = DateTime.now();
    final difference = now.difference(lastSeenDate);

    // Formatear hora
    final hour = lastSeenDate.hour.toString().padLeft(2, '0');
    final minute = lastSeenDate.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';

    // Hoy
    if (difference.inDays == 0 && now.day == lastSeenDate.day) {
      return 'Últ. vez hoy $timeStr';
    }

    // Ayer
    final yesterday = now.subtract(const Duration(days: 1));
    if (lastSeenDate.year == yesterday.year &&
        lastSeenDate.month == yesterday.month &&
        lastSeenDate.day == yesterday.day) {
      return 'Últ. vez ayer $timeStr';
    }

    // Esta semana (menos de 7 días)
    if (difference.inDays < 7) {
      final dayNames = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
      final dayName = dayNames[lastSeenDate.weekday - 1];
      return 'Últ. vez $dayName $timeStr';
    }

    // Más de una semana
    final day = lastSeenDate.day.toString();
    final monthNames = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    final month = monthNames[lastSeenDate.month - 1];
    return 'Últ. vez $day $month';
  }

  /// Actualizar si puede modificar moderación
  void _updateCanModifyModeration(bool canModify) {
    _canModifyModeration = canModify;
    _canModifyModerationController.add(_canModifyModeration);
  }

  /// Actualizar estado de carga
  void _updateLoadingState(bool isLoading) {
    _isLoading = isLoading;
    _isLoadingController.add(_isLoading);
  }

  /// Emitir estado de moderación
  void _emitModerationState() {
    _moderationStateController.add(ModerationState(
      enabled: _moderationEnabled,
      level: _moderationLevel,
      isLoading: _isLoadingModeration,
    ));
  }

  /// Obtener ID del usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Actualización optimista del estado local (sin llamar a Cloud Function)
  void setModerationOptimistic({required bool enabled, required String level}) {
    _moderationEnabled = enabled;
    _moderationLevel = level;
    _emitModerationState();
  }

  /// Actualizar nivel de moderación
  Future<({bool success, String message})> setModerationLevel(String level) async {
    if (_chatId == null) {
      return (success: false, message: 'Chat no inicializado');
    }

    _isLoadingModeration = true;
    _emitModerationState();

    try {
      final result = await _moderationService.call(
        contactId: _chatId!,
        moderationLevel: level,
        enabled: level != 'none',
      );

      if (result.success) {
        _moderationEnabled = result.enabled;
        _moderationLevel = result.level;
      }

      _isLoadingModeration = false;
      _emitModerationState();

      return (success: result.success, message: result.message);
    } catch (e) {
      _isLoadingModeration = false;
      _emitModerationState();
      return (success: false, message: 'Error: $e');
    }
  }

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChatAppBarController', tag: 'ChatAppBar');
    _canModifyModerationController.close();
    _isLoadingController.close();
    _moderationStateController.close();
  }
}

/// Estado de moderación
class ModerationState {
  final bool enabled;
  final String level;
  final bool isLoading;

  ModerationState({
    required this.enabled,
    required this.level,
    required this.isLoading,
  });
}