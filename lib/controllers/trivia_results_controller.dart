import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../models/trivia.dart';
import '../models/trivia_response.dart';
import '../services/trivia/trivia_orchestrator.dart';
import '../services/trivia/trivia_results_service.dart';
import '../utils/release_logger.dart';

/// Estado de carga de resultados
enum TriviaResultsState {
  loading,
  loaded,
  error,
}

/// Controller para ver resultados y leaderboard de trivia
///
/// Responsabilidades:
/// - Cargar trivia y leaderboard en tiempo real
/// - Manejar acciones del creador (cerrar, eliminar, compartir)
/// - Mostrar mi posición si participé
class TriviaResultsController {
  // Servicios
  final TriviaOrchestrator _orchestrator;
  final FirebaseAuth _auth;

  // Estado
  TriviaResultsState _state = TriviaResultsState.loading;
  Trivia? _trivia;
  List<TriviaLeaderboardEntry> _leaderboard = [];
  TriviaLeaderboardEntry? _myPosition;
  TriviaResults? _fullResults;
  String? _errorMessage;
  bool _isProcessing = false;

  // Suscripciones
  StreamSubscription? _triviaSubscription;
  StreamSubscription? _leaderboardSubscription;
  StreamSubscription? _myPositionSubscription;

  // Callbacks
  Function(TriviaResultsState)? onStateChanged;
  Function(Trivia)? onTriviaChanged;
  Function(List<TriviaLeaderboardEntry>)? onLeaderboardChanged;
  Function(TriviaLeaderboardEntry?)? onMyPositionChanged;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function(bool)? onProcessingChanged;

  TriviaResultsController({
    TriviaOrchestrator? orchestrator,
    FirebaseAuth? auth,
  })  : _orchestrator = orchestrator ?? TriviaOrchestrator(),
        _auth = auth ?? FirebaseAuth.instance;

  // Getters
  TriviaResultsState get state => _state;
  Trivia? get trivia => _trivia;
  List<TriviaLeaderboardEntry> get leaderboard => _leaderboard;
  TriviaLeaderboardEntry? get myPosition => _myPosition;
  TriviaResults? get fullResults => _fullResults;
  String? get errorMessage => _errorMessage;
  bool get isProcessing => _isProcessing;

  String? get currentUserId => _auth.currentUser?.uid;
  bool get isCreator => _trivia?.creatorId == currentUserId;
  bool get canClose => _trivia?.canClose ?? false;
  bool get canEdit => _trivia?.isEditable ?? false;
  bool get hasSharedResults => _trivia?.hasSharedResults ?? false;
  bool get didParticipate => _myPosition != null;

  /// Obtener podio (top 3)
  List<TriviaLeaderboardEntry> get podium {
    return _leaderboard.where((e) => e.isOnPodium).toList();
  }

  /// Verificar si hay podio completo
  bool get hasFullPodium => _leaderboard.length >= 3;

  // ==================== INITIALIZATION ====================

