import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DeepARService {
  static const MethodChannel _channel = MethodChannel('talia.deepar/ar_filters');
  static const EventChannel _eventChannel = EventChannel('talia.deepar/ar_events');

  static DeepARService? _instance;

  factory DeepARService() {
    _instance ??= DeepARService._internal();
    return _instance!;
  }

  DeepARService._internal();

  // Estados
  bool _isInitialized = false;
  bool _isRecording = false;
  String? _currentFilter;

  // Streams
  StreamSubscription? _eventSubscription;
  StreamController<DeepAREvent> _eventController = StreamController<DeepAREvent>.broadcast();

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isRecording => _isRecording;
  String? get currentFilter => _currentFilter;
  Stream<DeepAREvent> get events => _eventController.stream;

  /// Inicializar DeepAR con license key
  Future<bool> initialize({required String licenseKey}) async {
    try {
      print('🎭 Inicializando DeepAR...');

      final result = await _channel.invokeMethod('initialize', {
        'licenseKey': licenseKey,
      });

      if (result == true) {
        _isInitialized = true;
        _setupEventListener();
        print('✅ DeepAR inicializado exitosamente');
      }

      return result ?? false;
    } catch (e) {
      print('❌ Error inicializando DeepAR: $e');
      return false;
    }
  }

  /// Configurar listener de eventos nativos
  void _setupEventListener() {
    // Cancelar suscripción previa si existe
    _eventSubscription?.cancel();

    // Si el StreamController está cerrado, recrearlo
    if (_eventController.isClosed) {
      _eventController = StreamController<DeepAREvent>.broadcast();
    }

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        try {
          final eventMap = Map<String, dynamic>.from(event);
          final deepAREvent = DeepAREvent.fromMap(eventMap);

          // Solo agregar evento si el controller no está cerrado
          if (!_eventController.isClosed) {
            _eventController.add(deepAREvent);
          }

          // Actualizar estado interno
          if (deepAREvent.type == DeepAREventType.initialized) {
            _isInitialized = true;
          } else if (deepAREvent.type == DeepAREventType.filterChanged) {
            _currentFilter = deepAREvent.data['filterPath'];
          }
        } catch (e) {
          print('❌ Error procesando evento DeepAR: $e');
        }
      },
      onError: (error) {
        print('❌ Error en eventos DeepAR: $error');
        if (!_eventController.isClosed) {
          _eventController.addError(error);
        }
      },
    );
  }

  /// Cambiar filtro AR
  Future<bool> switchFilter(String filterPath) async {
    if (!_isInitialized) {
      print('❌ DeepAR no está inicializado');
      return false;
    }

    try {
      print('🔄 Cambiando filtro: $filterPath');

      final result = await _channel.invokeMethod('switchFilter', {
        'filterPath': filterPath,
      });

      if (result == true) {
        _currentFilter = filterPath;
        print('✅ Filtro cambiado: $filterPath');
      }

      return result ?? false;
    } catch (e) {
      print('❌ Error cambiando filtro: $e');
      return false;
    }
  }

  /// Remover filtro actual
  Future<bool> removeFilter() async {
    return await switchFilter('');
  }

  /// Iniciar grabación
  Future<bool> startRecording({
    required String outputPath,
    int width = 1280,
    int height = 720,
    int bitRate = 4000000,
  }) async {
    if (!_isInitialized) {
      print('❌ DeepAR no está inicializado');
      return false;
    }

    try {
      print('🎬 Iniciando grabación: $outputPath');

      final result = await _channel.invokeMethod('startRecording', {
        'outputPath': outputPath,
        'width': width,
        'height': height,
        'bitRate': bitRate,
      });

      if (result == true) {
        _isRecording = true;
        print('✅ Grabación iniciada');
      }

      return result ?? false;
    } catch (e) {
      print('❌ Error iniciando grabación: $e');
      return false;
    }
  }

  /// Parar grabación
  Future<bool> stopRecording() async {
    if (!_isInitialized || !_isRecording) {
      print('❌ No hay grabación en progreso');
      return false;
    }

    try {
      print('⏹️ Deteniendo grabación...');

      final result = await _channel.invokeMethod('stopRecording');

      if (result == true) {
        _isRecording = false;
        print('✅ Grabación detenida');
      }

      return result ?? false;
    } catch (e) {
      print('❌ Error deteniendo grabación: $e');
      return false;
    }
  }

  /// Tomar screenshot
  Future<Uint8List?> takeScreenshot() async {
    if (!_isInitialized) {
      print('❌ DeepAR no está inicializado');
      return null;
    }

    try {
      print('📸 Tomando screenshot...');

      final result = await _channel.invokeMethod('takeScreenshot');

      if (result != null) {
        print('✅ Screenshot tomado');
        return Uint8List.fromList(result.cast<int>());
      }

      return null;
    } catch (e) {
      print('❌ Error tomando screenshot: $e');
      return null;
    }
  }

  /// Cambiar cámara (frontal/trasera)
  Future<bool> switchCamera() async {
    if (!_isInitialized) {
      print('❌ DeepAR no está inicializado');
      return false;
    }

    try {
      print('🔄 Cambiando cámara...');

      final result = await _channel.invokeMethod('switchCamera');

      if (result == true) {
        print('✅ Cámara cambiada');
      }

      return result ?? false;
    } catch (e) {
      print('❌ Error cambiando cámara: $e');
      return false;
    }
  }

  /// Obtener filtros disponibles
  Future<List<String>> getAvailableFilters() async {
    try {
      final result = await _channel.invokeMethod('getAvailableFilters');
      return List<String>.from(result ?? []);
    } catch (e) {
      print('❌ Error obteniendo filtros: $e');
      return [];
    }
  }

  /// Pausar procesamiento AR
  Future<void> pause() async {
    if (_isInitialized) {
      await _channel.invokeMethod('pause');
    }
  }

  /// Reanudar procesamiento AR
  Future<void> resume() async {
    if (_isInitialized) {
      await _channel.invokeMethod('resume');
    }
  }

  /// Iniciar/reiniciar cámara
  Future<void> startCamera() async {
    try {
      await _channel.invokeMethod('startCamera');
      print('▶️ Cámara DeepAR iniciada');
    } catch (e) {
      print('❌ Error iniciando cámara DeepAR: $e');
    }
  }

  /// Detener cámara (para limpiar recursos cuando se cierra la pantalla)
  Future<void> stopCamera() async {
    try {
      await _channel.invokeMethod('stopCamera');
      print('⏹️ Cámara DeepAR detenida');
    } catch (e) {
      print('❌ Error deteniendo cámara DeepAR: $e');
    }
  }

  /// Pausar temporalmente (para navegación entre pantallas)
  Future<void> pauseTemporarily() async {
    try {
      await _eventSubscription?.cancel();
      _eventSubscription = null;
      print('⏸️ DeepAR temporalmente pausado');
    } catch (e) {
      print('❌ Error pausando DeepAR: $e');
    }
  }

  /// Limpiar recursos completamente
  Future<void> dispose() async {
    try {
      await _eventSubscription?.cancel();

      // Solo cerrar el StreamController si no está ya cerrado
      if (!_eventController.isClosed) {
        await _eventController.close();
      }

      if (_isInitialized) {
        await _channel.invokeMethod('dispose');
        _isInitialized = false;
        _isRecording = false;
        _currentFilter = null;
      }

      print('✅ DeepAR resources disposed');
    } catch (e) {
      print('❌ Error disposing DeepAR: $e');
    }
  }
}

