import 'package:talia/theme_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart' show FlashMode;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../controllers/story_camera_controller.dart';
import '../services/ad_service.dart';
import '../services/bottom_nav_visibility.dart';
import '../utils/release_logger.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/camera/flutter_camera_view.dart';
import 'package:audioplayers/audioplayers.dart';
import 'music/music_generator_screen.dart';
import 'music/music_crop_screen.dart';
import '../services/stories/services/story_music_service.dart';
import '../services/subscription_service.dart';
import '../widgets/premium_paywall_dialog.dart';
import 'package:flutter_story_editor/flutter_story_editor.dart';
// ignore: implementation_imports
import 'package:flutter_story_editor/src/controller/controller.dart';
import 'trivia/trivia_creation_screen.dart';
import '../link_parent_child.dart';

/// Pantalla de cámara para crear historias - REFACTORIZADA
///
/// Responsabilidades (SOLO UI):
/// - Renderizar interfaz de cámara y controles
/// - Manejar estado local de UI (filtros, grabación, etc.)
/// - Coordinar llamadas al StoryCameraController
/// - Navegación y diálogos
class StoryCameraScreen extends StatefulWidget {
  /// Si es true, apenas se captura la foto se abre automáticamente el selector
  /// de face-swap (usado desde el CTA "Generá tu historia con IA" del visor).
  final bool autoOpenFaceSwap;

  const StoryCameraScreen({super.key, this.autoOpenFaceSwap = false});

  @override
  State<StoryCameraScreen> createState() => _StoryCameraScreenState();
}

