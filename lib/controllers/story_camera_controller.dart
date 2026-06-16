import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:camera/camera.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/permission_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/story_service_refactored.dart';
import '../services/stories/services/story_music_service.dart';
import '../services/stickers_service.dart';
import '../services/character_service.dart';
import '../services/usage_limits_service.dart';
import '../services/subscription_service.dart';
import '../services/story_upload_progress_service.dart';
import '../services/face_detection_service.dart';
import '../services/ad_service.dart';
import '../services/credit_wallet_service.dart';
import '../models/character.dart';
import '../screens/character_selector_screen.dart';
import '../utils/release_logger.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Controller para manejar la lógica de la cámara de historias
///
/// Responsabilidades:
/// - Gestión de cámara y permisos
/// - Procesamiento de filtros de color y transformaciones (face swap con IA)
/// - Subida de historias a Firebase
/// - Gestión de límites de uso y suscripciones
/// - Coordinación entre servicios
class StoryCameraController {
  final String userId;

  // Hive keys para preferencias locales
  static const String _featureFlagsBoxName = 'feature_flags';
  static const String _hasUsedFaceSwapKey = 'hasUsedFaceSwap';

  // Servicios privados
  final StoryService _storyService;
  final StickersService _stickersService;
  final CharacterService _characterService;
  final UsageLimitsService _usageLimitsService;
  final SubscriptionService _subscriptionService;
  final StoryUploadProgressService _uploadProgressService;
  final PermissionService _permissionService;
  final ImagePicker _imagePicker;
  final StoryMusicService _musicService = StoryMusicService();
  final AdService _adService = AdService();
  final CreditWalletService _walletService = CreditWalletService();

  /// Cuántos créditos cuesta generar una canción (debe coincidir con
  /// FEATURE_PRICES.song_generation en functions/wallet.js).
  static const int songCreditCost = 6;

  // Estado de la cámara
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _hasCameraPermissions = false;
  bool _hasInitializationFailed = false;
  int _selectedCameraIndex = 0; // Will be set to front camera in initialization
  bool _isInitializingCamera = false; // 🔒 Mutex para prevenir race conditions

  // Estado de filtros
  String? _selectedFilter;

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
  /// Se dispara cuando una transformación falla por falta de créditos. El screen
  /// muestra el flujo: si el hijo tiene padre vinculado → ofrecer avisarle; si
  /// no → invitar a vincular un padre.
  Function()? onOutOfCredits;

  // Flag interno: la última transformación falló por créditos insuficientes.
  bool _pendingOutOfCredits = false;
  Function()? onPermissionGranted; // Nuevo callback para cuando se conceden permisos
  Function()? onCameraInitialized;
  Function(bool)? onLoadingChanged;
  Function(int)? onRecordingTimeChanged;
  Function()? onFaceSwapFirstUse; // Callback cuando se usa face-swap por primera vez

  // Constructor
  StoryCameraController({
    required this.userId,
    StoryService? storyService,
    StickersService? stickersService,
    CharacterService? characterService,
    UsageLimitsService? usageLimitsService,
    SubscriptionService? subscriptionService,
    StoryUploadProgressService? uploadProgressService,
    PermissionService? permissionService,
    ImagePicker? imagePicker,
  }) : _storyService = storyService ?? StoryService(),
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

  // ═══════════════════════════════════════════════════════════════
  // FACE SWAP - FIRST USE TRACKING
  // ═══════════════════════════════════════════════════════════════

  /// Verifica si el usuario ha usado face-swap alguna vez
  Future<bool> hasUsedFaceSwap() async {
    try {
      final box = await Hive.openBox(_featureFlagsBoxName);
      return box.get(_hasUsedFaceSwapKey, defaultValue: false) as bool;
    } catch (e) {
      ReleaseLogger.error('Error checking hasUsedFaceSwap: $e', tag: 'StoryCameraController');
      return false;
    }
  }