/// Widget nativo para mostrar preview de DeepAR
class DeepARPreview extends StatelessWidget {
  final Function(int viewId)? onPlatformViewCreated;
  final double? width;
  final double? height;

  const DeepARPreview({
    Key? key,
    this.onPlatformViewCreated,
    this.width,
    this.height,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    const String viewType = 'talia.deepar/ar_preview';

    return SizedBox(
      width: width,
      height: height,
      child: _buildPlatformView(viewType),
    );
  }

  Widget _buildPlatformView(String viewType) {
    // Android
    if (Platform.isAndroid) {
      return AndroidView(
        viewType: viewType,
        onPlatformViewCreated: onPlatformViewCreated,
      );
    }

    // iOS
    return UiKitView(
      viewType: viewType,
      onPlatformViewCreated: onPlatformViewCreated,
    );
  }
}

/// Eventos de DeepAR
class DeepAREvent {
  final DeepAREventType type;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  DeepAREvent({
    required this.type,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory DeepAREvent.fromMap(Map<String, dynamic> map) {
    return DeepAREvent(
      type: DeepAREventType.values.firstWhere(
        (e) => e.toString().split('.').last == map['type'],
        orElse: () => DeepAREventType.unknown,
      ),
      data: Map<String, dynamic>.from(map['data'] ?? {}),
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] ?? 0),
    );
  }
}

/// Tipos de eventos DeepAR
enum DeepAREventType {
  initialized,
  filterChanged,
  recordingStarted,
  recordingStopped,
  screenshotTaken,
  cameraSwitch,
  error,
  unknown,
}

/// Filtros AR predefinidos
class DeepARFilters {
  static const String none = '';
  static const String aviators = 'aviators.deepar';
  static const String beard = 'beard.deepar';
  static const String bigmouth = 'bigmouth.deepar';
  static const String dalmatian = 'dalmatian.deepar';
  static const String flowers = 'flowers.deepar';
  static const String koala = 'koala.deepar';
  static const String lion = 'lion.deepar';
  static const String mudMask = 'mudmask.deepar';
  static const String mustache = 'mustache.deepar';
  static const String neonDevil = 'neondevil.deepar';
  static const String pug = 'pug.deepar';
  static const String slash = 'slash.deepar';
  static const String sleepingMask = 'sleepingmask.deepar';
  static const String smallFace = 'smallface.deepar';
  static const String teddyCigar = 'teddycigar.deepar';
  static const String tripleface = 'tripleface.deepar';
  static const String twistedFace = 'twistedface.deepar';
  static const String vendetta = 'Vendetta.deepar';
  static const String baseBeauty = 'baseBeauty.deepar';
  static const String eightBitHearts = '8bitHearts.deepar';
  static const String elephantTrunk = 'Elephant_Trunk.deepar';
  static const String emotionMeter = 'Emotion_Meter.deepar';
  static const String emotionsExaggerator = 'Emotions_Exaggerator.deepar';
  static const String fireEffect = 'Fire_Effect.deepar';
  static const String hope = 'Hope.deepar';
  static const String humanoid = 'Humanoid.deepar';
  static const String makeupLook = 'MakeupLook.deepar';
  static const String neonDevilHorns = 'Neon_Devil_Horns.deepar';
  static const String pingPong = 'Ping_Pong.deepar';
  static const String snail = 'Snail.deepar';
  static const String splitViewLook = 'Split_View_Look.deepar';
  static const String stallone = 'Stallone.deepar';
  static const String vendettaMask = 'Vendetta_Mask.deepar';
  static const String burningEffect = 'burning_effect.deepar';
  static const String flowerFace = 'flower_face.deepar';
  static const String galaxyBackground = 'galaxy_background.deepar';
  static const String vikingHelmet = 'viking_helmet.deepar';

