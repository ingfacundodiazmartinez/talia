import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import '../utils/release_logger.dart';

/// Servicio de reconocimiento de voz local para transcripción de audio
///
/// Usado para transcribir audio durante la grabación y enviar la transcripción
/// al servidor para moderación (en lugar de usar APIs de pago como Whisper).
///
/// NOTA: En iOS, speech_to_text y audio recording pueden conflictuar.
/// Este servicio es tolerante a fallos y no crasheará la app si STT falla.
class SpeechToTextService {
  static final SpeechToTextService _instance = SpeechToTextService._internal();
  factory SpeechToTextService() => _instance;
  SpeechToTextService._internal();

  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  bool _isListening = false;
  String _currentTranscription = '';
  String _finalTranscription = '';

  // Locale preferido (español Argentina por defecto)
  String _localeId = 'es_AR';

  /// Stream controller para notificar cambios en la transcripción
  final _transcriptionController = StreamController<String>.broadcast();
  Stream<String> get transcriptionStream => _transcriptionController.stream;

  /// Indica si el servicio está escuchando
  bool get isListening => _isListening;

  /// Obtiene la transcripción actual (en progreso)
  String get currentTranscription => _currentTranscription;

  /// Obtiene la transcripción final después de detener
  String get finalTranscription => _finalTranscription;

  /// Inicializa el servicio de reconocimiento de voz
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _isInitialized = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
        debugLogging: false,
      );

      if (_isInitialized) {
        // Buscar locale español disponible
        final locales = await _speech.locales();
        final spanishLocale = locales.firstWhere(
          (l) => l.localeId.startsWith('es'),
          orElse: () => locales.first,
        );
        _localeId = spanishLocale.localeId;
        ReleaseLogger.log(
          '🎤 SpeechToText inicializado con locale: $_localeId',
          tag: 'STT',
        );
      }

      return _isInitialized;
    } catch (e) {
      ReleaseLogger.error('Error inicializando SpeechToText: $e', tag: 'STT');
      return false;
    }
  }

  /// Inicia el reconocimiento de voz
  ///
  /// Llamar al inicio de la grabación de audio para capturar transcripción
  Future<bool> startListening() async {
    if (!_isInitialized) {
      final success = await initialize();
      if (!success) return false;
    }

    if (_isListening) return true;

    try {
      _currentTranscription = '';
      _finalTranscription = '';

      await _speech.listen(
        onResult: _onResult,
        localeId: _localeId,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
        listenFor: const Duration(minutes: 5), // Máximo 5 minutos
        pauseFor: const Duration(seconds: 10), // Pausa larga permitida
      );

      _isListening = true;
      ReleaseLogger.log('🎤 Iniciando reconocimiento de voz', tag: 'STT');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error iniciando reconocimiento: $e', tag: 'STT');
      return false;
    }
  }

  /// Detiene el reconocimiento de voz y retorna la transcripción final
  Future<String> stopListening() async {
    if (!_isListening) return _finalTranscription;

    try {
      await _speech.stop();
      _isListening = false;

      // Guardar transcripción final
      _finalTranscription = _currentTranscription.trim();

      ReleaseLogger.log(
        '🎤 Reconocimiento detenido. Transcripción: "${_finalTranscription.length > 50 ? '${_finalTranscription.substring(0, 50)}...' : _finalTranscription}"',
        tag: 'STT',
      );

      return _finalTranscription;
    } catch (e) {
      ReleaseLogger.error('Error deteniendo reconocimiento: $e', tag: 'STT');
      return _currentTranscription.trim();
    }
  }

  /// Cancela el reconocimiento sin guardar
  Future<void> cancel() async {
    if (!_isListening) return;

    try {
      await _speech.cancel();
      _isListening = false;
      _currentTranscription = '';
      _finalTranscription = '';
      ReleaseLogger.log('🎤 Reconocimiento cancelado', tag: 'STT');
    } catch (e) {
      ReleaseLogger.error('Error cancelando reconocimiento: $e', tag: 'STT');
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    _currentTranscription = result.recognizedWords;
    _transcriptionController.add(_currentTranscription);

    if (result.finalResult) {
      _finalTranscription = _currentTranscription;
    }
  }

  void _onStatus(String status) {
    ReleaseLogger.log('🎤 STT Status: $status', tag: 'STT');

    if (status == 'done' || status == 'notListening') {
      _isListening = false;
    }
  }

  void _onError(dynamic error) {
    ReleaseLogger.error('🎤 STT Error: $error', tag: 'STT');
    _isListening = false;
  }

  /// Libera recursos
  void dispose() {
    _speech.cancel();
    _transcriptionController.close();
  }
}
