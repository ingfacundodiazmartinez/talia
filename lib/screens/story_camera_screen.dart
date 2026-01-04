import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart' show FlashMode;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/story_camera_controller.dart';
import '../theme_service.dart';
import '../models/character.dart';
import '../services/deepar_service.dart';
import '../services/ad_service.dart';
import '../services/usage_limits_service.dart';
import '../services/subscription_service.dart';
import '../utils/release_logger.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/character_selector_dialog.dart';
import '../widgets/premium_paywall_dialog.dart';
import '../widgets/camera/flutter_camera_view.dart';
import '../widgets/camera/deepar_camera_view.dart';
import 'package:flutter_story_editor/flutter_story_editor.dart';
import 'package:flutter_story_editor/src/controller/controller.dart';
import 'trivia/trivia_creation_screen.dart';

/// Pantalla de cámara para crear historias - REFACTORIZADA
///
/// Responsabilidades (SOLO UI):
/// - Renderizar interfaz de cámara y controles
/// - Manejar estado local de UI (filtros, grabación, etc.)
/// - Coordinar llamadas al StoryCameraController
/// - Navegación y diálogos
class StoryCameraScreen extends StatefulWidget {
  const StoryCameraScreen({super.key});

  @override
  State<StoryCameraScreen> createState() => _StoryCameraScreenState();
}