  /// Lista de todos los filtros disponibles
  static const List<String> all = [
    none,
    aviators,
    beard,
    bigmouth,
    dalmatian,
    flowers,
    koala,
    lion,
    mudMask,
    mustache,
    neonDevil,
    pug,
    slash,
    sleepingMask,
    smallFace,
    teddyCigar,
    tripleface,
    twistedFace,
    vendetta,
    baseBeauty,
    eightBitHearts,
    elephantTrunk,
    emotionMeter,
    emotionsExaggerator,
    fireEffect,
    hope,
    humanoid,
    makeupLook,
    neonDevilHorns,
    pingPong,
    snail,
    splitViewLook,
    stallone,
    vendettaMask,
    burningEffect,
    flowerFace,
    galaxyBackground,
    vikingHelmet,
  ];

  /// Obtener nombre legible del filtro
  static String getDisplayName(String filterPath) {
    switch (filterPath) {
      case none: return 'Sin filtro';
      case aviators: return 'Gafas de sol';
      case beard: return 'Barba';
      case bigmouth: return 'Boca grande';
      case dalmatian: return 'Dálmata';
      case flowers: return 'Flores';
      case koala: return 'Koala';
      case lion: return 'León';
      case mudMask: return 'Máscara de barro';
      case mustache: return 'Bigote';
      case neonDevil: return 'Diablo neón';
      case pug: return 'Pug';
      case slash: return 'Slash';
      case sleepingMask: return 'Máscara para dormir';
      case smallFace: return 'Cara pequeña';
      case teddyCigar: return 'Oso con cigarro';
      case tripleface: return 'Triple cara';
      case twistedFace: return 'Cara retorcida';
      case vendetta: return 'Vendetta';
      case baseBeauty: return 'Base Beauty';
      case eightBitHearts: return '8-Bit Hearts';
      case elephantTrunk: return 'Elephant Trunk';
      case emotionMeter: return 'Emotion Meter';
      case emotionsExaggerator: return 'Emotions Exaggerator';
      case fireEffect: return 'Fire Effect';
      case hope: return 'Hope';
      case humanoid: return 'Humanoid';
      case makeupLook: return 'Makeup Look';
      case neonDevilHorns: return 'Neon Devil Horns';
      case pingPong: return 'Ping Pong';
      case snail: return 'Snail';
      case splitViewLook: return 'Split View Look';
      case stallone: return 'Stallone';
      case vendettaMask: return 'Vendetta Mask';
      case burningEffect: return 'Burning Effect';
      case flowerFace: return 'Flower Face';
      case galaxyBackground: return 'Galaxy Background';
      case vikingHelmet: return 'Viking Helmet';
      default: return filterPath.split('.').first;
    }
  }
}