  /// Marca que el usuario ha usado face-swap por primera vez
  Future<void> _markFaceSwapAsUsed() async {
    try {
      final box = await Hive.openBox(_featureFlagsBoxName);
      final wasUsedBefore = box.get(_hasUsedFaceSwapKey, defaultValue: false) as bool;

      if (!wasUsedBefore) {
        await box.put(_hasUsedFaceSwapKey, true);
        onFaceSwapFirstUse?.call();
        ReleaseLogger.log('✨ Face-swap marcado como usado por primera vez', tag: 'StoryCameraController');
      }
    } catch (e) {
      ReleaseLogger.error('Error marking face-swap as used: $e', tag: 'StoryCameraController');
    }
  }

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
        final wasAlreadyGranted = currentStatus == PermissionResult.granted || currentStatus == PermissionResult.limited;

        PermissionResult permissionResult;
        if (wasAlreadyGranted) {
          permissionResult = currentStatus;
        } else if (context != null && context.mounted) {
          // Solicitar permiso de cámara
          permissionResult = await _permissionService.request(
            AppPermission.camera,
            context: context,
            showRationale: true, // En Android sí mostrar rationale
          );

          // También solicitar permiso de micrófono para video
          if (permissionResult == PermissionResult.granted && context.mounted) {
            await _permissionService.request(
              AppPermission.microphone,
              context: context,
              showRationale: true,
            );
          }
        } else {
          permissionResult = currentStatus;
        }

        switch (permissionResult) {
          case PermissionResult.granted:
          case PermissionResult.limited:
            _hasCameraPermissions = true;
            ReleaseLogger.log('✅ Permisos de cámara concedidos', tag: 'StoryCameraController');

            // ✅ FIX ANDROID: Esperar a que el sistema propague los permisos antes de inicializar cámara
            // Esto evita el problema de pantalla negra la primera vez que se conceden permisos
            if (!wasAlreadyGranted) {
              ReleaseLogger.log('⏳ Android: Esperando propagación de permisos...', tag: 'StoryCameraController');
              await Future.delayed(const Duration(milliseconds: 500));
            }

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
    // 🔒 Prevenir inicializaciones concurrentes (race condition fix)
    if (_isInitializingCamera) {
      ReleaseLogger.log('⚠️ Inicialización de cámara ya en progreso, ignorando...', tag: 'StoryCameraController');
      return;
    }

    if (_cameras == null || _cameras!.isEmpty) {
      ReleaseLogger.error('❌ No hay cámaras disponibles', tag: 'StoryCameraController');
      return;
    }

    _isInitializingCamera = true;

    try {
      // Dispose controller anterior si existe
      final oldController = _cameraController;
      _cameraController = null;
      _isCameraInitialized = false;

      if (oldController != null) {
        ReleaseLogger.log('🧹 Disposing controller anterior...', tag: 'StoryCameraController');
        await oldController.dispose();
      }

      ReleaseLogger.log(
        '🤳 Creando CameraController para índice $_selectedCameraIndex (${_cameras![_selectedCameraIndex].lensDirection})',
        tag: 'StoryCameraController',
      );

      final newController = CameraController(
        _cameras![_selectedCameraIndex],
        ResolutionPreset.high,
        enableAudio: true,
      );

      await newController.initialize();

      // ✅ Verificar que no se disparó otra inicialización mientras esperábamos
      if (!_isInitializingCamera) {
        ReleaseLogger.log('⚠️ Inicialización cancelada por otra operación', tag: 'StoryCameraController');
        await newController.dispose();
        return;
      }

      _cameraController = newController;
      _isCameraInitialized = true;

      // Bloquear orientación a portrait para que el preview no rote cuando
      // el usuario gira físicamente el celular (la app está locked a portrait
      // en Info.plist/AndroidManifest, pero el plugin sigue escuchando
      // UIDevice.orientationDidChangeNotification y rotaría el preview).
      try {
        await newController.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (e) {
        ReleaseLogger.warning('No se pudo bloquear orientación: $e', tag: 'StoryCameraController');
      }

      ReleaseLogger.log(
        '🤳 Camera inicializada en índice $_selectedCameraIndex (${_cameras![_selectedCameraIndex].lensDirection})',
        tag: 'StoryCameraController',
      );

      // Obtener límites de zoom y exposure
      await _initializeCameraLimits();
    } catch (e) {
      ReleaseLogger.error('❌ Error en _initializeCameraController: $e', tag: 'StoryCameraController');
      rethrow;
    } finally {
      _isInitializingCamera = false;
    }
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

      // ✅ FIX iOS: Forzar flash off con reintentos
      // El plugin camera tiene FlashMode.auto como default, y en iOS el
      // setFlashMode puede no tener efecto si se llama muy temprano.
      // Esto causaba que la UI mostrara "off" pero el flash real estuviera en "auto".
      _flashMode = FlashMode.off;
      await _forceFlashModeOff();

      ReleaseLogger.log(
        '📸 Camera limits - Zoom: $_minZoom-$_maxZoom, Exposure: $_minExposure-$_maxExposure',
        tag: 'StoryCameraController',
      );
    } catch (e) {
      ReleaseLogger.error('Error getting camera limits: $e', tag: 'StoryCameraController');
    }
  }