  /// Inicializar controller y cargar datos
  Future<void> initialize(String triviaId) async {
    try {
      _setState(TriviaResultsState.loading);
      _clearError();

      ReleaseLogger.log('🏆 [TriviaResults] Inicializando para trivia: $triviaId');

      // Suscribirse a la trivia en tiempo real
      _triviaSubscription = _orchestrator.watchTrivia(triviaId).listen(
        (trivia) {
          _trivia = trivia;
          if (trivia != null) {
            onTriviaChanged?.call(trivia);
            if (_state == TriviaResultsState.loading) {
              _setState(TriviaResultsState.loaded);
            }
          } else {
            // ✅ Manejar caso de trivia no encontrada
            ReleaseLogger.error('❌ [TriviaResults] Trivia no encontrada: $triviaId');
            _setError('Trivia no encontrada');
            _setState(TriviaResultsState.error);
          }
        },
        onError: (e) {
          ReleaseLogger.error('❌ [TriviaResults] Error en stream de trivia: $e');
          _setError('Error cargando trivia');
          _setState(TriviaResultsState.error);
        },
      );

      // Suscribirse al leaderboard en tiempo real
      _leaderboardSubscription = _orchestrator.watchLeaderboard(triviaId).listen(
        (entries) {
          _leaderboard = entries;
          onLeaderboardChanged?.call(entries);
          ReleaseLogger.log('🏆 [TriviaResults] Leaderboard actualizado: ${entries.length} participantes');
        },
        onError: (e) {
          ReleaseLogger.error('❌ [TriviaResults] Error en stream de leaderboard: $e');
        },
      );

      // Suscribirse a mi posición si participé
      _myPositionSubscription = _orchestrator.watchMyPosition(triviaId).listen(
        (position) {
          _myPosition = position;
          onMyPositionChanged?.call(position);
        },
        onError: (e) {
          ReleaseLogger.error('❌ [TriviaResults] Error en stream de mi posición: $e');
        },
      );
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaResults] Error inicializando: $e');
      _setError('Error al cargar resultados');
      _setState(TriviaResultsState.error);
    }
  }

  /// Cargar resultados completos (estadísticas detalladas)
  Future<void> loadFullResults(String triviaId) async {
    try {
      _setProcessing(true);
      _fullResults = await _orchestrator.getResults(triviaId);
      ReleaseLogger.log('🏆 [TriviaResults] Resultados completos cargados');
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaResults] Error cargando resultados: $e');
      _setError('Error cargando estadísticas');
    } finally {
      _setProcessing(false);
    }
  }

  // ==================== CREATOR ACTIONS ====================

  /// Cerrar trivia manualmente
  Future<bool> closeTrivia() async {
    if (!isCreator || _trivia == null || !canClose) {
      _setError('No puedes cerrar esta trivia');
      return false;
    }

    try {
      _setProcessing(true);
      _clearError();

      ReleaseLogger.log('🔒 [TriviaResults] Cerrando trivia: ${_trivia!.id}');
      await _orchestrator.closeTrivia(_trivia!.id);

      onSuccess?.call('Trivia cerrada exitosamente');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaResults] Error cerrando trivia: $e');
      _setError('Error al cerrar la trivia');
      return false;
    } finally {
      _setProcessing(false);
    }
  }

  /// Eliminar trivia
  Future<bool> deleteTrivia() async {
    if (!isCreator || _trivia == null) {
      _setError('No puedes eliminar esta trivia');
      return false;
    }

    try {
      _setProcessing(true);
      _clearError();

      ReleaseLogger.log('🗑️ [TriviaResults] Eliminando trivia: ${_trivia!.id}');
      await _orchestrator.deleteTrivia(_trivia!.id);

      onSuccess?.call('Trivia eliminada');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaResults] Error eliminando trivia: $e');
      _setError('Error al eliminar la trivia');
      return false;
    } finally {
      _setProcessing(false);
    }
  }

  /// Compartir resultados como historia
  Future<String?> shareResults() async {
    if (!isCreator || _trivia == null || hasSharedResults) {
      _setError('No puedes compartir los resultados');
      return null;
    }

    try {
      _setProcessing(true);
      _clearError();

      ReleaseLogger.log('📤 [TriviaResults] Compartiendo resultados: ${_trivia!.id}');
      final storyId = await _orchestrator.shareResultsAsStory(_trivia!.id);

      onSuccess?.call('Resultados compartidos como historia');
      return storyId;
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaResults] Error compartiendo resultados: $e');
      _setError('Error al compartir resultados');
      return null;
    } finally {
      _setProcessing(false);
    }
  }

  // ==================== SHARING ====================

  /// Generar URL para compartir trivia
  String generateShareUrl() {
    if (_trivia == null) return '';
    return _orchestrator.generateTriviaUrl(_trivia!.id);
  }

  /// Generar deeplink para compartir trivia
  String generateShareDeeplink() {
    if (_trivia == null) return '';
    return _orchestrator.generateTriviaDeeplink(_trivia!.id);
  }

  // ==================== UTILITIES ====================

  void _setState(TriviaResultsState newState) {
    _state = newState;
    onStateChanged?.call(newState);
  }

  void _setProcessing(bool processing) {
    _isProcessing = processing;
    onProcessingChanged?.call(processing);
  }

  void _setError(String error) {
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _errorMessage = null;
  }

  void dispose() {
    _triviaSubscription?.cancel();
    _leaderboardSubscription?.cancel();
    _myPositionSubscription?.cancel();

    _trivia = null;
    _leaderboard = [];
    _myPosition = null;
    _fullResults = null;
  }
}