class _StoryCameraScreenState extends State<StoryCameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ✅ CORRECTO: Solo controller y estado UI local
  late StoryCameraController _controller;
  final AdService _adService = AdService();
  final UsageLimitsService _usageLimitsService = UsageLimitsService();

  // Estado UI únicamente
  bool _isVideoMode = false; // Estado para modo foto/video
  double _baseZoom = 1.0; // Para pinch-to-zoom
  bool _showZoomIndicator = false; // Mostrar indicador de zoom temporalmente
  Character? _selectedFaceSwapCharacter; // Personaje seleccionado para Face Swap
  bool _showScreenFlash = false; // ✅ Screen flash para Android (cámara frontal)

  // Face-swap pulsing animation (para usuarios que nunca lo han usado)
  late AnimationController _faceSwapPulseController;
  late Animation<double> _faceSwapPulseAnimation;
  bool _hasUsedFaceSwap = true; // Default true para no mostrar animación hasta cargar

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // ✅ Bloquear orientación a portrait para evitar problemas de rotación de cámara
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    // Inicializar animación de pulso para face-swap
    _faceSwapPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _faceSwapPulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(
        parent: _faceSwapPulseController,
        curve: Curves.easeInOut,
      ),
    );

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid ?? '';
    _controller = StoryCameraController(userId: currentUserId);

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // Verificar si el usuario ya usó face-swap
    _loadFaceSwapStatus();

    // Inicializar controller
    _controller.initialize(context: context);

    // ✅ Pre-cargar rewarded ad para face-swap
    _adService.loadRewardedAd();
  }

  /// Cargar estado de uso de face-swap
  Future<void> _loadFaceSwapStatus() async {
    final hasUsed = await _controller.hasUsedFaceSwap();
    if (mounted) {
      setState(() {
        _hasUsedFaceSwap = hasUsed;
      });
      // Si no ha usado, iniciar animación de pulso
      if (!hasUsed) {
        _faceSwapPulseController.repeat(reverse: true);
      }
    }
  }

  /// Configurar callbacks del controller para actualizar UI
  void _setupControllerCallbacks() {
    _controller.onError = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    };

    _controller.onSuccess = (message) {
      // Success feedback removed - only show errors
    };

    _controller.onPermissionDenied = () {
      _showAppSettingsDialog();
    };

    _controller.onPermissionGranted = () {
      // Los permisos fueron concedidos, simplemente continuar sin mostrar mensajes
      // La cámara se inicializará automáticamente y el usuario verá el preview
    };

    _controller.onCameraInitialized = () {
      if (mounted) {
        setState(() {
          // Trigger rebuild cuando la cámara esté lista
        });
      }
    };

    _controller.onLoadingChanged = (loading) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para loading states
        });
      }
    };

    _controller.onRecordingTimeChanged = (timeRemaining) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para timer de grabación
        });
      }
    };

    _controller.onFaceSwapFirstUse = () {
      if (mounted) {
        setState(() {
          _hasUsedFaceSwap = true;
        });
        _faceSwapPulseController.stop();
      }
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _faceSwapPulseController.dispose();

    // ✅ Restaurar orientaciones permitidas al salir
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Dispose controller which will handle cleanup of any active modals
    _controller.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      // Pausar cámara cuando la app va al background
      _controller.cleanupDeepAR();
    } else if (state == AppLifecycleState.resumed) {
      // ✅ FIX: Solo reinicializar si la cámara YA estaba inicializada antes
      // Esto evita race condition cuando el diálogo de permisos de Android
      // causa un cambio de lifecycle (pause -> resume) que dispara otra inicialización
      if (_controller.isCameraInitialized && !_controller.hasInitializationFailed) {
        _controller.initialize();
      }
    }
  }

  /// ===== MÉTODOS UI HELPER (NO LÓGICA DE NEGOCIO) =====

  void _showAppSettingsDialog() {
    PermissionDialog.showPermissionDeniedDialog(
      context: context,
      title: 'Permiso de Cámara Requerido',
      message: 'Para crear historias necesitas habilitar el acceso a la cámara en la configuración de la aplicación.',
    ).then((openSettings) async {
      if (openSettings && mounted) {
        // El usuario fue a configuración, reintentar cuando regrese
        ReleaseLogger.log('📱 Usuario regresó de configuración, reintentando inicialización...', tag: 'StoryCameraScreen');
        await _controller.retryInitialization(context: context);
      } else if (!openSettings && mounted) {
        // El usuario canceló, cerrar la pantalla
        Navigator.pop(context);
      }
    });
  }

  Future<void> _closeScreen() async {
    await _controller.cleanupDeepAR();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  /// ===== MÉTODOS DE ACCIÓN (LLAMAN AL CONTROLLER) =====

  /// Mostrar selector de personajes para Face Swap
  Future<void> _showFaceSwapSelector() async {
    // Obtener transformaciones restantes para mostrar en el dialog
    final usageData = await _usageLimitsService.getFaceSwapDailyUsage();
    final remaining = usageData['remaining'] as int;

    // Mostrar selector de personajes
    final selectedCharacter = await showDialog<Character>(
      context: context,
      builder: (context) => CharacterSelectorDialog(
        remainingTransforms: remaining,
      ),
    );

    if (selectedCharacter != null && mounted) {
      setState(() {
        _selectedFaceSwapCharacter = selectedCharacter;
      });
      ReleaseLogger.log('🎭 Personaje seleccionado: ${selectedCharacter.name}', tag: 'StoryCameraScreen');
    }
  }

  /// Cancelar modo Face Swap
  void _cancelFaceSwapMode() {
    setState(() {
      _selectedFaceSwapCharacter = null;
    });
  }

  Future<void> _takePicture() async {
    // ✅ Screen flash para Android: mostrar pantalla blanca antes de la foto
    final useScreenFlash = Platform.isAndroid && _controller.shouldUseScreenFlash;

    if (useScreenFlash) {
      setState(() => _showScreenFlash = true);
      // Esperar a que el flash se muestre y la pantalla brille
      await Future.delayed(const Duration(milliseconds: 150));
    }

    final imagePath = await _controller.takePhoto();

    // Quitar screen flash
    if (useScreenFlash && mounted) {
      setState(() => _showScreenFlash = false);
    }

    if (imagePath != null) {
      // Si hay un personaje seleccionado, procesar Face Swap
      if (_selectedFaceSwapCharacter != null) {
        await _processFaceSwapPhoto(imagePath);
      } else {
        await _navigateToStoryEditor(imagePath, 'image');
      }
    }
  }

  /// Procesar foto con Face Swap usando el personaje pre-seleccionado
  Future<void> _processFaceSwapPhoto(String imagePath) async {
    final character = _selectedFaceSwapCharacter;
    if (character == null) return;

    // ✅ PASO 1: Verificar límites de uso diario
    final usageData = await _usageLimitsService.getFaceSwapDailyUsage();
    final remaining = usageData['remaining'] as int;
    final limit = usageData['limit'] as int;
    final tier = usageData['tier'] as String;
    final isUnlimited = usageData['unlimited'] == true;

    // Si no quedan transformaciones (y NO es unlimited), mostrar paywall
    // remaining == -1 significa unlimited, no límite alcanzado
    if (!isUnlimited && remaining <= 0) {
      if (mounted) {
        ReleaseLogger.log('⚠️ Límite de face-swap alcanzado ($limit/día para tier $tier)', tag: 'StoryCameraScreen');
        await PremiumPaywallDialog.show(
          context,
          feature: PremiumFeature(
            id: 'face_swap_limit',
            name: 'Face Swap',
            description: 'Has alcanzado el límite de $limit transformaciones por día. Actualiza a Premium para obtener más transformaciones diarias.',
            iconName: '🎭',
            requiredTier: SubscriptionTier.premium,
          ),
        );
        // Limpiar selección
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
      }
      return;
    }

    // ✅ PASO 2: Verificar si necesita ver ads o tiene Premium
    final canShowAds = await _adService.canShowAds();
    if (canShowAds) {
      // Mostrar diálogo con opciones: Ver video O Activar Premium
      final dialogResult = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: Colors.grey[900],
          title: Row(
            children: [
              Icon(Icons.face_retouching_natural, color: Color(0xFF9D7FE8), size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Transformar foto',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mira un breve video para transformarte en ${character.name}.',
                style: TextStyle(fontSize: 15, color: Colors.white70),
              ),
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(isUnlimited ? Icons.all_inclusive : Icons.info_outline, color: Colors.white54, size: 16),
                    SizedBox(width: 8),
                    Text(
                      isUnlimited ? 'Sin límite de uso' : '$remaining de $limit restantes hoy',
                      style: TextStyle(fontSize: 13, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            // Botón Premium (solo si premium está habilitado)
            if (!isUnlimited)
              OutlinedButton(
                onPressed: () => Navigator.pop(context, 'premium'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Color(0xFFFFD700)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star, color: Color(0xFFFFD700), size: 18),
                    SizedBox(width: 4),
                    Text('Premium', style: TextStyle(color: Color(0xFFFFD700))),
                  ],
                ),
              ),
            // Botón Ver video
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 'watch'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text('Ver video'),
            ),
          ],
        ),
      );

      if (dialogResult == 'cancel' || dialogResult == null) {
        // Usuario canceló, limpiar selección
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
        return;
      }

      if (dialogResult == 'premium') {
        // Mostrar paywall de Premium
        if (mounted) {
          PremiumPaywallDialog.show(
            context,
            feature: PremiumFeature(
              id: 'face_swap_no_ads',
              name: 'Face Swap sin anuncios',
              description: 'Con Premium puedes usar Face Swap sin ver anuncios y con más transformaciones diarias.',
              iconName: '🎭',
              requiredTier: SubscriptionTier.premium,
            ),
          );
        }
        // Limpiar selección
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
        return;
      }

      // dialogResult == 'watch': Mostrar rewarded ad
      final rewarded = await _adService.showRewardedAd();
      if (!rewarded) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Debes ver el video completo para usar Face Swap'),
              backgroundColor: Colors.orange,
            ),
          );
          // Limpiar selección
          setState(() {
            _selectedFaceSwapCharacter = null;
          });
        }
        return;
      }
    }

    try {
      // ✅ PASO 3: Procesar transformación
      final transformedPath = await _controller.applyFaceSwapWithCharacter(
        context,
        File(imagePath),
        character,
      );

      if (transformedPath != null && mounted) {
        // ✅ PASO 4: Incrementar contador de uso
        await _usageLimitsService.incrementFaceSwapDailyUsage();

        // Limpiar selección de personaje
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
        // Navegar al editor con la imagen transformada
        await _navigateToStoryEditor(transformedPath, 'image');
      } else if (mounted) {
        // Face swap falló silenciosamente
        ReleaseLogger.error('❌ Face swap retornó null', tag: 'StoryCameraScreen');
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al procesar Face Swap. Intenta de nuevo.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error procesando Face Swap: $e', tag: 'StoryCameraScreen');
      _controller.onError?.call('Error en Face Swap: $e');
      // Limpiar selección en caso de error
      if (mounted) {
        setState(() {
          _selectedFaceSwapCharacter = null;
        });
      }
    }
  }

  Future<void> _toggleVideoRecording() async {
    if (_controller.isRecordingVideo) {
      final videoPath = await _controller.stopVideoRecording();
      if (videoPath != null) {
        await _navigateToStoryEditor(videoPath, 'video');
      }
    } else {
      await _controller.startVideoRecording();
    }
  }

  Future<void> _pickFromGallery() async {
    final imagePath = await _controller.selectImageFromGallery();
    if (imagePath != null) {
      await _navigateToStoryEditor(imagePath, 'image');
    }
  }

  Future<void> _switchCamera() async {
    await _controller.switchCamera();
    // Forzar rebuild para que FlutterCameraView reciba el nuevo selectedCameraIndex
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _applyARFilter(String filterName) async {
    await _controller.applyARFilter(filterName);
    setState(() {}); // Rebuild UI
  }

  // Métodos de character transformation removidos - ahora están en el story editor

  /// Navegar al editor de historias
  Future<void> _navigateToStoryEditor(String mediaPath, String mediaType) async {
    try {
      ReleaseLogger.log('🎬 Navegando al editor con: $mediaPath (tipo: $mediaType)', tag: 'StoryCameraScreen');

      // Verificar que el archivo existe antes de navegar
      final file = File(mediaPath);
      if (!await file.exists()) {
        _controller.onError?.call('Error: El archivo no existe');
        return;
      }

      final fileSize = await file.length();
      ReleaseLogger.log('📂 Archivo válido - Tamaño: $fileSize bytes', tag: 'StoryCameraScreen');

      if (fileSize == 0) {
        _controller.onError?.call('Error: El archivo está vacío');
        return;
      }

      // Verificar que es una imagen válida para story editor
      if (mediaType == 'image') {
        final extension = mediaPath.toLowerCase().split('.').last;
        if (!['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(extension)) {
          _controller.onError?.call('Formato de imagen no soportado: $extension');
          return;
        }
      }

      ReleaseLogger.log('✅ Archivo validado, abriendo story editor...', tag: 'StoryCameraScreen');

      if (!mounted) return;

      // ✅ CRUCIAL: Crear controllers UNA SOLA VEZ para evitar recrearlos en rebuilds
      final storyController = FlutterStoryEditorController();
      final captionController = TextEditingController();

      // Variables para capturar resultado del editor
      String? editedFilePath;
      String? capturedCaption;
      bool shouldPublish = false;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FlutterStoryEditor(
            selectedFiles: [file],
            controller: storyController,
            captionController: captionController,
            onSaveClickListener: (editedFiles) {
              ReleaseLogger.log('💾 Story editor completado con ${editedFiles.length} archivos', tag: 'StoryCameraScreen');
              if (editedFiles.isNotEmpty) {
                // Capturar datos para publicar DESPUÉS de que el editor cierre
                editedFilePath = editedFiles.first.path;
                capturedCaption = captionController.text.trim();
                shouldPublish = true;
                ReleaseLogger.log('📝 Caption capturado: "${capturedCaption?.isNotEmpty == true ? capturedCaption : "(vacío)"}"', tag: 'StoryCameraScreen');
              }
              // Cerrar el editor - Navigator.push retornará después de esto
              Navigator.pop(context);
            },
            onFaceSwapClickListener: (currentFile, currentIndex) async {
              return await _handleFaceSwap(currentFile, currentIndex);
            },
          ),
        ),
      );

      // ✅ FIX: Cerrar cámara INMEDIATAMENTE y publicar en background
      // Navegación optimista - el usuario no espera la subida
      if (shouldPublish && editedFilePath != null && mounted) {
        ReleaseLogger.log('📤 Cerrando cámara y publicando en background...', tag: 'StoryCameraScreen');

        // Cerrar cámara primero (navegación inmediata)
        Navigator.pop(context);

        // Publicar en background (no await)
        _controller.publishStory(
          mediaPath: editedFilePath!,
          mediaType: mediaType,
          caption: capturedCaption?.isNotEmpty == true ? capturedCaption : null,
        );
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error navegando al story editor: $e', tag: 'StoryCameraScreen');
      _controller.onError?.call('Error abriendo editor: $e');
    }
  }

  /// Manejar face swap en el editor
  Future<String?> _handleFaceSwap(File currentFile, int currentIndex) async {
    return await _controller.applyFaceSwapToFile(context, currentFile);
  }

  /// ===== BUILD UI =====

  /// Verifica si la vista de cámara está mostrando preview real (no loading)
  /// Usado para evitar mostrar doble spinner durante inicialización
  bool _isCameraViewReady() {
    // Si no hay permisos o hubo error, no mostrar loading overlay
    if (!_controller.hasCameraPermissions || _controller.hasInitializationFailed) {
      return false;
    }

    // Para DeepAR: verificar si está inicializado
    if (_controller.filterType == 'deepar') {
      return _controller.isDeepARInitialized;
    }

    // Para cámara Flutter: verificar si está inicializada
    return _controller.cameraController != null && _controller.isCameraInitialized;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _closeScreen();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              // Vista de cámara
              _buildCameraView(),

              // Overlay de controles
              _buildControlsOverlay(),

              // Loading overlay - solo mostrar cuando la cámara ya está lista
              // (para operaciones como tomar foto, grabar, etc.)
              // Durante inicialización, _buildCameraView() ya muestra _buildLoadingUI()
              if (_controller.isLoading && _isCameraViewReady()) _buildLoadingOverlay(),

              // ✅ Screen flash overlay para Android (cámara frontal)
              if (_showScreenFlash) _buildScreenFlashOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraView() {
    // Verificar estado de inicialización
    if (!_controller.hasCameraPermissions) {
      return _buildPermissionDeniedUI();
    }

    if (_controller.hasInitializationFailed) {
      return _buildErrorUI();
    }

    // Widget de cámara base
    Widget cameraWidget;

    // ✅ FIX: Verificar DeepAR PRIMERO, antes de verificar Flutter camera
    // Cuando se activa DeepAR, Flutter camera se dispone (isCameraInitialized = false)
    // por lo que debemos verificar DeepAR antes de mostrar loading
    if (_controller.filterType == 'deepar') {
      if (_controller.isDeepARInitialized) {
        cameraWidget = DeepARCameraView(
          key: ValueKey(_controller.deepARReinitCounter),
          onInitialized: () {
            // DeepAR initialized callback
          },
          deepARService: DeepARService(),
          isDeepARInitialized: _controller.isDeepARInitialized,
          reinitCounter: _controller.deepARReinitCounter, // ✅ FIX #6: Pasar contador para forzar recreación del platform view
        );
      } else {
        // DeepAR está inicializando
        return _buildLoadingUI();
      }
    } else if (_controller.cameraController != null && _controller.isCameraInitialized) {
      cameraWidget = FlutterCameraView(
        cameras: _controller.cameras,
        selectedCameraIndex: _controller.selectedCameraIndex,
        onCameraInitialized: (controller) {
          // Camera initialized callback
        },
        onCameraDisposed: () {
          // Camera disposed callback
        },
      );
    } else if (!_controller.isCameraInitialized) {
      // Flutter camera está inicializando
      return _buildLoadingUI();
    } else {
      return Container(color: Colors.black);
    }

    // Envolver con GestureDetector para pinch-to-zoom
    return Stack(
      children: [
        GestureDetector(
          onScaleStart: (details) {
            _baseZoom = _controller.currentZoom;
          },
          onScaleUpdate: (details) async {
            await _controller.handlePinchZoom(details.scale, _baseZoom);
            setState(() {
              _showZoomIndicator = true;
            });
          },
          onScaleEnd: (details) {
            // Ocultar indicador después de un momento
            Future.delayed(Duration(milliseconds: 500), () {
              if (mounted) {
                setState(() {
                  _showZoomIndicator = false;
                });
              }
            });
          },
          child: cameraWidget,
        ),
        // Indicador de zoom
        if (_showZoomIndicator && _controller.maxZoom > 1.0)
          _buildZoomIndicator(),
      ],
    );
  }

  /// Indicador visual de nivel de zoom
  Widget _buildZoomIndicator() {
    return Positioned(
      bottom: 200,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${_controller.currentZoom.toStringAsFixed(1)}x',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedUI() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.camera_alt, size: 64, color: Colors.white),
          SizedBox(height: 16),
          Text(
            'Permiso de cámara requerido',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          SizedBox(height: 16),
          ElevatedButton(
            onPressed: _showAppSettingsDialog,
            child: Text('Configurar permisos'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorUI() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error, size: 64, color: Colors.red),
          SizedBox(height: 16),
          Text(
            'Error inicializando cámara',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingUI() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Color(0xFF9D7FE8)),
          SizedBox(height: 16),
          Text(
            'Inicializando cámara...',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return Column(
      children: [
        // Header con botón cerrar y switch cámara
        _buildHeader(),

        Spacer(),

        // Timer de grabación si está grabando
        if (_controller.isRecordingVideo) _buildRecordingTimer(),

        // Controles principales
        _buildMainControls(),

        const SizedBox(height: 20),

        // Filtros
        _buildFiltersSection(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Botón cerrar
          _buildShadowedIconButton(
            onPressed: _closeScreen,
            icon: Icons.close,
          ),
          // Controles de cámara (flash, switch)
          Row(
            children: [
              // Flash button - disponible para ambas cámaras
              _buildFlashButton(),
              SizedBox(width: 8),
              // Switch camera button
              _buildShadowedIconButton(
                onPressed: _switchCamera,
                icon: Icons.flip_camera_ios,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Botón con sombra para visibilidad en fondos claros
  Widget _buildShadowedIconButton({
    required VoidCallback onPressed,
    required IconData icon,
    String? tooltip,
  }) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 28),
        tooltip: tooltip,
      ),
    );
  }

  /// Botón de flash con icono según el modo actual
  Widget _buildFlashButton() {
    IconData flashIcon;
    String tooltip;

    switch (_controller.flashMode) {
      case FlashMode.off:
        flashIcon = Icons.flash_off;
        tooltip = 'Flash apagado';
        break;
      case FlashMode.auto:
        flashIcon = Icons.flash_auto;
        tooltip = 'Flash automático';
        break;
      case FlashMode.always:
        flashIcon = Icons.flash_on;
        tooltip = 'Flash encendido';
        break;
      case FlashMode.torch:
        flashIcon = Icons.highlight;
        tooltip = 'Linterna';
        break;
    }

    return _buildShadowedIconButton(
      onPressed: () async {
        await _controller.toggleFlashMode();
        setState(() {});
      },
      icon: flashIcon,
      tooltip: tooltip,
    );
  }

  Widget _buildRecordingTimer() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '00:${_controller.recordingSecondsRemaining.toString().padLeft(2, '0')}',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildMainControls() {
    return Column(
      children: [
        // Indicador de Face Swap activo
        if (_selectedFaceSwapCharacter != null) _buildFaceSwapIndicator(),

        // Selector de modo: FOTO | VIDEO (ocultar si Face Swap activo)
        if (_selectedFaceSwapCharacter == null) _buildModeSelector(),

        SizedBox(height: 20),

        // Controles principales
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Galería o botones de features (Face Swap + Trivia)
            _isVideoMode
                ? _buildShadowedIconButton(
                    onPressed: _pickFromGallery,
                    icon: Icons.photo_library,
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildFaceSwapButton(),
                      const SizedBox(width: 12),
                      _buildTriviaButton(),
                    ],
                  ),

            // Botón principal (cambia según modo)
            _isVideoMode ? _buildVideoButton() : _buildPhotoButton(),

            // Galería (si estamos en modo foto)
            _isVideoMode
                ? SizedBox(width: 48)
                : _buildShadowedIconButton(
                    onPressed: _pickFromGallery,
                    icon: Icons.photo_library,
                  ),
          ],
        ),
      ],
    );
  }

  /// Botón de Face Swap prominente
  Widget _buildFaceSwapButton() {
    final isActive = _selectedFaceSwapCharacter != null;

    // Si el usuario nunca ha usado face-swap y el botón no está activo, mostrar con animación
    final showPulsingAnimation = !_hasUsedFaceSwap && !isActive;

    Widget button = GestureDetector(
      onTap: isActive ? _cancelFaceSwapMode : _showFaceSwapSelector,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isActive
              ? LinearGradient(
                  colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
                )
              : showPulsingAnimation
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        context.customColors.gradientStart,
                        context.customColors.gradientEnd,
                      ],
                    )
                  : null,
          color: (isActive || showPulsingAnimation) ? null : Colors.black.withValues(alpha: 0.5),
          border: Border.all(
            color: isActive
                ? Color(0xFF9D7FE8)
                : showPulsingAnimation
                    ? context.customColors.gradientStart
                    : Colors.white,
            width: showPulsingAnimation ? 3 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? Color(0xFF9D7FE8).withValues(alpha: 0.5)
                  : showPulsingAnimation
                      ? context.customColors.gradientStart.withValues(alpha: 0.6)
                      : Colors.black.withValues(alpha: 0.4),
              blurRadius: isActive ? 12 : (showPulsingAnimation ? 16 : 8),
              spreadRadius: isActive ? 2 : (showPulsingAnimation ? 4 : 1),
            ),
          ],
        ),
        child: isActive && _selectedFaceSwapCharacter!.thumbnailUrl.isNotEmpty
            ? ClipOval(
                child: CachedNetworkImage(
                  imageUrl: _selectedFaceSwapCharacter!.thumbnailUrl,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Icon(
                    Icons.face_retouching_natural,
                    color: Colors.white,
                    size: 28,
                  ),
                  errorWidget: (context, url, error) => Icon(
                    Icons.face_retouching_natural,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              )
            : Icon(
                Icons.face_retouching_natural,
                color: Colors.white,
                size: 28,
              ),
      ),
    );

    // Envolver con animación de pulso si es primera vez
    if (showPulsingAnimation) {
      return ScaleTransition(
        scale: _faceSwapPulseAnimation,
        child: button,
      );
    }

    return button;
  }

  /// Indicador visual de Face Swap activo
  Widget _buildFaceSwapIndicator() {
    final character = _selectedFaceSwapCharacter;
    if (character == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF9D7FE8).withValues(alpha: 0.9),
            Color(0xFFB39DDB).withValues(alpha: 0.9),
          ],
        ),
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
            color: Color(0xFF9D7FE8).withValues(alpha: 0.4),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.face_retouching_natural, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(
            'Face Swap: ${character.name}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _cancelFaceSwapMode,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  /// Navegar a pantalla de creación de trivia
  Future<void> _openTriviaCreation() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TriviaCreationScreen()),
    );

    if (result != null && mounted) {
      // result es el triviaId - si quisieras hacer algo con él
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Trivia creada exitosamente!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// Botón de Trivia
  Widget _buildTriviaButton() {
    return GestureDetector(
      onTap: _openTriviaCreation,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF667eea), Color(0xFF764ba2)],
          ),
          border: Border.all(
            color: Colors.white,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF667eea).withValues(alpha: 0.5),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.quiz_rounded,
          color: Colors.white,
          size: 28,
        ),
      ),
    );
  }

  /// Widget selector de modo FOTO/VIDEO - SOLO UI
  Widget _buildModeSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModeButton('FOTO', !_isVideoMode),
          _buildModeButton('VIDEO', _isVideoMode),
        ],
      ),
    );
  }

  /// Widget botón de modo - SOLO UI
  Widget _buildModeButton(String text, bool isSelected) {
    return GestureDetector(
      onTap: () => setState(() => _isVideoMode = text == 'VIDEO'),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Color(0xFF9D7FE8) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  /// Widget botón de foto - SOLO UI, delega al controller
  Widget _buildPhotoButton() {
    return GestureDetector(
      onTap: _takePicture,
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: Colors.white, width: 4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(
          Icons.camera_alt,
          color: Colors.black,
          size: 32,
        ),
      ),
    );
  }

  /// Widget botón de video - SOLO UI, delega al controller
  Widget _buildVideoButton() {
    return GestureDetector(
      onTap: _toggleVideoRecording,
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _controller.isRecordingVideo ? Colors.red : Colors.red.withValues(alpha: 0.8),
          border: Border.all(color: Colors.white, width: 4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Icon(
          _controller.isRecordingVideo ? Icons.stop : Icons.videocam,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }

  Widget _buildFiltersSection() {
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 20),
        children: [
          // Filtros AR
          ..._controller.getAvailableDeepARFilters().entries.map((entry) =>
            _buildARFilterButton(entry.key, entry.value['name'], entry.value['emoji'])
          ),
        ],
      ),
    );
  }

  Widget _buildARFilterButton(String filterId, String name, String emoji) {
    final isSelected = _controller.selectedARFilter == filterId;
    // Deshabilitar filtros mientras la cámara está inicializando
    final isDisabled = !_isCameraViewReady() || _controller.isLoading;

    return GestureDetector(
      onTap: isDisabled ? null : () => _applyARFilter(filterId),
      child: Opacity(
        opacity: isDisabled ? 0.4 : 1.0,
        child: Container(
          width: 70,
          margin: EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(35),
            color: Colors.black.withValues(alpha: 0.3),
            border: Border.all(
              color: isSelected ? Color(0xFF9D7FE8) : Colors.white,
              width: isSelected ? 3 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(emoji, style: TextStyle(fontSize: 32)),
              SizedBox(height: 4),
              Text(
                name,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  shadows: [
                    Shadow(
                      color: Colors.black,
                      blurRadius: 4,
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: CircularProgressIndicator(color: Color(0xFF9D7FE8)),
      ),
    );
  }

  /// ✅ Screen flash overlay para Android (simula flash de cámara frontal)
  Widget _buildScreenFlashOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.white,
      ),
    );
  }

}