  /// Forzar flash mode a off con reintentos para iOS
  Future<void> _forceFlashModeOff() async {
    if (_cameraController == null) return;

    // Intento 1: inmediato
    try {
      await _cameraController!.setFlashMode(FlashMode.off);
      ReleaseLogger.log('🔦 Flash inicializado en OFF (intento 1)', tag: 'StoryCameraController');
    } catch (e) {
      ReleaseLogger.log('⚠️ setFlashMode falló en intento 1: $e', tag: 'StoryCameraController');
    }

    // Intento 2: con pequeño delay (para iOS)
    await Future.delayed(const Duration(milliseconds: 100));
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
        ReleaseLogger.log('🔦 Flash confirmado en OFF (intento 2)', tag: 'StoryCameraController');
      } catch (e) {
        ReleaseLogger.log('⚠️ setFlashMode falló en intento 2: $e', tag: 'StoryCameraController');
      }
    }
  }

  /// Cambiar cámara (frontal/trasera)
  /// Solo alterna entre cámara frontal y trasera, ignorando otras cámaras (telephoto, ultra-wide, etc.)
  Future<void> switchCamera() async {
    if (_cameras == null || _cameras!.length <= 1) return;

    // Determinar la dirección actual
    final currentDirection = _cameras![_selectedCameraIndex].lensDirection;

    // Buscar la dirección opuesta
    final targetDirection = currentDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    // Buscar la primera cámara con la dirección opuesta
    for (int i = 0; i < _cameras!.length; i++) {
      if (_cameras![i].lensDirection == targetDirection) {
        _selectedCameraIndex = i;
        ReleaseLogger.log(
          '🔄 Switching camera: $currentDirection → $targetDirection (index $_selectedCameraIndex)',
          tag: 'StoryCameraController',
        );
        break;
      }
    }

    await _initializeCameraController();

    // Notificar a la UI para que se actualice
    onCameraInitialized?.call();
  }

  // ═══════════════════════════════════════════════════════════════
  // CONTROLES DE CÁMARA: FLASH, ZOOM, EXPOSURE
  // ═══════════════════════════════════════════════════════════════

  /// Ciclar entre modos de flash: off → auto → always → torch → off
  /// Para cámara frontal, solo cambia entre off y always (screen flash)
  Future<void> toggleFlashMode() async {
    FlashMode nextMode;

    // Para cámara frontal: solo off ↔ always (screen flash)
    // El screen flash funciona mostrando pantalla blanca, no requiere cameraController
    if (!isBackCamera) {
      nextMode = _flashMode == FlashMode.off ? FlashMode.always : FlashMode.off;
      _flashMode = nextMode;
      ReleaseLogger.log('🔦 Screen flash: ${nextMode == FlashMode.always ? "ON" : "OFF"}', tag: 'StoryCameraController');

      // Intentar configurar en el plugin si está disponible
      if (_cameraController != null && _isCameraInitialized) {
        try {
          await _cameraController!.setFlashMode(nextMode);
        } catch (e) {
          // Ignorar - el screen flash se maneja por software
        }
      }
      return;
    }

    // Para cámara trasera: requiere cameraController
    if (_cameraController == null || !_isCameraInitialized) return;

    // Para cámara trasera: ciclar todos los modos
    try {
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

  /// Indica si se debe usar screen flash (cámara frontal con flash activado)
  bool get shouldUseScreenFlash => !isBackCamera && _flashMode != FlashMode.off;

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

  /// Aplicar filtro de color (sepia, vintage, etc.)
  Future<void> applyColorFilter(String filterName) async {
    _selectedFilter = filterName;
  }

  /// Tomar foto
  Future<String?> takePhoto() async {
    try {
      _setLoading(true);

      if (!_isCameraInitialized || _cameraController == null) {
        throw Exception('Cámara no inicializada');
      }

      // ✅ FIX: Sincronizar flash mode con el plugin ANTES de tomar la foto
      // Esto asegura que el estado interno del plugin coincida con nuestro estado
      try {
        await _cameraController!.setFlashMode(_flashMode);
        ReleaseLogger.log('🔦 Flash sincronizado antes de foto: ${_flashMode.name}', tag: 'StoryCameraController');
      } catch (e) {
        ReleaseLogger.log('⚠️ No se pudo sincronizar flash: $e', tag: 'StoryCameraController');
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

      if (!_isCameraInitialized || _cameraController == null) {
        throw Exception('Cámara no inicializada');
      }

      await _cameraController!.startVideoRecording();

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

      // Verificar que hay una cara visible en la imagen ANTES de mostrar el selector
      final faceDetectionService = FaceDetectionService();
      final hasFace = await faceDetectionService.hasFace(file.path);
      if (!hasFace) {
        onError?.call('No se detectó una cara en la imagen. Para mejores resultados, asegúrate de que tu rostro sea claramente visible.');
        return null;
      }

      // Capturar context antes de operaciones async
      if (!context.mounted) return null;

      // Mostrar selector de personajes (pantalla fullscreen)
      final selectedCharacter = await Navigator.of(context).push<Character>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const CharacterSelectorScreen(),
        ),
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

      // Mantener pantalla encendida durante la transformación
      await WakelockPlus.enable();

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

      // Nota: El contador de uso se incrementa en el servidor (transformations.js)
      await _markFaceSwapAsUsed();
      final usage = await _usageLimitsService.getFaceSwapUsageByTier();

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
        final isUnlimited = usage['unlimited'] == true;
        final successMessage = isUnlimited
            ? 'Face swap aplicado exitosamente!'
            : 'Face swap aplicado exitosamente!\nTe quedan ${usage['remaining']} usos gratuitos este mes.';
        progressKey.currentState!.showSuccess(successMessage);
      }

      // NO retornar aquí - esperar hasta que el usuario presione continuar

    } catch (e) {
      hasError = true;
      ReleaseLogger.error('❌ Error en face swap: $e', tag: 'StoryCameraController');

      // ✅ Detectar "sin créditos" (el spend en la CF lanza failed-precondition
      // con INSUFFICIENT_CREDITS). En ese caso NO mostramos error genérico:
      // disparamos el flujo de pedir créditos al padre / invitar a vincular.
      final outOfCredits = e is FirebaseFunctionsException &&
          (e.message?.contains('INSUFFICIENT_CREDITS') ?? false);
      if (outOfCredits) {
        _pendingOutOfCredits = true;
      } else {
        onError?.call('Error aplicando face swap: $e');
      }

      // Completar inmediatamente con error
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    } finally {
      // Desactivar wakelock
      await WakelockPlus.disable();
      // Solo cerrar modal en caso de error - en caso de éxito se mantiene para mostrar confirmación
      if (hasError) {
        _forceCloseProgressDialog();
      }
      _setLoading(false);

      // Después de cerrar el progress dialog, disparar el flujo de sin-créditos.
      if (_pendingOutOfCredits) {
        _pendingOutOfCredits = false;
        onOutOfCredits?.call();
      }
    }

    // Esperar hasta que el usuario presione continuar o cancele
    return completer.future;
  }

  /// ¿El hijo (usuario actual) tiene al menos un padre vinculado?
  /// Usa el campo denormalizado linkedParentIds del doc del usuario.
  Future<bool> hasLinkedParent() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return false;
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final ids = doc.data()?['linkedParentIds'];
      return ids is List && ids.isNotEmpty;
    } catch (e) {
      ReleaseLogger.error('Error verificando padres vinculados: $e',
          tag: 'StoryCameraController');
      return false;
    }
  }

  /// Pide a los padres vinculados que carguen créditos (la CF manda un push a
  /// cada uno). Devuelve (success, message).
  Future<({bool success, String message})> requestCreditsFromParents() async {
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('requestCreditsFromParents');
      final res = await callable.call();
      final count = (res.data?['parentsNotified'] as int?) ?? 0;
      return (
        success: true,
        message: count > 1
            ? 'Les avisamos a tu familia ✨'
            : 'Le avisamos a tu familia ✨',
      );
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'resource-exhausted') {
        return (
          success: false,
          message: e.message ?? 'Ya avisaste recién, esperá un rato.'
        );
      }
      return (success: false, message: 'No se pudo avisar. Intentá de nuevo.');
    } catch (e) {
      return (success: false, message: 'No se pudo avisar. Intentá de nuevo.');
    }
  }

  /// Aplicar face swap con un personaje pre-seleccionado (desde la cámara)
  /// Esta variante NO muestra el selector de personajes porque ya viene seleccionado
  Future<String?> applyFaceSwapWithCharacter(
    BuildContext context,
    File file,
    Character selectedCharacter,
  ) async {
    late GlobalKey<_FaceSwapProgressDialogState> progressKey;
    BuildContext? dialogContext;
    bool hasError = false;
    String? transformedFilePath;
    final Completer<String?> completer = Completer<String?>();

    try {
      ReleaseLogger.log('🎭 Iniciando Face Swap con personaje: ${selectedCharacter.name}', tag: 'StoryCameraController');

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

      // Verificar que hay una cara visible en la imagen
      final faceDetectionService = FaceDetectionService();
      final hasFace = await faceDetectionService.hasFace(file.path);
      if (!hasFace) {
        onError?.call('No se detectó una cara en la imagen. Para mejores resultados, asegúrate de que tu rostro sea claramente visible.');
        return null;
      }

      // Capturar context antes de operaciones async
      if (!context.mounted) return null;
      dialogContext = context;

      // Mostrar dialog de progreso INMEDIATAMENTE
      progressKey = GlobalKey<_FaceSwapProgressDialogState>();

      // Marcar modal como activo
      _activeProgressDialogContext = dialogContext;
      _isProgressDialogOpen = true;

      // Show dialog immediately without awaiting
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
            _forceCloseProgressDialog();
            if (!completer.isCompleted) {
              completer.complete(transformedFilePath);
            }
          },
        ),
      );

      // Give the dialog a moment to render
      await Future.delayed(const Duration(milliseconds: 50));

      // Mantener pantalla encendida durante la transformación
      await WakelockPlus.enable();

      _setLoading(true);

      // Subir imagen a Firebase Storage
      progressKey.currentState?.updateStatus('Subiendo imagen...');
      progressKey.currentState?.updateProgress(0.1);

      final fileName = 'temp_faceswap_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = FirebaseStorage.instance.ref().child('temp_transforms').child(fileName);
      final uploadTask = storageRef.putFile(file);
      final snapshot = await uploadTask;
      final imageUrl = await snapshot.ref.getDownloadURL();

      progressKey.currentState?.updateStatus('Transformando en ${selectedCharacter.name}...');
      progressKey.currentState?.updateProgress(0.3);

      // Aplicar face swap
      final transformedImageUrl = await _characterService.transformImageWithProgress(
        imageUrl: imageUrl,
        characterId: selectedCharacter.id,
        onProgress: (progress) {
          if (_isProgressDialogOpen) {
            progressKey.currentState?.updateProgress(progress);
          }
        },
        onStatusUpdate: (status) {
          if (_isProgressDialogOpen) {
            progressKey.currentState?.updateStatus(status);
          }
        },
      );

      // Nota: El contador de uso se incrementa en el servidor (transformations.js)
      await _markFaceSwapAsUsed();
      final usage = await _usageLimitsService.getFaceSwapUsageByTier();

      // Guardar resultado
      if (_isProgressDialogOpen) {
        progressKey.currentState?.updateStatus('Guardando resultado...');
        progressKey.currentState?.updateProgress(0.95);
      }

      final transformedFile = await _downloadAndSaveTransformedImage(transformedImageUrl, file.path);
      transformedFilePath = transformedFile?.path;

      ReleaseLogger.log('🎭 Face swap completado: $transformedFilePath', tag: 'StoryCameraController');

      // Mostrar éxito
      if (_isProgressDialogOpen && progressKey.currentState != null) {
        final isUnlimited = usage['unlimited'] == true;
        final successMessage = isUnlimited
            ? '¡Transformación completada!'
            : '¡Transformación completada!\nTe quedan ${usage['remaining']} usos gratuitos este mes.';
        progressKey.currentState!.showSuccess(successMessage);
        // El usuario debe clickear "Continuar" para completar el completer via onContinue callback
      } else {
        // ✅ FIX: El diálogo ya no está disponible, completar el completer directamente
        ReleaseLogger.log('⚠️ Diálogo de progreso no disponible, completando directamente', tag: 'StoryCameraController');
        _forceCloseProgressDialog();
        if (!completer.isCompleted) {
          completer.complete(transformedFilePath);
        }
      }

    } on FirebaseFunctionsException catch (e) {
      // Manejar errores específicos de Cloud Functions con mensajes amigables
      hasError = true;
      ReleaseLogger.error('❌ Error Cloud Function Face Swap: ${e.code} - ${e.message}', tag: 'StoryCameraController');

      String userMessage;
      if (e.code == 'resource-exhausted') {
        // Extraer mensaje amigable del servidor (límite de transformaciones)
        userMessage = e.message ?? 'Has alcanzado el límite de transformaciones. Actualiza a Premium para más.';
      } else if (e.code == 'unauthenticated') {
        userMessage = 'Sesión expirada. Por favor vuelve a iniciar sesión.';
      } else if (e.code == 'permission-denied') {
        userMessage = 'No tienes permiso para usar Face Swap.';
      } else {
        userMessage = e.message ?? 'Error aplicando Face Swap. Intenta de nuevo.';
      }

      onError?.call(userMessage);

      if (!completer.isCompleted) {
        completer.complete(null);
      }
    } catch (e) {
      hasError = true;
      ReleaseLogger.error('❌ Error en Face Swap: $e', tag: 'StoryCameraController');
      onError?.call('Error aplicando Face Swap. Intenta de nuevo.');

      if (!completer.isCompleted) {
        completer.complete(null);
      }
    } finally {
      // Desactivar wakelock
      await WakelockPlus.disable();
      if (hasError) {
        _forceCloseProgressDialog();
      }
      _setLoading(false);
    }

    return completer.future;
  }

  /// Publicar historia de forma optimista (termina inmediatamente, sube en background)
  Future<bool> publishStory({
    required String mediaPath,
    required String mediaType, // 'image' o 'video'
    String? caption,
    Character? character,
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
  }) async {
    try {
      ReleaseLogger.log('🚀 Iniciando publicación optimista de historia...', tag: 'StoryCameraController');

      // Usar el servicio optimista - NO ESPERAR a que termine la subida
      // aiGenerated: true si se aplicó face-swap (flag explícito o character != null).
      final storyId = await _storyService.createStory(
        mediaPath: mediaPath,
        mediaType: mediaType,
        caption: caption,
        aiGenerated: aiGenerated || character != null,
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
        onProgressUpdate: (storyId, progress) {
          // Actualizar progreso en el servicio global
          _uploadProgressService.updateProgress(storyId, progress);
          ReleaseLogger.log('📊 Progreso de subida: ${(progress * 100).toInt()}%', tag: 'StoryCameraController');
        },
      );

      ReleaseLogger.log('✅ Historia creada optimisticamente con ID: $storyId', tag: 'StoryCameraController');
      onSuccess?.call('Historia publicándose...');
      return true;
    } on FirebaseFunctionsException catch (e) {
      // Manejar errores específicos de Cloud Functions con mensajes amigables
      ReleaseLogger.error('❌ Error Cloud Function publicando historia: ${e.code} - ${e.message}', tag: 'StoryCameraController');

      String userMessage;
      if (e.code == 'resource-exhausted') {
        // Extraer mensaje amigable del servidor
        userMessage = e.message ?? 'Has alcanzado el límite de historias. Espera un momento.';
      } else if (e.code == 'unauthenticated') {
        userMessage = 'Sesión expirada. Por favor vuelve a iniciar sesión.';
      } else if (e.code == 'permission-denied') {
        userMessage = 'No tienes permiso para publicar historias.';
      } else {
        userMessage = e.message ?? 'Error al publicar historia. Intenta de nuevo.';
      }

      onError?.call(userMessage);
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error publicando historia: $e', tag: 'StoryCameraController');
      onError?.call('Error al publicar historia. Intenta de nuevo.');
      return false;
    }
  }

  /// 🎵 Genera una canción con IA a partir de un prompt.
  /// Devuelve el resultado (con la URL del audio) o null si falló
  /// (el error se reporta vía onError con un mensaje legible).
  Future<StoryMusicResult?> generateMusic({
    required String prompt,
    String? lyrics,
    bool instrumental = false,
  }) async {
    try {
      return await _musicService.generate(
        prompt: prompt,
        lyrics: lyrics,
        instrumental: instrumental,
      );
    } on StoryMusicException catch (e) {
      onError?.call(e.message);
      return null;
    } catch (e) {
      ReleaseLogger.error('Error generando música: $e', tag: 'StoryCameraController');
      onError?.call('No se pudo generar la canción. Intentá de nuevo.');
      return null;
    }
  }

  /// 🎵 Stream del balance de créditos disponible (wallet propio o del padre).
  Stream<int?> watchAvailableCredits() => _walletService.watchMaxAvailableCredits();

  /// 🎵 Pide el timing (alignment) de la canción para sincronizar la letra.
  Future<AlignmentResult?> fetchMusicAlignment(String taskId) =>
      _musicService.fetchAlignment(taskId);

  /// 🎵 Muestra un rewarded ad para ganar 1 crédito. El crédito se acredita
  /// automáticamente en el backend (AdService → earnCreditsFromAd) y el stream
  /// de balance se actualiza solo. Devuelve true si el usuario completó el video.
  Future<bool> watchAdForCredit() async {
    try {
      if (!_adService.isRewardedAdLoaded) {
        await _adService.loadRewardedAd();
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!_adService.isRewardedAdLoaded) {
        onError?.call('El video no está disponible. Probá de nuevo en unos segundos.');
        return false;
      }
      return await _adService.showRewardedAd();
    } catch (e) {
      ReleaseLogger.error('Error mostrando rewarded ad: $e', tag: 'StoryCameraController');
      onError?.call('No se pudo mostrar el video. Intentá de nuevo.');
      return false;
    }
  }

  /// 🎵 Ve [count] rewarded ads SEGUIDOS (al terminar uno arranca el siguiente
  /// automáticamente). Cada uno acredita 1 crédito en el backend; el stream de
  /// balance se actualiza solo. Devuelve cuántos videos se completaron.
  Future<int> watchAdsForCredits(int count) async {
    int completed = 0;
    for (var i = 0; i < count; i++) {
      try {
        if (!_adService.isRewardedAdLoaded) {
          await _adService.loadRewardedAd();
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (!_adService.isRewardedAdLoaded) break;
        final ok = await _adService.showRewardedAd();
        if (!ok) break; // el usuario cerró el video antes de completarlo
        completed++;
        // Respiro para que se precargue el siguiente.
        if (i < count - 1) await Future.delayed(const Duration(seconds: 1));
      } catch (e) {
        ReleaseLogger.error('Error en cadena de rewarded ads: $e', tag: 'StoryCameraController');
        break;
      }
    }
    if (completed == 0) {
      onError?.call('No se pudo mostrar el video. Probá de nuevo en unos segundos.');
    }
    return completed;
  }

  /// 🎵 Para hijos sin créditos: pide a la familia que cargue créditos (la CF
  /// manda un push a cada padre, que es quien puede ver videos / comprar).
  /// Muestra el feedback vía los callbacks de la screen.
  Future<void> requestCreditsFromFamily() async {
    final result = await requestCreditsFromParents();
    if (result.success) {
      onSuccess?.call(result.message);
    } else {
      onError?.call(result.message);
    }
  }

  /// 🎵 Publica una historia de solo-música (sin foto/video).
  Future<bool> publishMusicOnlyStory({
    required String musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>>? musicLyricsTimings,
    String? caption,
  }) async {
    try {
      final storyId = await _storyService.createMusicOnlyStory(
        musicUrl: musicUrl,
        musicPrompt: musicPrompt,
        musicLyrics: musicLyrics,
        musicStartMs: musicStartMs,
        musicClipMs: musicClipMs,
        musicTitle: musicTitle,
        musicDisplayMode: musicDisplayMode,
        musicLyricsTimings: musicLyricsTimings,
        caption: caption,
      );
      ReleaseLogger.log('✅ Historia de música creada: $storyId', tag: 'StoryCameraController');
      onSuccess?.call('Historia publicándose...');
      return true;
    } on FirebaseFunctionsException catch (e) {
      final msg = e.code == 'resource-exhausted'
          ? (e.message ?? 'Alcanzaste el límite de historias. Esperá un momento.')
          : (e.message ?? 'Error al publicar historia. Intentá de nuevo.');
      onError?.call(msg);
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error publicando música story: $e', tag: 'StoryCameraController');
      onError?.call('Error al publicar historia. Intenta de nuevo.');
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

  /// Métodos auxiliares privados
  void _setLoading(bool loading) {
    _isLoading = loading;
    onLoadingChanged?.call(loading);
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

    // Solo dispose si la cámara terminó de inicializarse
    // Evita IllegalStateException en Android cuando se cierra
    // la pantalla antes de que la cámara termine de cargar
    if (_isCameraInitialized && _cameraController != null) {
      _cameraController!.dispose();
    }
    _cameraController = null;

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
                // X para cerrar/cancelar (esquina superior derecha).
                GestureDetector(
                  onTap: widget.onCancel,
                  child: const Icon(Icons.close, color: Colors.white54, size: 22),
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

