import 'dart:io';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../services/deepar_service.dart';
import '../services/story_service.dart';
import '../services/stickers_service.dart';
import '../services/character_service.dart';
import '../services/usage_limits_service.dart';
import '../services/subscription_service.dart';
import '../services/story_upload_progress_service.dart';
import '../models/character.dart';

/// Controller para manejar la lógica de la cámara de historias
///
/// Responsabilidades:
/// - Gestión de cámara y permisos
/// - Procesamiento de filtros y transformaciones
/// - Subida de historias a Firebase
/// - Gestión de límites de uso y suscripciones
/// - Coordinación entre servicios
class StoryCameraController {
  final String userId;

  // Servicios privados
  final DeepARService _deepARService;
  final StoryService _storyService;
  final StickersService _stickersService;
  final CharacterService _characterService;
  final UsageLimitsService _usageLimitsService;
  final SubscriptionService _subscriptionService;
  final StoryUploadProgressService _uploadProgressService;
  final ImagePicker _imagePicker;

  // Estado de la cámara
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _hasCameraPermissions = false;
  bool _hasInitializationFailed = false;
  int _selectedCameraIndex = 0;

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

  // Estado de carga y procesamiento
  bool _isLoading = false;
  bool _isLoadingStickers = false;
  List<StickerMetadata> _stickerMetadata = [];

  // Callbacks para comunicación con el screen
  Function(String)? onError;
  Function(String)? onSuccess;
  Function()? onPermissionDenied;
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
    ImagePicker? imagePicker,
  }) : _deepARService = deepARService ?? DeepARService(),
       _storyService = storyService ?? StoryService(),
       _stickersService = stickersService ?? StickersService(),
       _characterService = characterService ?? CharacterService(),
       _usageLimitsService = usageLimitsService ?? UsageLimitsService(),
       _subscriptionService = subscriptionService ?? SubscriptionService(),
       _uploadProgressService = uploadProgressService ?? StoryUploadProgressService(),
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

  /// Inicializa el controller
  Future<void> initialize() async {
    
    await _initializeCamera();
  }

  /// Inicializar cámara y permisos
  Future<void> _initializeCamera() async {
    try {
      _setLoading(true);

      // Verificar permisos de cámara
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          _hasCameraPermissions = false;
          onPermissionDenied?.call();
          return;
        }
      }
      _hasCameraPermissions = true;

      // Obtener cámaras disponibles
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('No se encontraron cámaras disponibles');
      }

      // Inicializar controller de cámara
      await _initializeCameraController();

      onCameraInitialized?.call();
    } catch (e) {
      
      _hasInitializationFailed = true;
      onError?.call('Error inicializando cámara: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Inicializar controller de cámara específico
  Future<void> _initializeCameraController() async {
    if (_cameras == null || _cameras!.isEmpty) return;

    _cameraController?.dispose();

    _cameraController = CameraController(
      _cameras![_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: true,
    );

    await _cameraController!.initialize();
    _isCameraInitialized = true;
  }

  /// Cambiar cámara (frontal/trasera)
  Future<void> switchCamera() async {
    if (_cameras == null || _cameras!.length <= 1) return;

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras!.length;
    await _initializeCameraController();
  }

  /// Aplicar filtro DeepAR
  Future<void> applyARFilter(String filterName) async {
    try {
      _selectedARFilter = filterName;
      _filterType = filterName == DeepARFilters.none ? 'color' : 'deepar';

      if (_filterType == 'deepar') {
        // DeepARService maneja el cambio de efectos internamente
        await _deepARService.initialize(licenseKey: 'DEEPAR_LICENSE_KEY'); // TODO: Move to config
        if (!_isDeepARInitialized) {
          _deepARReinitCounter++;
          _isDeepARInitialized = true;
        }
      }
    } catch (e) {
      
      onError?.call('Error aplicando filtro: $e');
    }
  }

  /// Aplicar filtro de color
  void applyColorFilter(String filterName) {
    _selectedFilter = filterName;
    _filterType = 'color';
  }

  /// Tomar foto
  Future<String?> takePhoto() async {
    try {
      if (!_isCameraInitialized || _cameraController == null) {
        throw Exception('Cámara no inicializada');
      }

      _setLoading(true);

      final image = await _cameraController!.takePicture();
      return image.path;
    } catch (e) {
      
      onError?.call('Error tomando foto: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  /// Iniciar grabación de video
  Future<void> startVideoRecording() async {
    try {
      if (!_isCameraInitialized || _cameraController == null) {
        throw Exception('Cámara no inicializada');
      }

      if (_isRecordingVideo) return;

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
      
      onError?.call('Error iniciando grabación: $e');
    }
  }

  /// Parar grabación de video
  Future<String?> stopVideoRecording() async {
    try {
      if (!_isRecordingVideo || _cameraController == null) return null;

      _recordingTimer?.cancel();
      _recordingTimer = null;
      _isRecordingVideo = false;

      final videoFile = await _cameraController!.stopVideoRecording();
      _recordedVideoPath = videoFile.path;

      return videoFile.path;
    } catch (e) {
      
      onError?.call('Error parando grabación: $e');
      return null;
    }
  }

  /// Seleccionar imagen de galería
  Future<String?> selectImageFromGallery() async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      return pickedFile?.path;
    } catch (e) {
      
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

  /// Publicar historia
  Future<bool> publishStory({
    required String mediaPath,
    required String mediaType, // 'image' o 'video'
    String? caption,
    Character? character,
  }) async {
    try {
      _setLoading(true);

      // Usar el servicio de historias para crear la historia
      await _storyService.createStory(
        mediaPath: mediaPath,
        mediaType: mediaType,
        caption: caption,
      );

      onSuccess?.call('Historia publicada exitosamente');
      return true;
    } catch (e) {
      
      onError?.call('Error publicando historia: $e');
      return false;
    } finally {
      _setLoading(false);
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

  /// Limpiar recursos
  void dispose() {
    
    _recordingTimer?.cancel();
    _cameraController?.dispose();
    _deepARService.dispose();
    _uploadProgressService.dispose();
  }
}