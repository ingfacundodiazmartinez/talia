import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../voip_service.dart';
import '../app_state_service.dart';
import 'call_stack_navigator.dart';
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

  // Callbacks para notificar al orchestrator
  Function(String callId, String source)? onCallDetected;
  Function(String callId)? onCallEnded;

  /// Inicializar listeners
  Future<void> initialize({
    required Function(String callId, String source) onCallDetected,
    Function(String callId)? onCallEnded,
  }) async {
    // ✅ DEBUG: Log detallado del estado al entrar a initialize
    ReleaseLogger.log(
      '🚀 [CallListenerService] INITIALIZE llamado - isListening=$_isListening, subscription=${_foregroundCallSubscription != null}',
      tag: 'CallListenerService',
    );

    if (_isListening) {
      ReleaseLogger.log(
        '⚠️ [CallListenerService] Listeners ya inicializados - saltando (ESTO PUEDE SER EL PROBLEMA)',
        tag: 'CallListenerService',
      );
      return;
    }

    this.onCallDetected = onCallDetected;
    this.onCallEnded = onCallEnded;

    ReleaseLogger.log(
      '🚀 [CallListenerService] Procediendo con inicialización de listeners...',
      tag: 'CallListenerService',
    );

    _setupForegroundCallListener();

    _isListening = true;

    ReleaseLogger.log(
      '✅ [CallListenerService] Listeners configurados exitosamente',
      tag: 'CallListenerService',
    );
  }

  /// Dispose listeners
  void dispose() {
    // ✅ DEBUG: Logging detallado antes de dispose
    ReleaseLogger.log(
      '🧹 [CallListenerService] DISPOSE INICIADO - subscription=${_foregroundCallSubscription != null}, listening=$_isListening',
      tag: 'CallListenerService',
    );

    // ✅ ROOT CAUSE FIX: Safe cancel para evitar MissingPluginException
    if (_foregroundCallSubscription != null) {
      try {
        _foregroundCallSubscription!.cancel();
        ReleaseLogger.log(
          '✅ [CallListenerService] Subscription cancelada exitosamente',
          tag: 'CallListenerService',
        );
      } catch (e) {
        // ✅ IGNORAR MissingPluginException - esto pasa cuando el plugin nativo
        // ya fue destruido (hot restart, navegación, etc.)
        ReleaseLogger.log(
          '⚠️ [CallListenerService] Error cancelando subscription (ignorando): $e',
          tag: 'CallListenerService',
        );
      }
    }
    _foregroundCallSubscription = null; // ✅ Explicitly set to null
    _isListening = false;
    onCallDetected = null;
    onCallEnded = null;

    ReleaseLogger.log(
      '🧹 [CallListenerService] DISPOSE COMPLETADO - subscription=null, listening=false',
      tag: 'CallListenerService',
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // LISTENER HEALTH & RECOVERY
  // ═══════════════════════════════════════════════════════════════

  /// Check if the listener is currently active
  bool get isHealthy {
    final healthy = _foregroundCallSubscription != null && _isListening;
    ReleaseLogger.log(
      '🔍 [CallListenerService] Health check: subscription=${_foregroundCallSubscription != null}, listening=$_isListening, healthy=$healthy',
      tag: 'CallListenerService',
    );

    return healthy;
  }

  /// ✅ NUEVA FUNCIÓN: Detección avanzada de listener zombificado
  Future<bool> detectZombifiedListener() async {
    final basicHealthy = isHealthy;

    if (!basicHealthy) {
      ReleaseLogger.log(
        '⚠️ [CallListenerService] Listener básicamente no saludable - no zombificado, simplemente muerto',
        tag: 'CallListenerService',
      );
      return false; // No zombificado, simplemente no inicializado
    }

    // ✅ TEST AVANZADO: Si parece saludable, verificar si realmente recibe eventos
    ReleaseLogger.log(
      '🔍 [CallListenerService] Listener parece saludable, verificando funcionalidad real...',
      tag: 'CallListenerService',
    );

    final foundDocuments = await _testFirestoreConnection();

    if (foundDocuments) {
      ReleaseLogger.log(
        '⚠️ [ZOMBIFIED DETECTED] Listener reporta healthy=true pero hay docs que debería detectar',
        tag: 'CallListenerService',
      );
      return true; // ZOMBIFICADO: healthy pero no funcional
    }

    ReleaseLogger.log(
      '✅ [CallListenerService] Listener genuinamente saludable - no hay docs nuevos',
      tag: 'CallListenerService',
    );
    return false; // No zombificado
  }

  /// Test manual de conexión Firestore y detección de listener zombificado
  Future<bool> _testFirestoreConnection() async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.log(
          '⚠️ [DEBUG TEST] No hay usuario autenticado para test',
          tag: 'CallListenerService',
        );
        return false;
      }

      final cutoffTime = DateTime.now().subtract(Duration(minutes: 5));

      ReleaseLogger.log(
        '🔍 [DEBUG TEST] Ejecutando test manual de Firestore...',
        tag: 'CallListenerService',
      );

      final testSnapshot = await FirebaseFirestore.instance
          .collection('calls')
          .where('participants', arrayContains: currentUserId)
          .where('createdAt', isGreaterThan: cutoffTime)
          .get();

      final foundDocs = testSnapshot.docs.length;
      ReleaseLogger.log(
        '🔍 [DEBUG TEST] Test manual Firestore: $foundDocs docs encontrados',
        tag: 'CallListenerService',
      );

      for (var doc in testSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>?;
        final participants = data?['participants'];
        final createdAt = data?['createdAt'];
        ReleaseLogger.log(
          '🔍 [DEBUG TEST] Doc: ${doc.id}, participants=$participants, createdAt=$createdAt',
          tag: 'CallListenerService',
        );
      }

      // ✅ DETECCIÓN DE LISTENER ZOMBIFICADO:
      // Si el test manual encuentra documentos pero el listener no disparó recientemente,
      // es probable que esté zombificado
      return foundDocs > 0;
    } catch (e) {
      ReleaseLogger.log(
        '❌ [DEBUG TEST] Error en test manual: $e',
        tag: 'CallListenerService',
      );
      return false;
    }
  }

  /// Attempt to recover the listener if it was disposed
  Future<bool> attemptRecovery({
    required Function(String callId, String source) onCallDetected,
    Function(String callId)? onCallEnded,
  }) async {
    // Check if we're already healthy
    if (isHealthy) {
      ReleaseLogger.log(
        '✅ [CallListenerService] Listener is already healthy',
        tag: 'CallListenerService',
      );
      return true;
    }

    ReleaseLogger.log(
      '🔄 [CallListenerService] Listener was disposed - attempting recovery',
      tag: 'CallListenerService',
    );

    try {
      // Re-initialize the listener
      await initialize(
        onCallDetected: onCallDetected,
        onCallEnded: onCallEnded,
      );

      ReleaseLogger.log(
        '✅ [CallListenerService] Listener recovery successful',
        tag: 'CallListenerService',
      );
      return true;
    } catch (e) {
      ReleaseLogger.error(
        '❌ [CallListenerService] Listener recovery failed: $e',
        tag: 'CallListenerService',
      );
      return false;
    }
  }

  /// This should be called periodically to ensure listener health
  Future<void> ensureListenerHealth({
    required Function(String callId, String source) onCallDetected,
    Function(String callId)? onCallEnded,
  }) async {
    if (!isHealthy) {
      ReleaseLogger.log(
        '⚠️ [CallListenerService] Listener health check failed - recovering',
        tag: 'CallListenerService',
      );
      await attemptRecovery(
        onCallDetected: onCallDetected,
        onCallEnded: onCallEnded,
      );
    }
  }

  /// ✅ FIX ESCENARIO CALLKIT: Forzar refresh completo del listener
  Future<void> forceListenerRefresh({
    required Function(String callId, String source) onCallDetected,
    Function(String callId)? onCallEnded,
  }) async {
    ReleaseLogger.log(
      '🔄 [CallListenerService] Forzando refresh completo del listener (dispose + re-initialize)',
      tag: 'CallListenerService',
    );

    // Forzar dispose completo
    dispose();

    // Esperar un momento
    await Future.delayed(Duration(milliseconds: 100));

    // Re-inicializar completamente
    await initialize(
      onCallDetected: onCallDetected,
      onCallEnded: onCallEnded,
    );

    ReleaseLogger.log(
      '✅ [CallListenerService] Listener refresh completado',
      tag: 'CallListenerService',
    );
  }

  /// Configurar listener para detectar llamadas en foreground
  void _setupForegroundCallListener() {
    // ✅ DEBUG AUTH: Verificar estado de autenticación en detalle
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUserId = currentUser?.uid;

    ReleaseLogger.log(
      '🔐 [DEBUG AUTH] Estado de autenticación: user=${currentUser != null}, uid=$currentUserId, isAnonymous=${currentUser?.isAnonymous}, emailVerified=${currentUser?.emailVerified}',
      tag: 'CallListenerService',
    );

    if (currentUserId == null) {
      ReleaseLogger.error(
        '❌ [CallListenerService] No hay usuario autenticado - currentUser=${currentUser != null}',
        tag: 'CallListenerService',
      );
      return;
    }

    ReleaseLogger.log(
      '👂 [CallListenerService] Configurando listener foreground para usuario: $currentUserId',
      tag: 'CallListenerService',
    );

    // ✅ DEBUG: Agregar logging detallado del estado antes de configurar
    ReleaseLogger.log(
      '🔍 [DEBUG] Estado antes de setup: _foregroundCallSubscription=${_foregroundCallSubscription != null}, _isListening=$_isListening',
      tag: 'CallListenerService',
    );

    try {
      final callsCollection = FirebaseFirestore.instance.collection('calls');

      // ✅ FIX CUTOFFTIME: Siempre usar tiempo ACTUAL para evitar filtros obsoletos
      final cutoffTime = DateTime.now().subtract(Duration(minutes: 5));
      final now = DateTime.now();

      ReleaseLogger.log(
        '🔍 [CallListenerService] Configurando query FRESH: participants arrayContains $currentUserId, createdAt > ${cutoffTime.toIso8601String()}',
        tag: 'CallListenerService',
      );

      // ✅ DEEP DEBUG: Log tiempo actual vs cutoff (FRESH cada vez)
      final cutoffDiff = now.difference(cutoffTime).inMinutes;
      ReleaseLogger.log(
        '🔍 [DEBUG DEEP] Time check FRESH: now=${now.toIso8601String()}, cutoff=${cutoffTime.toIso8601String()}, diff=${cutoffDiff}min',
        tag: 'CallListenerService',
      );

      // ✅ FIX ÍNDICE FIRESTORE: Usar array participants para consulta eficiente y segura
      // Estructura híbrida: participants (array) para consultas + participantDetails (mapa) para estados

      // ✅ DEBUG ROOT CAUSE: Verificar identidad de FirebaseFirestore instance
      final firestoreInstance = FirebaseFirestore.instance;
      final firestoreHash = firestoreInstance.hashCode;

      ReleaseLogger.log(
        '🔄 [DEBUG] Creando nueva subscription - FirestoreInstance: $firestoreHash, UserId: $currentUserId',
        tag: 'CallListenerService',
      );

      // ✅ DEBUG QUERY: Verificar que la query está bien formada
      ReleaseLogger.log(
        '🔍 [DEBUG QUERY] Query details: collection=calls, participants arrayContains $currentUserId, createdAt > ${cutoffTime.millisecondsSinceEpoch}',
        tag: 'CallListenerService',
      );

      // ✅ TEMPORAL DEBUG: Hacer query sin filtros para ver todos los documentos
      callsCollection.limit(10).get().then((allCallsSnapshot) {
        ReleaseLogger.log(
          '🔍 [DEBUG TEMP] Total calls en collection: ${allCallsSnapshot.docs.length}',
          tag: 'CallListenerService',
        );
        for (var doc in allCallsSnapshot.docs) {
          final data = doc.data() as Map<String, dynamic>?;
          final participants = data?['participants'];
          final createdAt = data?['createdAt'];
          ReleaseLogger.log(
            '🔍 [DEBUG TEMP] Call ${doc.id}: participants=$participants, createdAt=$createdAt',
            tag: 'CallListenerService',
          );
        }
      }).catchError((e) {
        ReleaseLogger.log(
          '🔍 [DEBUG TEMP] Error getting all calls: $e',
          tag: 'CallListenerService',
        );
      });

      _foregroundCallSubscription = callsCollection
          .where('participants', arrayContains: currentUserId)
          .where(
            'createdAt',
            isGreaterThan: cutoffTime,
          )
          .snapshots()
          .listen(
            (snapshot) {
              // ✅ DEBUG AUTH: Verificar userId en el momento del snapshot
              final snapshotUserId = FirebaseAuth.instance.currentUser?.uid;

              ReleaseLogger.log(
                '📊 [DEBUG DEEP] Firestore listener triggered! timestamp=${DateTime.now().millisecondsSinceEpoch}, docs=${snapshot.docs.length}, originalUserId=$currentUserId, currentUserId=$snapshotUserId',
                tag: 'CallListenerService',
              );

              // ✅ DEEP DEBUG: Log todas las llamadas recibidas
              for (var doc in snapshot.docs) {
                final data = doc.data() as Map<String, dynamic>?;
                final participants = data?['participants'] as List<dynamic>?;
                final createdAt = data?['createdAt'];

                ReleaseLogger.log(
                  '📋 [DEBUG DEEP] Call doc: ${doc.id}, participants: $participants, createdAt: $createdAt',
                  tag: 'CallListenerService',
                );
              }

              ReleaseLogger.log(
                '📊 [CallListenerService] Firestore listener triggered with ${snapshot.docs.length} docs',
                tag: 'CallListenerService',
              );
              _handleForegroundCallSnapshot(snapshot);
            },
            onError: (error) {
              ReleaseLogger.error(
                '❌ [CallListenerService] Error en listener foreground: $error',
                tag: 'CallListenerService',
              );
            },
            onDone: () {
              // ✅ DEBUG: Log cuando la subscription se cierra
              ReleaseLogger.log(
                '🔚 [DEBUG] Firestore subscription CLOSED/DONE - esto puede indicar por qué se pierde',
                tag: 'CallListenerService',
              );
            },
          );

      // ✅ DEBUG: Log después de crear subscription
      ReleaseLogger.log(
        '✅ [DEBUG] Subscription creada: ${_foregroundCallSubscription != null}',
        tag: 'CallListenerService',
      );

      ReleaseLogger.log(
        '✅ [CallListenerService] Firestore listener configurado exitosamente',
        tag: 'CallListenerService',
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
      ReleaseLogger.log(
        '📊 [CallListenerService] Snapshot recibido: ${snapshot.docChanges.length} cambios',
        tag: 'CallListenerService',
      );

      for (var docChange in snapshot.docChanges) {
        ReleaseLogger.log(
          '📋 [CallListenerService] Cambio detectado: ${docChange.type.name} para call ${docChange.doc.id}',
          tag: 'CallListenerService',
        );

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
      // ✅ DEBUG ROOT CAUSE: Verificar estado de auth cuando se procesa llamada
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      final callId = callDoc.id;
      final callData = callDoc.data() as Map<String, dynamic>?;

      ReleaseLogger.log(
        '🔔 [CallListenerService] Llamada ${isNewCall ? 'nueva' : 'modificada'} detectada: $callId (currentUser: $currentUserId)',
        tag: 'CallListenerService',
      );

      // ✅ FIX: Para llamadas modificadas, verificar si terminaron
      if (!isNewCall && callData != null) {
        final endedAt = callData['endedAt'];
        if (endedAt != null) {
          ReleaseLogger.log(
            '🔚 [CallListenerService] Llamada $callId terminada - notificando onCallEnded',
            tag: 'CallListenerService',
          );
          onCallEnded?.call(callId);
          return; // No procesar más esta llamada
        }
      }

      // Verificar si la app está en foreground
      final isAppInForeground = AppStateService().isAppInForeground();

      ReleaseLogger.log(
        '📱 [CallListenerService] App state check: isAppInForeground = $isAppInForeground',
        tag: 'CallListenerService',
      );

      // ✅ DEEP DEBUG: Log app state más detallado
      ReleaseLogger.log(
        '📱 [DEBUG DEEP] AppStateService full state: ${AppStateService().toString()}',
        tag: 'CallListenerService',
      );

      if (!isAppInForeground) {
        ReleaseLogger.log(
          '⬇️ [CallListenerService] App en background - saltando llamada $callId',
          tag: 'CallListenerService',
        );
        return;
      }

      // Para llamadas nuevas, aplicar validaciones legacy
      if (isNewCall) {
        ReleaseLogger.log(
          '🆕 [CallListenerService] Procesando llamada nueva: $callId',
          tag: 'CallListenerService',
        );

        // ✅ FIX ESCENARIO CALLKIT: Verificar estado VoIP con diagnóstico
        VoIPService().debugVoIPTracking();
        final isHandledByVoIP = VoIPService().isCallHandledByVoIP(callId);
        ReleaseLogger.log(
          '📞 [DEBUG DEEP] VoIP check para callId=$callId: isHandledByVoIP = $isHandledByVoIP',
          tag: 'CallListenerService',
        );

        if (isHandledByVoIP) {
          ReleaseLogger.log(
            '📞 [DEBUG DEEP] ⚠️ BLOQUEADO POR VOIP: Llamada $callId ya manejada por VoIP - saltando',
            tag: 'CallListenerService',
          );
          return;
        }

        // ✅ FIX: Verificar si ya hay una CallScreen activa para evitar navegaciones duplicadas
        final hasActiveCallScreen = CallStackNavigator.hasActiveCall;
        ReleaseLogger.log(
          '📱 [DEBUG DEEP] CallScreen check: hasActiveCallScreen = $hasActiveCallScreen',
          tag: 'CallListenerService',
        );

        if (hasActiveCallScreen) {
          ReleaseLogger.log(
            '📱 [DEBUG DEEP] ⚠️ BLOQUEADO POR CALLSCREEN: Ya hay CallScreen activa - saltando navegación para $callId',
            tag: 'CallListenerService',
          );
          return;
        }

        // ✅ FIX: En foreground, AMBAS plataformas necesitan IncomingCallScreen
        // Android: CallKit nativo NO muestra nada en foreground
        // iOS: También necesita nuestra UI en foreground
        ReleaseLogger.log(
          '📱 [CallListenerService] App en foreground - notificando orchestrator para mostrar IncomingCallScreen',
          tag: 'CallListenerService',
        );
        onCallDetected?.call(callId, 'foreground');
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