class _StoryCameraScreenState extends State<StoryCameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // ✅ CORRECTO: Solo controller y estado UI local
  late StoryCameraController _controller;
  final AdService _adService = AdService();

  // Estado UI únicamente
  bool _isVideoMode = false; // Estado para modo foto/video
  double _baseZoom = 1.0; // Para pinch-to-zoom
  bool _showZoomIndicator = false; // Mostrar indicador de zoom temporalmente
  bool _showScreenFlash = false; // ✅ Screen flash para Android (cámara frontal)
  // Default true para no mostrar el pulse antes de saber si ya lo usó (evita
  // un flash de animación que luego se apaga al cargar Hive).
  bool _hasUsedFaceSwap = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Ocultar bottom navbar durante la creación de historia
    BottomNavVisibility.instance.registerFullScreen();

    // ✅ Bloquear orientación a portrait para evitar problemas de rotación de cámara
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid ?? '';
    _controller = StoryCameraController(userId: currentUserId);

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // Inicializar controller
    _controller.initialize(context: context);

    // ✅ Pre-cargar rewarded ad para face-swap (se usa en el editor)
    _adService.loadRewardedAd();

    // Cargar flag de primer uso de face-swap para decidir si mostrar el pulse.
    _loadFaceSwapState();
  }

  Future<void> _loadFaceSwapState() async {
    final used = await _controller.hasUsedFaceSwap();
    if (mounted && used != _hasUsedFaceSwap) {
      setState(() => _hasUsedFaceSwap = used);
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

    // Sin créditos al generar con IA: ofrecer avisar a la familia, o invitar a
    // vincular un padre si el hijo no tiene ninguno.
    _controller.onOutOfCredits = _handleOutOfCredits;

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

    // Apagar el pulse del botón face-swap cuando el usuario lo usa por
    // primera vez (Hive ya queda marcado por el controller).
    _controller.onFaceSwapFirstUse = () {
      if (mounted) {
        setState(() => _hasUsedFaceSwap = true);
      }
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BottomNavVisibility.instance.unregisterFullScreen();

    // 🔒 Restaurar el lock global de la app (solo portrait). Antes este bloque
    // abría las 4 orientaciones, lo que dejaba a la app rotando en landscape
    // por el resto de la sesión hasta el siguiente reinicio. La app entera es
    // portrait-only (ver main.dart).
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Dispose controller which will handle cleanup of any active modals
    _controller.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      // ✅ FIX: Solo reinicializar si la cámara YA estaba inicializada antes
      // Esto evita race condition cuando el diálogo de permisos de Android
      // causa un cambio de lifecycle (pause -> resume) que dispara otra inicialización
      if (_controller.isCameraInitialized && !_controller.hasInitializationFailed) {
        _controller.initialize();
      }
    }
  }

  /// ===== MÉTODOS UI HELPER (NO LÓGICA DE NEGOCIO) =====

  /// Flujo cuando se acaba el crédito al generar con IA.
  Future<void> _handleOutOfCredits() async {
    // Esperar a que cierre el progress dialog del face-swap antes de mostrar el nuestro.
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    final hasParent = await _controller.hasLinkedParent();
    if (!mounted) return;
    if (hasParent) {
      _showRequestCreditsDialog();
    } else {
      _showLinkParentDialog();
    }
  }

  /// Hijo CON padre vinculado: ofrecer avisarle para que cargue créditos.
  void _showRequestCreditsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.auto_awesome, color: Color(0xFF9D7FE8), size: 40),
        title: const Text('Te quedaste sin créditos'),
        content: const Text(
          '¿Avisamos a tu familia para que mire un video y cargue más créditos?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ahora no'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final r = await _controller.requestCreditsFromParents();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(r.message),
                backgroundColor: r.success ? Colors.green : Colors.orange,
              ));
            },
            child: const Text('Avisar a mi familia'),
          ),
        ],
      ),
    );
  }

  /// Hijo SIN padre vinculado: invitar a vincular para seguir generando con IA.
  void _showLinkParentDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.family_restroom, color: Color(0xFF9D7FE8), size: 40),
        title: const Text('Vinculá a tu familia'),
        content: const Text(
          'Vinculá a tu mamá o papá para seguir generando historias con IA.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Ahora no'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const GenerateLinkCodeScreen(),
                ),
              );
            },
            child: const Text('Vincular'),
          ),
        ],
      ),
    );
  }

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
    if (mounted) {
      Navigator.pop(context);
    }
  }

  /// ===== MÉTODOS DE ACCIÓN (LLAMAN AL CONTROLLER) =====

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
      // ✨ Si venimos del CTA "Generá tu historia con IA", abrir el selector de
      // face-swap apenas se toma la foto, antes del editor.
      String finalPath = imagePath;
      bool preAppliedFaceSwap = false;
      if (widget.autoOpenFaceSwap && mounted) {
        final swapped = await _controller.applyFaceSwapToFile(
          context,
          File(imagePath),
        );
        if (swapped != null) {
          finalPath = swapped;
          preAppliedFaceSwap = true;
        }
      }
      await _navigateToStoryEditor(
        finalPath,
        'image',
        preAppliedFaceSwap: preAppliedFaceSwap,
      );
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
    // Forzar rebuild para que FlutterCameraView reciba el nuevo CameraController
    // creado por StoryCameraController.switchCamera().
    if (mounted) {
      setState(() {});
    }
  }

  // Métodos de character transformation removidos - ahora están en el story editor

  /// Navegar al editor de historias
  ///
  /// [preAppliedFaceSwap] = true si ya se aplicó face-swap antes de entrar al
  /// editor (auto-flow). Sirve para marcar la historia como aiGenerated aunque
  /// el usuario no toque el botón de face-swap dentro del editor.
  Future<void> _navigateToStoryEditor(
    String mediaPath,
    String mediaType, {
    bool preAppliedFaceSwap = false,
  }) async {
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
      // Marca si la historia fue generada con IA (face-swap pre-aplicado en el
      // auto-flow, o aplicado por el usuario dentro del editor).
      bool faceSwapApplied = preAppliedFaceSwap;

      // 🎵 Música generada desde el botón del editor (si el usuario la agregó).
      final pendingMusic = ValueNotifier<StoryMusicResult?>(null);

      // Reproductor para escuchar la canción/fragmento mientras se edita la foto.
      final musicPreview = AudioPlayer();
      Future<void> updatePreview(StoryMusicResult? m) async {
        try {
          await musicPreview.stop();
          if (m == null) return;
          await musicPreview.play(UrlSource(m.audioUrl));
          if (m.startMs != null && m.startMs! > 0) {
            await musicPreview.seek(Duration(milliseconds: m.startMs!));
          }
        } catch (_) {}
      }

      // Loop del fragmento: al llegar al fin del clip, volver al inicio.
      final posSub = musicPreview.onPositionChanged.listen((pos) {
        final m = pendingMusic.value;
        if (m?.clipMs != null) {
          final start = m!.startMs ?? 0;
          if (pos.inMilliseconds >= start + m.clipMs!) {
            musicPreview.seek(Duration(milliseconds: start));
          }
        }
      });

      // Resolver el rol una sola vez: los hijos piden créditos a la familia,
      // los adultos pueden ver videos.
      final isChild = await _controller.hasLinkedParent();
      if (!mounted) {
        pendingMusic.dispose();
        await posSub.cancel();
        await musicPreview.dispose();
        return;
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (editorContext) => Stack(
            children: [
              FlutterStoryEditor(
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
                  Navigator.pop(editorContext);
                },
                onFaceSwapClickListener: (currentFile, currentIndex) async {
                  final result = await _handleFaceSwap(currentFile, currentIndex);
                  if (result != null) faceSwapApplied = true;
                  return result;
                },
                // Pulse el botón solo si el usuario nunca usó face-swap, para
                // destacarlo como feature insignia la primera vez.
                showFaceSwapPulse: !_hasUsedFaceSwap,
              ),
              // 🎵 Botón "Música IA" visible dentro del editor.
              Positioned(
                right: 12,
                top: MediaQuery.of(editorContext).padding.top + 60,
                child: ValueListenableBuilder<StoryMusicResult?>(
                  valueListenable: pendingMusic,
                  builder: (ctx, music, _) => _buildEditorMusicButton(
                    hasMusic: music != null,
                    onTap: () async {
                      // Pausar el preview para no superponerlo con el de la
                      // pantalla de generación/recorte.
                      await musicPreview.pause();
                      if (!ctx.mounted) return;
                      if (music == null) {
                        // Generar una canción nueva.
                        final result = await _openMusicGenerator(ctx, isChild);
                        if (result != null) pendingMusic.value = result;
                      } else {
                        // Re-editar el recorte de la canción ya generada.
                        final crop = await _openMusicCrop(ctx, music);
                        if (crop != null) {
                          music.startMs = crop.startMs;
                          music.clipMs = crop.clipMs;
                          music.fragmentLyrics = crop.lyrics;
                          music.displayMode = crop.displayMode;
                          music.title = crop.title;
                          music.lineTimings = crop.lineTimings;
                        }
                      }
                      await updatePreview(pendingMusic.value);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      // Música agregada desde el editor (si la hay).
      final musicResult = pendingMusic.value;
      await posSub.cancel();
      await musicPreview.stop();
      await musicPreview.dispose();
      pendingMusic.dispose();

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
          aiGenerated: faceSwapApplied || musicResult != null,
          musicUrl: musicResult?.audioUrl,
          musicPrompt: musicResult?.prompt,
          musicLyrics: musicResult?.fragmentLyrics,
          musicStartMs: musicResult?.startMs,
          musicClipMs: musicResult?.clipMs,
          musicTitle: musicResult?.title,
          musicDisplayMode: musicResult?.displayMode,
          musicLyricsTimings: musicResult?.lineTimings,
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

  /// Abre el generador de música (pantalla con el diseño estándar de imágenes
  /// IA). Devuelve la canción generada, o null si el usuario salió sin crear.
  /// Abre solo la pantalla de recorte para una canción YA generada (re-editar
  /// el fragmento sin regenerar). Usa la letra completa (no el fragmento).
  Future<MusicCrop?> _openMusicCrop(BuildContext ctx, StoryMusicResult m) {
    return Navigator.of(ctx).push<MusicCrop>(
      MaterialPageRoute(
        builder: (_) => MusicCropScreen(
          audioUrl: m.audioUrl,
          taskId: m.taskId,
          fullLyrics: m.lyrics,
          defaultTitle: m.title ?? m.defaultTitle,
          onFetchAlignment: _controller.fetchMusicAlignment,
        ),
      ),
    );
  }

  /// Feature para el paywall de música (creación de canciones con IA).
  static const _musicPremiumFeature = PremiumFeature(
    id: 'ai_music',
    name: 'Música con IA',
    description: 'Creá canciones únicas con IA para tus historias',
    requiredTier: SubscriptionTier.premium,
    iconName: '🎵',
  );

  Future<StoryMusicResult?> _openMusicGenerator(BuildContext ctx, bool isChild) async {
    // 🔒 Gate premium: la creación de canciones es exclusiva de Premium/Premium+.
    final isPremium = await _controller.hasActiveSubscription();
    if (!isPremium) {
      if (ctx.mounted) {
        PremiumPaywallDialog.show(ctx, feature: _musicPremiumFeature);
      }
      return null;
    }
    if (!ctx.mounted) return null;
    return await showMusicGenerator(
      ctx,
      onGenerate: _controller.generateMusic,
      creditCost: StoryCameraController.songCreditCost,
      creditsStream: _controller.watchAvailableCredits(),
      onWatchAds: isChild ? null : _controller.watchAdsForCredits,
      onRequestCredits: isChild ? _controller.requestCreditsFromFamily : null,
      onFetchAlignment: _controller.fetchMusicAlignment,
    );
  }

  /// Botón "Música IA" que se muestra dentro del editor de historias.
  Widget _buildEditorMusicButton({required bool hasMusic, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFB388FF), Color(0xFF7C4DFF)]),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasMusic ? Icons.check_rounded : Icons.music_note_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              hasMusic ? 'Música ✓' : 'Música IA',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// ===== BUILD UI =====

  /// Verifica si la vista de cámara está mostrando preview real (no loading)
  /// Usado para evitar mostrar doble spinner durante inicialización
  bool _isCameraViewReady() {
    // Si no hay permisos o hubo error, no mostrar loading overlay
    if (!_controller.hasCameraPermissions || _controller.hasInitializationFailed) {
      return false;
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

    if (_controller.cameraController != null && _controller.isCameraInitialized) {
      cameraWidget = FlutterCameraView(
        controller: _controller.cameraController!,
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
          CircularProgressIndicator(color: ThemeService.primaryColor),
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
          // Controles de cámara (flash, switch) + música IA
          Row(
            children: [
              // Crear historia de solo música con IA
              _buildMusicStoryButton(),
              SizedBox(width: 8),
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

  /// Botón para crear una historia de solo-música con IA.
  Widget _buildMusicStoryButton() {
    return GestureDetector(
      onTap: _openMusicStoryCreation,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFB388FF), Color(0xFF7C4DFF)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7C4DFF).withValues(alpha: 0.5),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 24),
      ),
    );
  }

  /// Abre el flujo de creación de historia de solo-música.
  Future<void> _openMusicStoryCreation() async {
    // Los hijos no pueden ver videos: piden créditos a la familia.
    final isChild = await _controller.hasLinkedParent();
    if (!mounted) return;
    final result = await _openMusicGenerator(context, isChild);
    if (result == null || !mounted) return;

    // Cerrar la cámara y publicar en background (UX optimista).
    Navigator.pop(context);
    _controller.publishMusicOnlyStory(
      musicUrl: result.audioUrl,
      musicPrompt: result.prompt,
      musicLyrics: result.fragmentLyrics,
      musicStartMs: result.startMs,
      musicClipMs: result.clipMs,
      musicTitle: result.title,
      musicDisplayMode: result.displayMode,
      musicLyricsTimings: result.lineTimings,
      // El prompt ya NO se usa como caption: la historia muestra título o letra.
      caption: null,
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
        // Selector de modo: FOTO | VIDEO
        _buildModeSelector(),

        SizedBox(height: 20),

        // Controles principales
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Galería o botón de Trivia
            _isVideoMode
                ? _buildShadowedIconButton(
                    onPressed: _pickFromGallery,
                    icon: Icons.photo_library,
                  )
                : _buildTriviaButton(),

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
          color: isSelected ? ThemeService.primaryColor : Colors.transparent,
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

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: CircularProgressIndicator(color: ThemeService.primaryColor),
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