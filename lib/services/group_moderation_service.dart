import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';
import 'app_config_service.dart';
import 'subscription_service.dart';

/// Resultado de operación de moderación de grupo
class GroupModerationResult {
  final bool success;
  final String message;
  final bool enabled;
  final String level;

  const GroupModerationResult({
    required this.success,
    required this.message,
    required this.enabled,
    required this.level,
  });
}

/// Estado de moderación de un grupo
class GroupModerationState {
  final bool enabled;
  final String level;
  final DateTime? updatedAt;
  final String? updatedBy;

  const GroupModerationState({
    required this.enabled,
    required this.level,
    this.updatedAt,
    this.updatedBy,
  });

  factory GroupModerationState.fromMap(Map<String, dynamic> data) {
    return GroupModerationState(
      enabled: data['moderationEnabled'] as bool? ?? false,
      level: data['moderationLevel'] as String? ?? 'high',
      updatedAt: (data['moderationUpdatedAt'] as Timestamp?)?.toDate(),
      updatedBy: data['moderationUpdatedBy'] as String?,
    );
  }
}

/// Servicio para gestionar moderación de grupos
///
/// Permite a administradores con Premium activar/desactivar moderación.
/// Si premium_enabled está desactivado, cualquier admin puede usarlo.
class GroupModerationService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppConfigService _configService;
  final SubscriptionService _subscriptionService;

  static final GroupModerationService _instance = GroupModerationService._internal();

  factory GroupModerationService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    AppConfigService? configService,
    SubscriptionService? subscriptionService,
  }) {
    return _instance;
  }

  GroupModerationService._internal()
      : _firestore = FirebaseFirestore.instance,
        _auth = FirebaseAuth.instance,
        _configService = AppConfigService(),
        _subscriptionService = SubscriptionService();

  /// Verificar si el usuario actual puede modificar moderación del grupo
  ///
  /// [wantsToEnable] - true si quiere activar, false si quiere desactivar
  /// Retorna (canModify, reason)
  ///
  /// ✅ FIX: Non-premium admins can DISABLE moderation (but not enable)
  Future<({bool canModify, String reason})> canModifyModeration(String groupId, {bool wantsToEnable = true}) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return (canModify: false, reason: 'Usuario no autenticado');
    }

    // Verificar que es admin del grupo
    final groupDoc = await _firestore.collection('groups_v2').doc(groupId).get();
    if (!groupDoc.exists) {
      return (canModify: false, reason: 'Grupo no encontrado');
    }

    final admins = List<String>.from(groupDoc.data()?['admins'] ?? []);
    if (!admins.contains(userId)) {
      return (canModify: false, reason: 'Solo administradores pueden modificar la moderación');
    }

    // Si premium está deshabilitado, todos los admins pueden
    if (!_configService.premiumEnabled) {
      return (canModify: true, reason: 'Premium deshabilitado - acceso permitido');
    }

    // ✅ FIX: Cualquier admin puede DESACTIVAR moderación sin premium
    // Solo se requiere premium para ACTIVAR
    if (!wantsToEnable) {
      return (canModify: true, reason: 'Admin puede desactivar moderación');
    }

    // Verificar suscripción premium para ACTIVAR
    final premiumStatus = await _subscriptionService.checkPremiumStatus();
    if (!premiumStatus.isPremium) {
      return (canModify: false, reason: 'Requiere suscripción Premium para activar');
    }

    return (canModify: true, reason: 'Admin con Premium');
  }

  /// Actualizar configuración de moderación del grupo
  ///
  /// [groupId] - ID del grupo
  /// [enabled] - Activar o desactivar moderación
  /// [level] - Nivel de moderación: 'high', 'medium', 'low'
  ///
  /// Note: Multimedia moderation is auto-enabled server-side when any group admin is Premium+.
  /// No separate toggle is needed.
  Future<GroupModerationResult> setModeration({
    required String groupId,
    required bool enabled,
    String level = 'high',
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return const GroupModerationResult(
          success: false,
          message: 'Usuario no autenticado',
          enabled: false,
          level: 'high',
        );
      }

      // Verificar permisos (pasar wantsToEnable para diferenciar activar vs desactivar)
      final permissionCheck = await canModifyModeration(groupId, wantsToEnable: enabled);
      if (!permissionCheck.canModify) {
        return GroupModerationResult(
          success: false,
          message: permissionCheck.reason,
          enabled: false,
          level: 'high',
        );
      }

      // Validar nivel
      final validLevels = ['high', 'medium', 'low'];
      final normalizedLevel = validLevels.contains(level) ? level : 'high';

      // Actualizar Firestore
      await _firestore.collection('groups_v2').doc(groupId).update({
        'moderationEnabled': enabled,
        'moderationLevel': normalizedLevel,
        'moderationUpdatedAt': FieldValue.serverTimestamp(),
        'moderationUpdatedBy': userId,
      });

      ReleaseLogger.log(
        '✅ Moderación de grupo actualizada: groupId=$groupId, enabled=$enabled, level=$normalizedLevel',
        tag: 'GroupModeration',
      );

      return GroupModerationResult(
        success: true,
        message: enabled ? 'Moderación activada' : 'Moderación desactivada',
        enabled: enabled,
        level: normalizedLevel,
      );
    } catch (e) {
      ReleaseLogger.error(
        'Error actualizando moderación de grupo: $e',
        tag: 'GroupModeration',
      );

      return GroupModerationResult(
        success: false,
        message: 'Error al actualizar moderación',
        enabled: false,
        level: 'high',
      );
    }
  }

  /// Stream del estado de moderación del grupo
  Stream<GroupModerationState> watchModeration(String groupId) {
    return _firestore
        .collection('groups_v2')
        .doc(groupId)
        .snapshots()
        .map((snapshot) {
      if (!snapshot.exists) {
        return const GroupModerationState(enabled: false, level: 'high');
      }
      return GroupModerationState.fromMap(snapshot.data()!);
    });
  }

  /// Obtener estado actual de moderación
  Future<GroupModerationState> getModeration(String groupId) async {
    final doc = await _firestore.collection('groups_v2').doc(groupId).get();
    if (!doc.exists) {
      return const GroupModerationState(enabled: false, level: 'high');
    }
    return GroupModerationState.fromMap(doc.data()!);
  }
}
