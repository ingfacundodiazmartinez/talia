import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../voip_service.dart';
import '../app_state_service.dart';
import '../../utils/release_logger.dart';

/// Servicio dedicado para manejar todos los listeners de llamadas
///
/// Responsabilidades:
/// - Configurar listeners de Firestore para llamadas foreground
/// - Detectar llamadas entrantes en tiempo real SOLO para el usuario actual
/// - Filtrar llamadas según estado de la app
/// - Notificar al orchestrator cuando detecta llamadas válidas
class CallListenerService {
  static final CallListenerService _instance = CallListenerService._internal();
  factory CallListenerService() => _instance;
  CallListenerService._internal();

  // State
  StreamSubscription<QuerySnapshot>? _foregroundCallSubscription;
  bool _isListening = false;

  // Callback para notificar al orchestrator
  Function(String callId, String source)? onCallDetected;

  /// Inicializar listeners
  Future<void> initialize({
    required Function(String callId, String source) onCallDetected,
  }) async {
    if (_isListening) return;

    this.onCallDetected = onCallDetected;

    ReleaseLogger.log(
      '🚀 [CallListenerService] Inicializando listeners',
      tag: 'CallListenerService',
    );

    _setupForegroundCallListener();

    _isListening = true;

    ReleaseLogger.log(
      '✅ [CallListenerService] Listeners configurados',
      tag: 'CallListenerService',
    );
  }

  /// Dispose listeners
  void dispose() {
    _foregroundCallSubscription?.cancel();
    _isListening = false;
    onCallDetected = null;

    ReleaseLogger.log(
      '🧹 [CallListenerService] Listeners disposed',
      tag: 'CallListenerService',
    );
  }

  /// Configurar listener para detectar llamadas en foreground
  void _setupForegroundCallListener() {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid;
    if (currentUserId == null) {
      ReleaseLogger.error(
        '❌ [CallListenerService] No hay usuario autenticado',
        tag: 'CallListenerService',
      );
      return;
    }

    ReleaseLogger.log(
      '👂 [CallListenerService] Configurando listener foreground para usuario: $currentUserId',
      tag: 'CallListenerService',
    );

    try {
      final callsCollection = FirebaseFirestore.instance.collection('calls');

      // ✅ FILTRAR SOLO LLAMADAS DONDE EL USUARIO ACTUAL ESTÁ EN PARTICIPANTS
      _foregroundCallSubscription = callsCollection
          .where('participants.$currentUserId', isNull: false)
          .where(
            'createdAt',
            isGreaterThan: DateTime.now().subtract(Duration(minutes: 5)),
          )
          .snapshots()
          .listen(
            (snapshot) => _handleForegroundCallSnapshot(snapshot),
            onError: (error) {
              ReleaseLogger.error(
                '❌ [CallListenerService] Error en listener foreground: $error',
                tag: 'CallListenerService',
              );
            },
          );
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallListenerService] Error configurando listener: $e',
        tag: 'CallListenerService',
      );
    }
  }

  /// Procesar snapshot de llamadas en foreground
  void _handleForegroundCallSnapshot(QuerySnapshot snapshot) async {
    try {
      for (var docChange in snapshot.docChanges) {
        if (docChange.type == DocumentChangeType.added) {
          await _processForegroundCall(docChange.doc, isNewCall: true);
        } else if (docChange.type == DocumentChangeType.modified) {
          await _processForegroundCall(docChange.doc, isNewCall: false);
        }
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallListenerService] Error procesando snapshot: $e',
        tag: 'CallListenerService',
      );
    }
  }

  /// Procesar llamada individual detectada en foreground
  Future<void> _processForegroundCall(
    DocumentSnapshot callDoc, {
    required bool isNewCall,
  }) async {
    try {
      final callId = callDoc.id;

      ReleaseLogger.log(
        '🔔 [CallListenerService] Llamada ${isNewCall ? 'nueva' : 'modificada'} detectada: $callId',
        tag: 'CallListenerService',
      );

      // Verificar si la app está en foreground
      final isAppInForeground = AppStateService().isAppInForeground();

      if (!isAppInForeground) {
        ReleaseLogger.log(
          '⬇️ [CallListenerService] App en background - saltando',
          tag: 'CallListenerService',
        );
        return;
      }

      // Para llamadas nuevas, aplicar validaciones legacy
      if (isNewCall) {
        // Verificar si VoIP ya está manejando esta llamada
        if (VoIPService().isCallHandledByVoIP(callId)) {
          ReleaseLogger.log(
            '📞 [CallListenerService] Llamada $callId ya manejada por VoIP - saltando',
            tag: 'CallListenerService',
          );
          return;
        }

        // Solo proceder si es iOS y app en foreground
        if (Platform.isIOS) {
          // Notificar al orchestrator
          onCallDetected?.call(callId, 'foreground');
        } else {
          ReleaseLogger.log(
            '🤖 [CallListenerService] Android - CallKit maneja todo',
            tag: 'CallListenerService',
          );
        }
      } else {
        // Para llamadas modificadas, notificar siempre (ambas plataformas)
        ReleaseLogger.log(
          '🔄 [CallListenerService] Cambio de estado detectado - notificando orchestrator',
          tag: 'CallListenerService',
        );
        onCallDetected?.call(callId, 'state_change');
      }
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallListenerService] Error procesando foreground call: $e',
        tag: 'CallListenerService',
      );
    }
  }
}
