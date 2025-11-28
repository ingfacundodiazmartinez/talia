import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/permission_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../services/deepar_service.dart';
import '../services/story_service_refactored.dart';
import '../services/stickers_service.dart';
import '../services/character_service.dart';
import '../services/usage_limits_service.dart';
import '../services/subscription_service.dart';
import '../services/story_upload_progress_service.dart';
import '../models/character.dart';
import '../widgets/character_selector_dialog.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de la cámara de historias
///
/// Responsabilidades:
/// - Gestión de cámara y permisos
/// - Procesamiento de filtros y transformaciones
/// - Subida de historias a Firebase
/// - Gestión de límites de uso y suscripciones
/// - Coordinación entre servicios
///
/// ## DeepAR License Keys:
/// Las keys están configuradas por plataforma (iOS/Android).
/// Para producción, actualizar las keys desde https://developer.deepar.ai/
class StoryCameraController {
  final String userId;

  // DeepAR License Keys por plataforma
  static const String _iosLicenseKey =
      'bc5821fe04221f7349429783cced44ddbe6006d0287c4397dc97fc5dd993a843429712eda6fe98c9';
  static const String _androidLicenseKey =
      'e54c25aaa8b14776f4837d0c406f91bebb6f9652716847c37004a458645242ccce15c78ea3f1084b';

  // Servicios privados
  final DeepARService _deepARService;
  final StoryService _storyService;
  final StickersService _stickersService;
  final CharacterService _characterService;
  final UsageLimitsService _usageLimitsService;
  final SubscriptionService _subscriptionService;
  final StoryUploadProgressService _uploadProgressService;
  final PermissionService _permissionService;
  final ImagePicker _imagePicker;

  // Estado de la cámara
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _hasCameraPermissions = false;
  bool _hasInitializationFailed = false;
  int _selectedCameraIndex = 0; // Will be set to front camera in initialization

  // Estado de filtros
  String? _selectedFilter;
  String? _selectedARFilter = DeepARFilters.none;
  String _filterType = 'color';
  bool _isDeepARInitialized = false;
  int _deepARReinitCounter = 0;
  bool _hasCleanedUpDeepAR = false;

  // Estado de grabación
  bool _isRecordingVideo = false;
  String? _recordedVideoPath;
  Timer? _recordingTimer;
  int _recordingSecondsRemaining = 10;

  // Estado de controles de cámara (flash, zoom, exposure)
  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentExposure = 0.0;
  double _minExposure = 0.0;
  double _maxExposure = 0.0;

  // Estado de carga y procesamiento
  bool _isLoading = false;
  bool _isLoadingStickers = false;
  List<StickerMetadata> _stickerMetadata = [];

  // Estado de modales para cleanup
  BuildContext? _activeProgressDialogContext;
  bool _isProgressDialogOpen = false;

  // Callbacks para comunicación con el screen
  Function(String)? onError;
  Function(String)? onSuccess;
  Function()? onPermissionDenied;
  Function()? onPermissionGranted; // Nuevo callback para cuando se conceden permisos
  Function()? onCameraInitialized;
  Function(bool)? onLoadingChanged;
  Function(int)? onRecordingTimeChanged;

  // Constructor
  StoryCameraController({
    required this.userId,
    DeepARService? deepARService,
    StoryService? storyService,
    StickersService? stickersService,
    CharacterService? characterService,
    UsageLimitsService? usageLimitsService,
    SubscriptionService? subscriptionService,
    StoryUploadProgressService? uploadProgressService,
    PermissionService? permissionService,
    ImagePicker? imagePicker,
  }) : _deepARService = deepARService ?? DeepARService(),
       _storyService = storyService ?? StoryService(),
       _stickersService = stickersService ?? StickersService(),
       _characterService = characterService ?? CharacterService(),
       _usageLimitsService = usageLimitsService ?? UsageLimitsService(),
       _subscriptionService = subscriptionService ?? SubscriptionService(),
       _uploadProgressService = uploadProgressService ?? StoryUploadProgressService(),
       _permissionService = permissionService ?? PermissionService(),
       _imagePicker = imagePicker ?? ImagePicker();

  // Getters para el estado
  CameraController? get cameraController => _cameraController;
  List<CameraDescription>? get cameras => _cameras;
  bool get isCameraInitialized => _isCameraInitialized;
  bool get hasCameraPermissions => _hasCameraPermissions;
  bool get hasInitializationFailed => _hasInitializationFailed;
  int get selectedCameraIndex => _selectedCameraIndex;
  String? get selectedFilter => _selectedFilter;
  String? get selectedARFilter => _selectedARFilter;
  String get filterType => _filterType;
  bool get isDeepARInitialized => _isDeepARInitialized;
  int get deepARReinitCounter => _deepARReinitCounter;
  bool get hasCleanedUpDeepAR => _hasCleanedUpDeepAR;
  bool get isRecordingVideo => _isRecordingVideo;
  String? get recordedVideoPath => _recordedVideoPath;
  int get recordingSecondsRemaining => _recordingSecondsRemaining;
  bool get isLoading => _isLoading;
  bool get isLoadingStickers => _isLoadingStickers;
  List<StickerMetadata> get stickerMetadata => _stickerMetadata;

  // Getters para controles de cámara
  FlashMode get flashMode => _flashMode;
  double get currentZoom => _currentZoom;
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;
  double get currentExposure => _currentExposure;
  double get minExposure => _minExposure;
  double get maxExposure => _maxExposure;
  bool get isBackCamera => _cameras != null &&
                           _selectedCameraIndex < _cameras!.length &&
                           _cameras![_selectedCameraIndex].lensDirection == CameraLensDirection.back;

