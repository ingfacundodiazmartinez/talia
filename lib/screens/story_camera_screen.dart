import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart' show FlashMode;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../controllers/story_camera_controller.dart';
import '../services/deepar_service.dart';
import '../utils/release_logger.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/camera/flutter_camera_view.dart';
import '../widgets/camera/deepar_camera_view.dart';
import 'package:flutter_story_editor/flutter_story_editor.dart';
import 'package:flutter_story_editor/src/controller/controller.dart';

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
    with WidgetsBindingObserver {
  // ✅ CORRECTO: Solo controller y estado UI local
  late StoryCameraController _controller;

  // Estado UI únicamente
  bool _isVideoMode = false; // Estado para modo foto/video
  double _baseZoom = 1.0; // Para pinch-to-zoom
  bool _showZoomIndicator = false; // Mostrar indicador de zoom temporalmente

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    final currentUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid ?? '';
    _controller = StoryCameraController(userId: currentUserId);

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // Inicializar controller
    _controller.initialize(context: context);
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

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

  Future<void> _takePicture() async {
    final imagePath = await _controller.takePhoto();
    if (imagePath != null) {
      await _navigateToStoryEditor(imagePath, 'image');
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

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FlutterStoryEditor(
            selectedFiles: [file],
            controller: storyController,
            captionController: captionController,
            onSaveClickListener: (editedFiles) async {
              ReleaseLogger.log('💾 Story editor completado con ${editedFiles.length} archivos', tag: 'StoryCameraScreen');
              if (editedFiles.isNotEmpty) {
                // Cerrar el editor primero
                Navigator.pop(context);
                // Luego publicar la historia (esto cerrará la cámara al terminar)
                await _publishStory(editedFiles.first.path, mediaType);
              } else {
                Navigator.pop(context);
              }
            },
            onFaceSwapClickListener: (currentFile, currentIndex) async {
              return await _handleFaceSwap(currentFile, currentIndex);
            },
          ),
        ),
      );
    } catch (e) {
      ReleaseLogger.error('❌ Error navegando al story editor: $e', tag: 'StoryCameraScreen');
      _controller.onError?.call('Error abriendo editor: $e');
    }
  }

  /// Publicar historia usando el controller
  Future<void> _publishStory(String finalMediaPath, String mediaType) async {
    final success = await _controller.publishStory(
      mediaPath: finalMediaPath,
      mediaType: mediaType,
    );

    if (success && mounted) {
      Navigator.pop(context); // Cerrar cámara después de publicar
    }
  }

  /// Manejar face swap en el editor
  Future<String?> _handleFaceSwap(File currentFile, int currentIndex) async {
    return await _controller.applyFaceSwapToFile(context, currentFile);
  }

  /// ===== BUILD UI =====

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

              // Loading overlay
              if (_controller.isLoading) _buildLoadingOverlay(),
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
        // Selector de modo: FOTO | VIDEO
        _buildModeSelector(),

        SizedBox(height: 20),

        // Controles principales
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Galería
            _buildShadowedIconButton(
              onPressed: _pickFromGallery,
              icon: Icons.photo_library,
            ),

            // Botón principal (cambia según modo)
            _isVideoMode ? _buildVideoButton() : _buildPhotoButton(),

            // Espacio vacío para mantener centrado el botón principal
            SizedBox(width: 48), // Mismo ancho que un IconButton
          ],
        ),
      ],
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

    return GestureDetector(
      onTap: () => _applyARFilter(filterId),
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

}