  /// Inicializa el controller
  Future<void> initialize({BuildContext? context}) async {
    ReleaseLogger.log('🎬 Inicializando StoryCameraController...', tag: 'StoryCameraController');
    await _initializeCamera(context: context);
  }

  /// Reintentar inicialización después de conceder permisos
  Future<void> retryInitialization({BuildContext? context}) async {
    ReleaseLogger.log('🔄 Reintentando inicialización de cámara...', tag: 'StoryCameraController');

    // Resetear estados de error
    _hasInitializationFailed = false;
    _hasCameraPermissions = false;

    // Intentar inicializar nuevamente
    await _initializeCamera(context: context);
  }

  /// Inicializar cámara y permisos
  Future<void> _initializeCamera({BuildContext? context}) async {
    try {
      _setLoading(true);

      // En iOS: intentar usar la cámara directamente, el sistema maneja permisos automáticamente
      // En Android: verificar permisos primero
      if (Platform.isIOS) {
        ReleaseLogger.log('📱 iOS: Intentando inicializar cámara directamente...', tag: 'StoryCameraController');
        _hasCameraPermissions = true; // Asumir que funcionará, iOS maneja permisos automáticamente
      } else {
        // Solo en Android verificar permisos primero
        ReleaseLogger.log('🤖 Android: Verificando permisos de cámara...', tag: 'StoryCameraController');

        final currentStatus = await _permissionService.checkStatus(AppPermission.camera);

        PermissionResult permissionResult;
        if (currentStatus == PermissionResult.granted || currentStatus == PermissionResult.limited) {
          permissionResult = currentStatus;
        } else if (context != null && context.mounted) {
          permissionResult = await _permissionService.request(
            AppPermission.camera,
            context: context,
            showRationale: true, // En Android sí mostrar rationale
          );
        } else {
          permissionResult = currentStatus;
        }

        switch (permissionResult) {
          case PermissionResult.granted:
          case PermissionResult.limited:
            _hasCameraPermissions = true;
            ReleaseLogger.log('✅ Permisos de cámara concedidos', tag: 'StoryCameraController');
            onPermissionGranted?.call();
            break;

          case PermissionResult.denied:
          case PermissionResult.permanentlyDenied:
          case PermissionResult.restricted:
            _hasCameraPermissions = false;
            ReleaseLogger.log('❌ Permisos de cámara denegados', tag: 'StoryCameraController');
            onPermissionDenied?.call();
            return;
        }
      }

      // Obtener cámaras disponibles
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('No se encontraron cámaras disponibles');
      }

      // 📷 CONFIGURAR CÁMARA FRONTAL POR DEFECTO para selfies
      _selectedCameraIndex = _findFrontCameraIndex();
      if (_cameras != null && _selectedCameraIndex < _cameras!.length) {
        ReleaseLogger.log('🤳 Camera inicializada en índice $_selectedCameraIndex (${_cameras![_selectedCameraIndex].lensDirection})', tag: 'StoryCameraController');
      } else {
        ReleaseLogger.log('🤳 Camera inicializada en índice $_selectedCameraIndex', tag: 'StoryCameraController');
      }

      // Inicializar controller de cámara
      await _initializeCameraController();

      onCameraInitialized?.call();
    } catch (e) {
      ReleaseLogger.log('❌ Error inicializando cámara: $e', tag: 'StoryCameraController');

      _hasInitializationFailed = true;
      _hasCameraPermissions = false;

      // En iOS, si falla la inicialización es probable que sea por permisos
      if (Platform.isIOS && e.toString().contains('not authorized')) {
        ReleaseLogger.log('📱 iOS: Permisos de cámara denegados por el usuario', tag: 'StoryCameraController');
        onPermissionDenied?.call();
      } else {
        onError?.call('Error inicializando cámara: $e');
      }
    } finally {
      _setLoading(false);
    }
  }

  /// Inicializar controller de cámara específico
  Future<void> _initializeCameraController() async {
    if (_cameras == null || _cameras!.isEmpty) {
      ReleaseLogger.error('❌ No hay cámaras disponibles', tag: 'StoryCameraController');
      return;
    }

    // Dispose controller anterior si existe
    if (_cameraController != null) {
      ReleaseLogger.log('🧹 Disposing controller anterior...', tag: 'StoryCameraController');
      await _cameraController!.dispose();
      _cameraController = null;
    }

    ReleaseLogger.log(
      '🤳 Creando CameraController para índice $_selectedCameraIndex (${_cameras![_selectedCameraIndex].lensDirection})',
      tag: 'StoryCameraController',
    );

    _cameraController = CameraController(
      _cameras![_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: true,
    );

    await _cameraController!.initialize();
    _isCameraInitialized = true;

    ReleaseLogger.log(
      '🤳 Camera inicializada en índice $_selectedCameraIndex (${_cameras![_selectedCameraIndex].lensDirection})',
      tag: 'StoryCameraController',
    );

    // Obtener límites de zoom y exposure
    await _initializeCameraLimits();
  }

  /// Inicializar límites de zoom y exposure después de que la cámara esté lista
  Future<void> _initializeCameraLimits() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    try {
      _minZoom = await _cameraController!.getMinZoomLevel();
      _maxZoom = await _cameraController!.getMaxZoomLevel();
      _currentZoom = _minZoom;

      _minExposure = await _cameraController!.getMinExposureOffset();
      _maxExposure = await _cameraController!.getMaxExposureOffset();
      _currentExposure = 0.0;

      // Reset flash mode (off por defecto, especialmente para cámara frontal)
      _flashMode = FlashMode.off;
      await _cameraController!.setFlashMode(_flashMode);

      ReleaseLogger.log(
        '📸 Camera limits - Zoom: $_minZoom-$_maxZoom, Exposure: $_minExposure-$_maxExposure',
        tag: 'StoryCameraController',
      );
    } catch (e) {
      ReleaseLogger.error('Error getting camera limits: $e', tag: 'StoryCameraController');
    }
  }

  /// Cambiar cámara (frontal/trasera)
  Future<void> switchCamera() async {
    if (_cameras == null || _cameras!.length <= 1) return;

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras!.length;
    ReleaseLogger.log(
      '🔄 Switching to camera index $_selectedCameraIndex',
      tag: 'StoryCameraController',
    );
    await _initializeCameraController();

    // Notificar a la UI para que se actualice
    onCameraInitialized?.call();
  }

  // ═══════════════════════════════════════════════════════════════
  // CONTROLES DE CÁMARA: FLASH, ZOOM, EXPOSURE
  // ═══════════════════════════════════════════════════════════════

  /// Ciclar entre modos de flash: off → auto → always → torch → off
  Future<void> toggleFlashMode() async {
    if (_cameraController == null || !_isCameraInitialized) return;

    try {
      // Determinar siguiente modo de flash
      FlashMode nextMode;
      switch (_flashMode) {
        case FlashMode.off:
          nextMode = FlashMode.auto;
          break;
        case FlashMode.auto:
          nextMode = FlashMode.always;
          break;
        case FlashMode.always:
          nextMode = FlashMode.torch;
          break;
        case FlashMode.torch:
          nextMode = FlashMode.off;
          break;
      }

      await _cameraController!.setFlashMode(nextMode);
      _flashMode = nextMode;
      ReleaseLogger.log('🔦 Flash mode: ${_flashMode.name}', tag: 'StoryCameraController');
    } catch (e) {
      ReleaseLogger.error('Error setting flash mode: $e', tag: 'StoryCameraController');
      onError?.call('Error cambiando modo de flash');
    }
  }

  /// Establecer modo de flash específico
  Future<void> setFlashMode(FlashMode mode) async {
    if (_cameraController == null || !_isCameraInitialized) return;

    try {
      await _cameraController!.setFlashMode(mode);
      _flashMode = mode;
      ReleaseLogger.log('🔦 Flash mode set to: ${_flashMode.name}', tag: 'StoryCameraController');
    } catch (e) {
      ReleaseLogger.error('Error setting flash mode: $e', tag: 'StoryCameraController');
    }
  }

  /// Establecer nivel de zoom
  Future<void> setZoomLevel(double zoom) async {
    if (_cameraController == null || !_isCameraInitialized) return;

    try {
      // Clampear el valor entre min y max
      final clampedZoom = zoom.clamp(_minZoom, _maxZoom);
      await _cameraController!.setZoomLevel(clampedZoom);
      _currentZoom = clampedZoom;
    } catch (e) {
      ReleaseLogger.error('Error setting zoom level: $e', tag: 'StoryCameraController');
    }
  }

  /// Ajustar zoom con gesto de pinch (scale factor relativo)
  Future<void> handlePinchZoom(double scale, double baseZoom) async {
    final newZoom = (baseZoom * scale).clamp(_minZoom, _maxZoom);
    await setZoomLevel(newZoom);
  }

  /// Establecer offset de exposición
  Future<void> setExposureOffset(double offset) async {
    if (_cameraController == null || !_isCameraInitialized) return;

    try {
      // Clampear el valor entre min y max
      final clampedOffset = offset.clamp(_minExposure, _maxExposure);
      await _cameraController!.setExposureOffset(clampedOffset);
      _currentExposure = clampedOffset;
    } catch (e) {
      ReleaseLogger.error('Error setting exposure offset: $e', tag: 'StoryCameraController');
    }
  }

  /// Reset de controles de cámara a valores por defecto
  Future<void> resetCameraControls() async {
    await setFlashMode(FlashMode.off);
    await setZoomLevel(_minZoom);
    await setExposureOffset(0.0);
  }

  /// Aplicar filtro DeepAR
  Future<void> applyARFilter(String filterName) async {
    try {
      // 🔄 VERIFICAR LÍMITES PARA FACE SWAP
      if (filterName == DeepARFilters.faceSwap) {
        final canUseFaceSwap = await _usageLimitsService.canUseFaceSwap();
        if (!canUseFaceSwap) {
          // Verificar si tiene suscripción premium
          final hasSubscription = await hasActiveSubscription();
          if (!hasSubscription) {
            final usage = await _usageLimitsService.getFaceSwapUsage();
            onError?.call('Has usado todos tus ${usage['limit']} face swaps gratuitos este mes. Suscríbete para uso ilimitado.');
            return;
          }
        }
      }

      _selectedARFilter = filterName;

      // ✅ CASO 0: Si se selecciona "Normal" (DeepARFilters.none), volver a cámara Flutter
      if (filterName == DeepARFilters.none || filterName.isEmpty) {
        ReleaseLogger.log(
          '🔄 Volviendo a modo normal desde DeepAR',
          tag: 'StoryCameraController',
        );
        // Delegamos a applyColorFilter que maneja el cleanup y reinicio de Flutter camera
        await applyColorFilter('none');
        return;
      }

      _filterType = 'deepar';

      if (_filterType == 'deepar') {
        // ✅ CASO 1: DeepAR ya está inicializado - solo cambiar el filtro
        if (_isDeepARInitialized) {
          ReleaseLogger.log(
            '🔄 DeepAR ya inicializado, cambiando filtro a: $filterName',
            tag: 'StoryCameraController',
          );

          if (filterName.isNotEmpty) {
            final filterApplied = await _deepARService.switchFilter(filterName);
            if (filterApplied) {
              ReleaseLogger.log('✅ Filtro cambiado exitosamente', tag: 'StoryCameraController');
            } else {
              ReleaseLogger.error('❌ Error cambiando filtro', tag: 'StoryCameraController');
            }
          }
        } else {
          // ✅ CASO 2: Primera vez inicializando DeepAR

          // Liberar la cámara Flutter ANTES de inicializar DeepAR
          if (_cameraController != null) {
            ReleaseLogger.log(
              '📷 Liberando cámara Flutter antes de DeepAR...',
              tag: 'StoryCameraController',
            );
            await _cameraController!.dispose();
            _cameraController = null;
            _isCameraInitialized = false;
            await Future.delayed(const Duration(milliseconds: 100));
          }

          // Seleccionar license key según plataforma
          final licenseKey = Platform.isIOS ? _iosLicenseKey : _androidLicenseKey;

          ReleaseLogger.log(
            '🎭 Inicializando DeepAR con license key de ${Platform.isIOS ? "iOS" : "Android"}',
            tag: 'StoryCameraController',
          );

          // Inicializar DeepAR
          await _deepARService.initialize(licenseKey: licenseKey);
          _deepARReinitCounter++;
          _isDeepARInitialized = true;
          _hasCleanedUpDeepAR = false; // ✅ Resetear flag para permitir cleanup futuro
          ReleaseLogger.log('✅ DeepAR initialized successfully', tag: 'StoryCameraController');

          // Notificar UI para que se actualice con DeepAR view
          onCameraInitialized?.call();

          // Esperar a que el platform view esté completamente configurado
          ReleaseLogger.log('⏳ Esperando a que platform view esté listo...', tag: 'StoryCameraController');
          await Future.delayed(const Duration(milliseconds: 500));

          // Aplicar el filtro seleccionado
          if (filterName.isNotEmpty) {
            ReleaseLogger.log(
              '🎭 Aplicando filtro DeepAR: $filterName',
              tag: 'StoryCameraController',
            );
            final filterApplied = await _deepARService.switchFilter(filterName);
            if (filterApplied) {
              ReleaseLogger.log('✅ Filtro aplicado exitosamente', tag: 'StoryCameraController');
            } else {
              ReleaseLogger.error('❌ Error aplicando filtro', tag: 'StoryCameraController');
            }
          }
        }

        // 🔄 INCREMENTAR CONTADOR PARA FACE SWAP después de aplicar exitosamente
        if (filterName == DeepARFilters.faceSwap) {
          await _usageLimitsService.incrementFaceSwapUsage();
          final usage = await _usageLimitsService.getFaceSwapUsage();
          onSuccess?.call('Face swap aplicado. Te quedan ${usage['remaining']} usos gratuitos este mes.');
        }
      }
    } catch (e) {

      onError?.call('Error aplicando filtro: $e');
    }
  }

  /// Aplicar filtro de color
  Future<void> applyColorFilter(String filterName) async {
    final wasDeepAR = _filterType == 'deepar';

    _selectedFilter = filterName;
    _filterType = 'color';
    _selectedARFilter = DeepARFilters.none; // ✅ Limpiar selección de filtro AR

    // Si estábamos en DeepAR, necesitamos reinicializar la cámara Flutter
    if (wasDeepAR) {
      ReleaseLogger.log(
        '📷 Cambiando de DeepAR a cámara Flutter...',
        tag: 'StoryCameraController',
      );

      // Notificar UI inmediatamente para mostrar loading
      onCameraInitialized?.call();

      // Limpiar DeepAR primero (esto toma ~500ms en nativo)
      ReleaseLogger.log('🧹 Limpiando DeepAR...', tag: 'StoryCameraController');
      await cleanupDeepAR();

      // Esperar suficiente para que DeepAR libere la cámara completamente
      ReleaseLogger.log('⏳ Esperando liberación de recursos...', tag: 'StoryCameraController');
      await Future.delayed(const Duration(milliseconds: 600));

      // Reinicializar cámara Flutter
      ReleaseLogger.log('📷 Reinicializando cámara Flutter...', tag: 'StoryCameraController');

      // Asegurar que tenemos la lista de cámaras disponibles
      if (_cameras == null || _cameras!.isEmpty) {
        ReleaseLogger.log('📷 Obteniendo lista de cámaras...', tag: 'StoryCameraController');
        _cameras = await availableCameras();

        // Buscar cámara frontal por defecto
        for (int i = 0; i < _cameras!.length; i++) {
          if (_cameras![i].lensDirection == CameraLensDirection.front) {
            _selectedCameraIndex = i;
            break;
          }
        }
      }

      await _initializeCameraController();

      // Notificar UI que la cámara está lista
      onCameraInitialized?.call();
      ReleaseLogger.log('✅ Cámara Flutter lista', tag: 'StoryCameraController');
    }
  }

  /// Tomar foto
  Future<String?> takePhoto() async {
    try {
      _setLoading(true);

      // ✅ CASO 1: Modo DeepAR - usar screenshot de DeepAR
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        ReleaseLogger.log('📸 Tomando screenshot con DeepAR...', tag: 'StoryCameraController');

        final imageData = await _deepARService.takeScreenshot();
        if (imageData == null) {
          throw Exception('No se pudo capturar screenshot de DeepAR');
        }

        // Guardar screenshot a archivo temporal
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final filePath = '${tempDir.path}/deepar_photo_$timestamp.jpg';
        final file = File(filePath);
        await file.writeAsBytes(imageData);

        ReleaseLogger.log('✅ Screenshot DeepAR guardado: $filePath', tag: 'StoryCameraController');
        return filePath;
      }

      // ✅ CASO 2: Modo Flutter Camera normal
      if (!_isCameraInitialized || _cameraController == null) {
        throw Exception('Cámara no inicializada');
      }

      final image = await _cameraController!.takePicture();
      return image.path;
    } catch (e) {
      ReleaseLogger.error('❌ Error tomando foto: $e', tag: 'StoryCameraController');
      onError?.call('Error tomando foto: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  /// Iniciar grabación de video
  Future<void> startVideoRecording() async {
    try {
      if (_isRecordingVideo) return;

      // ✅ CASO 1: Modo DeepAR - usar grabación de DeepAR
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        ReleaseLogger.log('🎬 Iniciando grabación con DeepAR...', tag: 'StoryCameraController');

        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _recordedVideoPath = '${tempDir.path}/deepar_video_$timestamp.mp4';

        await _deepARService.startRecording(
          outputPath: _recordedVideoPath!,
          width: 720,
          height: 1280,
        );
      } else {
        // ✅ CASO 2: Modo Flutter Camera normal
        if (!_isCameraInitialized || _cameraController == null) {
          throw Exception('Cámara no inicializada');
        }

        await _cameraController!.startVideoRecording();
      }

      _isRecordingVideo = true;
      _recordingSecondsRemaining = 10;

      // Iniciar timer de 10 segundos
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _recordingSecondsRemaining--;
        onRecordingTimeChanged?.call(_recordingSecondsRemaining);

        if (_recordingSecondsRemaining <= 0) {
          stopVideoRecording();
        }
      });
    } catch (e) {
      ReleaseLogger.error('❌ Error iniciando grabación: $e', tag: 'StoryCameraController');
      onError?.call('Error iniciando grabación: $e');
    }
  }

  /// Parar grabación de video
  Future<String?> stopVideoRecording() async {
    try {
      if (!_isRecordingVideo) return null;

      _recordingTimer?.cancel();
      _recordingTimer = null;
      _isRecordingVideo = false;

      // ✅ CASO 1: Modo DeepAR
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        ReleaseLogger.log('⏹️ Deteniendo grabación DeepAR...', tag: 'StoryCameraController');
        await _deepARService.stopRecording();

        // DeepAR guarda en el path que le pasamos
        if (_recordedVideoPath != null) {
          ReleaseLogger.log('✅ Video DeepAR guardado: $_recordedVideoPath', tag: 'StoryCameraController');
          return _recordedVideoPath;
        }
        return null;
      }

      // ✅ CASO 2: Modo Flutter Camera normal
      if (_cameraController == null) return null;

      final videoFile = await _cameraController!.stopVideoRecording();
      _recordedVideoPath = videoFile.path;

      return videoFile.path;
    } catch (e) {
      ReleaseLogger.error('❌ Error parando grabación: $e', tag: 'StoryCameraController');
      onError?.call('Error parando grabación: $e');
      return null;
    }
  }

  /// Seleccionar imagen de galería
  Future<String?> selectImageFromGallery() async {
    try {
      ReleaseLogger.log('📱 Abriendo selector de galería...', tag: 'StoryCameraController');

      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        ReleaseLogger.log('❌ Usuario canceló selección de imagen', tag: 'StoryCameraController');
        return null;
      }

      final imagePath = pickedFile.path;
      ReleaseLogger.log('✅ Imagen seleccionada: $imagePath', tag: 'StoryCameraController');

      // Verificar que el archivo existe y es válido
      final file = File(imagePath);
      if (!await file.exists()) {
        throw Exception('El archivo seleccionado no existe');
      }

      final fileSize = await file.length();
      ReleaseLogger.log('📂 Tamaño del archivo: $fileSize bytes', tag: 'StoryCameraController');

      if (fileSize == 0) {
        throw Exception('El archivo seleccionado está vacío');
      }

      return imagePath;
    } catch (e) {
      ReleaseLogger.error('❌ Error seleccionando imagen: $e', tag: 'StoryCameraController');
      onError?.call('Error seleccionando imagen: $e');
      return null;
    }
  }

  /// Procesar imagen con filtros
  Future<String?> processImageWithFilters(String imagePath) async {
    try {
      _setLoading(true);

      if (_selectedFilter == null || _selectedFilter == 'none') {
        return imagePath; // Sin filtro
      }

      // Cargar imagen
      final bytes = await File(imagePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) throw Exception('No se pudo procesar la imagen');

      // Aplicar filtro según el tipo
      img.Image processedImage = image;
      switch (_selectedFilter) {
        case 'sepia':
          processedImage = img.sepia(image);
          break;
        case 'black_white':
          processedImage = img.grayscale(image);
          break;
        case 'vintage':
          processedImage = _applyVintageFilter(image);
          break;
        case 'bright':
          processedImage = img.adjustColor(image, brightness: 1.3);
          break;
        case 'dark':
          processedImage = img.adjustColor(image, brightness: 0.7);
          break;
        default:
          break;
      }

      // Guardar imagen procesada
      final tempDir = await getTemporaryDirectory();
      final processedPath = '${tempDir.path}/processed_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final processedFile = File(processedPath);
      await processedFile.writeAsBytes(img.encodeJpg(processedImage, quality: 85));

      return processedPath;
    } catch (e) {
      
      onError?.call('Error procesando imagen: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  /// Aplicar filtro vintage personalizado
  img.Image _applyVintageFilter(img.Image image) {
    // Aplicar tono sepia suave
    var processed = img.sepia(image);
    // Reducir contraste
    processed = img.adjustColor(processed, contrast: 0.8);
    // Añadir un poco de brillo amarillento
    processed = img.adjustColor(processed, saturation: 0.9);
    return processed;
  }

  /// Transformar imagen con personaje
  Future<String?> transformImageWithCharacter(String imagePath, Character character) async {
    try {
      _setLoading(true);

      // Verificar límites de uso
      final canTransform = await _usageLimitsService.canUseCharacterTransform();
      if (!canTransform) {
        final premiumStatus = await _subscriptionService.checkPremiumStatus();
        if (!premiumStatus.isPremium) {
          onError?.call('Límite de transformaciones alcanzado. Necesitas una suscripción premium.');
          return null;
        }
      }

      // Primero subir imagen a Firebase Storage
      final fileName = 'temp_transform_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance.ref().child('temp_transforms').child(fileName);
      final uploadTask = storageRef.putFile(File(imagePath));
      final snapshot = await uploadTask;
      final imageUrl = await snapshot.ref.getDownloadURL();

      // Realizar transformación a través del servicio
      final transformedImageUrl = await _characterService.transformImageWithProgress(
        imageUrl: imageUrl,
        characterId: character.id,
        onProgress: (progress) {
          // Progreso manejado internamente
        },
      );

      // Registrar uso
      await _usageLimitsService.incrementCharacterTransformUsage();
      onSuccess?.call('Transformación completada exitosamente');

      return transformedImageUrl;
    } catch (e) {

      onError?.call('Error en transformación: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  /// Aplicar face swap a un archivo desde el editor
  Future<String?> applyFaceSwapToFile(BuildContext context, File file) async {
    late GlobalKey<_FaceSwapProgressDialogState> progressKey;
    BuildContext? dialogContext;
    bool hasError = false;
    String? transformedFilePath;
    final Completer<String?> completer = Completer<String?>();

    try {
      ReleaseLogger.log('🔄 Iniciando face swap desde editor...', tag: 'StoryCameraController');

      // Verificar que sea imagen
      if (!file.path.toLowerCase().contains('.jpg') &&
          !file.path.toLowerCase().contains('.jpeg') &&
          !file.path.toLowerCase().contains('.png')) {
        onError?.call('Face swap solo funciona con imágenes');
        return null;
      }

      // Verificar límites de face swap
      final canUseFaceSwap = await _usageLimitsService.canUseFaceSwap();
      if (!canUseFaceSwap) {
        final hasSubscription = await hasActiveSubscription();
        if (!hasSubscription) {
          final usage = await _usageLimitsService.getFaceSwapUsage();
          onError?.call('Has usado todos tus ${usage['limit']} face swaps gratuitos este mes. Suscríbete para uso ilimitado.');
          return null;
        }
      }

      // Obtener personajes disponibles
      final characters = await _characterService.getEnabledCharacters();
      if (characters.isEmpty) {
        onError?.call('No hay personajes disponibles para face swap');
        return null;
      }

      // Capturar context antes de operaciones async
      if (!context.mounted) return null;

      // Mostrar selector de personajes
      final selectedCharacter = await showDialog<Character>(
        context: context,
        builder: (context) => const CharacterSelectorDialog(),
      );

      if (selectedCharacter == null) return null;

      // Capturar context INMEDIATAMENTE después de seleccionar personaje
      if (!context.mounted) return null;
      dialogContext = context;

      // Mostrar dialog de progreso INMEDIATAMENTE
      progressKey = GlobalKey<_FaceSwapProgressDialogState>();

      // Marcar modal como activo
      _activeProgressDialogContext = dialogContext;
      _isProgressDialogOpen = true;

      // Show dialog immediately without awaiting (fire and forget)
      showDialog(
        context: dialogContext,
        barrierDismissible: false,
        builder: (context) => _FaceSwapProgressDialog(
          key: progressKey,
          characterName: selectedCharacter.name,
          onCancel: () {
            _forceCloseProgressDialog();
            if (!completer.isCompleted) {
              completer.complete(null);
            }
          },
          onContinue: () {
            // Cerrar modal y completar con el resultado
            _forceCloseProgressDialog();
            if (!completer.isCompleted) {
              completer.complete(transformedFilePath);
            }
          },
        ),
      );

      // Give the dialog a moment to render
      await Future.delayed(const Duration(milliseconds: 50));

      _setLoading(true);

      // Subir imagen a Firebase Storage (con progreso)
      progressKey.currentState?.updateStatus('Subiendo imagen...');
      progressKey.currentState?.updateProgress(0.1);

      final fileName = 'temp_faceswap_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance.ref().child('temp_transforms').child(fileName);
      final uploadTask = storageRef.putFile(file);
      final snapshot = await uploadTask;
      final imageUrl = await snapshot.ref.getDownloadURL();

      progressKey.currentState?.updateStatus('Preparando transformación...');
      progressKey.currentState?.updateProgress(0.3);

      // Aplicar face swap usando el character service con progreso
      final transformedImageUrl = await _characterService.transformImageWithProgress(
        imageUrl: imageUrl,
        characterId: selectedCharacter.id,
        onProgress: (progress) {
          // Verificar que el dialog sigue disponible antes de actualizar
          if (_isProgressDialogOpen) {
            progressKey.currentState?.updateProgress(progress);
          }
        },
        onStatusUpdate: (status) {
          // Verificar que el dialog sigue disponible antes de actualizar
          if (_isProgressDialogOpen) {
            progressKey.currentState?.updateStatus(status);
          }
        },
      );

      // Incrementar contador de face swap
      await _usageLimitsService.incrementFaceSwapUsage();
      final usage = await _usageLimitsService.getFaceSwapUsage();

      // Descargar imagen transformada y reemplazar archivo original
      if (_isProgressDialogOpen) {
        progressKey.currentState?.updateStatus('Guardando resultado...');
        progressKey.currentState?.updateProgress(0.95);
      }

      final transformedFile = await _downloadAndSaveTransformedImage(transformedImageUrl, file.path);
      transformedFilePath = transformedFile?.path;

      ReleaseLogger.log('🔄 Face swap completado. Archivo transformado: $transformedFilePath', tag: 'StoryCameraController');

      // Mostrar pantalla de éxito en la modal en lugar de cerrarla
      if (_isProgressDialogOpen && progressKey.currentState != null) {
        progressKey.currentState!.showSuccess(
          'Face swap aplicado exitosamente!\nTe quedan ${usage['remaining']} usos gratuitos este mes.'
        );
      }

      // NO retornar aquí - esperar hasta que el usuario presione continuar

    } catch (e) {
      hasError = true;
      ReleaseLogger.error('❌ Error en face swap: $e', tag: 'StoryCameraController');
      onError?.call('Error aplicando face swap: $e');

      // Completar inmediatamente con error
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    } finally {
      // Solo cerrar modal en caso de error - en caso de éxito se mantiene para mostrar confirmación
      if (hasError) {
        _forceCloseProgressDialog();
      }
      _setLoading(false);
    }

    // Esperar hasta que el usuario presione continuar o cancele
    return completer.future;
  }

  /// Publicar historia de forma optimista (termina inmediatamente, sube en background)
  Future<bool> publishStory({
    required String mediaPath,
    required String mediaType, // 'image' o 'video'
    String? caption,
    Character? character,
  }) async {
    try {
      ReleaseLogger.log('🚀 Iniciando publicación optimista de historia...', tag: 'StoryCameraController');

      // Usar el servicio optimista - NO ESPERAR a que termine la subida
      final storyId = await _storyService.createStory(
        mediaPath: mediaPath,
        mediaType: mediaType,
        caption: caption,
        onProgressUpdate: (storyId, progress) {
          // Actualizar progreso en el servicio global
          _uploadProgressService.updateProgress(storyId, progress);
          ReleaseLogger.log('📊 Progreso de subida: ${(progress * 100).toInt()}%', tag: 'StoryCameraController');
        },
      );

      ReleaseLogger.log('✅ Historia creada optimisticamente con ID: $storyId', tag: 'StoryCameraController');
      onSuccess?.call('Historia publicándose...');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error publicando historia: $e', tag: 'StoryCameraController');
      onError?.call('Error publicando historia: $e');
      return false;
    }
  }

  /// Cargar stickers disponibles
  Future<void> loadAvailableStickers() async {
    try {
      _isLoadingStickers = true;
      _stickerMetadata = await _stickersService.getAvailableStickers();
    } catch (e) {
      
      onError?.call('Error cargando stickers: $e');
    } finally {
      _isLoadingStickers = false;
    }
  }

  /// Verificar si el usuario tiene suscripción activa
  Future<bool> hasActiveSubscription() async {
    try {
      final premiumStatus = await _subscriptionService.checkPremiumStatus();
      return premiumStatus.isPremium;
    } catch (e) {
      
      return false;
    }
  }

  /// Obtener límites de uso restantes
  Future<Map<String, int>> getRemainingLimits() async {
    try {
      final usage = await _usageLimitsService.getCharacterTransformUsage();
      return {
        'transformationsUsed': usage['count'] as int,
        'transformationsLimit': usage['limit'] as int,
        'transformationsRemaining': usage['remaining'] as int,
      };
    } catch (e) {
      
      return {};
    }
  }

  /// Limpiar DeepAR (llamar cuando se cambie a cámara nativa)
  Future<void> cleanupDeepAR() async {
    if (!_hasCleanedUpDeepAR) {
      await _deepARService.dispose();
      _hasCleanedUpDeepAR = true;
      _isDeepARInitialized = false;
    }
  }

  /// Métodos auxiliares privados
  void _setLoading(bool loading) {
    _isLoading = loading;
    onLoadingChanged?.call(loading);
  }

  /// Obtener filtros DeepAR disponibles
  Map<String, Map<String, dynamic>> getAvailableDeepARFilters() {
    return {
      DeepARFilters.none: {'name': 'Normal', 'icon': 'face', 'emoji': '😊'},
      DeepARFilters.vendetta: {'name': 'Vendetta', 'icon': 'face', 'emoji': '🎭'},
      DeepARFilters.eightBitHearts: {'name': '8-Bit Hearts', 'icon': 'favorite', 'emoji': '💕'},
      DeepARFilters.elephantTrunk: {'name': 'Elephant Trunk', 'icon': 'face', 'emoji': '🐘'},
      DeepARFilters.emotionMeter: {'name': 'Emotion Meter', 'icon': 'mood', 'emoji': '📊'},
      DeepARFilters.emotionsExaggerator: {'name': 'Emotions Exaggerator', 'icon': 'mood', 'emoji': '😱'},
      DeepARFilters.fireEffect: {'name': 'Fire Effect', 'icon': 'whatshot', 'emoji': '🔥'},
      DeepARFilters.hope: {'name': 'Hope', 'icon': 'star', 'emoji': '⭐'},
      DeepARFilters.humanoid: {'name': 'Humanoid', 'icon': 'android', 'emoji': '🤖'},
      DeepARFilters.makeupLook: {'name': 'Makeup Look', 'icon': 'face', 'emoji': '💄'},
      DeepARFilters.neonDevilHorns: {'name': 'Neon Devil Horns', 'icon': 'ac_unit', 'emoji': '😈'},
      DeepARFilters.pingPong: {'name': 'Ping Pong', 'icon': 'sports_tennis', 'emoji': '🏓'},
      DeepARFilters.splitViewLook: {'name': 'Split View Look', 'icon': 'flip', 'emoji': '🔀'},
      DeepARFilters.stallone: {'name': 'Stallone', 'icon': 'face', 'emoji': '🥊'},
      DeepARFilters.vendettaMask: {'name': 'Vendetta Mask', 'icon': 'face', 'emoji': '🎭'},
      DeepARFilters.burningEffect: {'name': 'Burning Effect', 'icon': 'whatshot', 'emoji': '🔥'},
      DeepARFilters.flowerFace: {'name': 'Flower Face', 'icon': 'local_florist', 'emoji': '🌸'},
      DeepARFilters.galaxyBackground: {'name': 'Galaxy Background', 'icon': 'stars', 'emoji': '🌌'},
      DeepARFilters.vikingHelmet: {'name': 'Viking Helmet', 'icon': 'shield', 'emoji': '⚔️'},
      DeepARFilters.barbieAd: {'name': 'Barbie', 'icon': 'face', 'emoji': '💖'},
      DeepARFilters.faceSwap: {'name': 'Face Swap', 'icon': 'swap_horiz', 'emoji': '🔄'},
      DeepARFilters.harryPotter: {'name': 'Harry Potter', 'icon': 'auto_fix_high', 'emoji': '⚡'},
    };
  }

  /// 📷 Encontrar índice de cámara frontal para selfies
  int _findFrontCameraIndex() {
    if (_cameras == null || _cameras!.isEmpty) return 0;

    // Buscar cámara frontal (front-facing)
    for (int i = 0; i < _cameras!.length; i++) {
      if (_cameras![i].lensDirection == CameraLensDirection.front) {
        return i;
      }
    }

    // Si no se encuentra cámara frontal, usar la primera disponible
    return 0;
  }


  /// Forzar cierre de modal de progreso activo
  void _forceCloseProgressDialog() {
    if (!_isProgressDialogOpen || _activeProgressDialogContext == null) {
      return;
    }

    ReleaseLogger.log('🔧 Forzando cierre de modal de progreso...', tag: 'StoryCameraController');

    try {
      if (_activeProgressDialogContext!.mounted) {
        Navigator.of(_activeProgressDialogContext!, rootNavigator: true).pop();
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error forzando cierre de modal: $e', tag: 'StoryCameraController');

      // Último recurso: intentar cerrar cualquier dialog usando el focus manager
      try {
        final focusContext = WidgetsBinding.instance.focusManager.primaryFocus?.context;
        if (focusContext != null && focusContext.mounted) {
          Navigator.of(focusContext, rootNavigator: true).pop();
        }
      } catch (e2) {
        ReleaseLogger.error('❌ Error en último recurso para cerrar modal: $e2', tag: 'StoryCameraController');
      }
    } finally {
      _isProgressDialogOpen = false;
      _activeProgressDialogContext = null;
    }
  }

  /// Descargar imagen transformada y guardarla reemplazando el archivo original
  Future<File?> _downloadAndSaveTransformedImage(String imageUrl, String originalPath) async {
    try {
      ReleaseLogger.log('📥 Descargando imagen transformada: $imageUrl', tag: 'StoryCameraController');

      // Descargar imagen transformada
      final response = await HttpClient().getUrl(Uri.parse(imageUrl));
      final downloadResponse = await response.close();

      // Obtener bytes de la imagen
      final bytes = await downloadResponse.fold<List<int>>([], (previous, element) => previous..addAll(element));

      // Crear un nuevo archivo con timestamp para evitar problemas de caché
      final directory = File(originalPath).parent;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newPath = '${directory.path}/faceswap_$timestamp.jpg';

      final file = File(newPath);
      await file.writeAsBytes(bytes);

      ReleaseLogger.log('✅ Imagen transformada guardada: $newPath', tag: 'StoryCameraController');
      return file;

    } catch (e) {
      ReleaseLogger.error('❌ Error descargando imagen transformada: $e', tag: 'StoryCameraController');
      return null;
    }
  }

  /// Limpiar recursos
  void dispose() {
    // Cerrar cualquier modal de progreso activo
    _forceCloseProgressDialog();

    _recordingTimer?.cancel();
    _cameraController?.dispose();
    _deepARService.dispose();

    // ❌ NO HACER: _uploadProgressService.dispose();
    // ✅ CORRECTO: StoryUploadProgressService es un singleton global,
    // no debe ser disposed por un controller individual.
    // Los uploads pueden continuar en background incluso después
    // de que este controller se destruya.
  }
}

/// Dialog para mostrar progreso de face swap
class _FaceSwapProgressDialog extends StatefulWidget {
  final String characterName;
  final VoidCallback onCancel;
  final VoidCallback? onContinue;

  const _FaceSwapProgressDialog({
    super.key,
    required this.characterName,
    required this.onCancel,
    this.onContinue,
  });

  @override
  State<_FaceSwapProgressDialog> createState() => _FaceSwapProgressDialogState();
}

class _FaceSwapProgressDialogState extends State<_FaceSwapProgressDialog>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  double _progress = 0.0;
  String _status = 'Iniciando transformación...';
  bool _isCompleted = false;
  String _successMessage = '';

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void updateProgress(double progress) {
    if (mounted) {
      setState(() {
        _progress = progress;
      });
    }
  }

  void updateStatus(String status) {
    if (mounted) {
      setState(() {
        _status = status;
      });
    }
  }

  void showSuccess(String message) {
    if (mounted) {
      setState(() {
        _isCompleted = true;
        _successMessage = message;
        _progress = 1.0;
      });
      _animationController.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  _isCompleted ? Icons.check_circle : Icons.swap_horiz,
                  color: _isCompleted ? Colors.green : Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _isCompleted
                        ? 'Transformación completada!'
                        : 'Transformando con ${widget.characterName}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            if (_isCompleted) ...[
              // Success content
              const Icon(
                Icons.check_circle_outline,
                color: Colors.green,
                size: 64,
              ),
              const SizedBox(height: 16),

              Text(
                _successMessage,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Continue button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: widget.onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Continuar',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ] else ...[
              // Progress content
              RotationTransition(
                turns: _animationController,
                child: const Icon(
                  Icons.sync,
                  color: Colors.blue,
                  size: 48,
                ),
              ),
              const SizedBox(height: 16),

              Text(
                _status,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.grey[800],
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
              const SizedBox(height: 8),

              Text(
                '${(_progress * 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

