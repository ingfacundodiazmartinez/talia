import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../controllers/story_camera_controller.dart';
import '../services/deepar_service.dart';
import '../services/subscription_service.dart';
import '../models/character.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/camera/flutter_camera_view.dart';
import '../widgets/camera/deepar_camera_view.dart';
import '../widgets/character_selector_dialog.dart';
import '../widgets/premium_paywall_dialog.dart';
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

  // Estado UI únicamente (ninguno actualmente)

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
    _controller.initialize();
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
      // Reinicializar cuando regresa al foreground
      if (_controller.hasCameraPermissions && !_controller.hasInitializationFailed) {
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
    ).then((openSettings) {
      if (!openSettings && mounted) {
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
      _navigateToStoryEditor(imagePath, 'image');
    }
  }

  Future<void> _toggleVideoRecording() async {
    if (_controller.isRecordingVideo) {
      final videoPath = await _controller.stopVideoRecording();
      if (videoPath != null) {
        _navigateToStoryEditor(videoPath, 'video');
      }
    } else {
      await _controller.startVideoRecording();
    }
  }

  Future<void> _pickFromGallery() async {
    final imagePath = await _controller.selectImageFromGallery();
    if (imagePath != null) {
      _navigateToStoryEditor(imagePath, 'image');
    }
  }

  Future<void> _switchCamera() async {
    await _controller.switchCamera();
  }

  Future<void> _applyColorFilter(String filterName) async {
    _controller.applyColorFilter(filterName);
    setState(() {}); // Rebuild UI
  }

  Future<void> _applyARFilter(String filterName) async {
    await _controller.applyARFilter(filterName);
    setState(() {}); // Rebuild UI
  }

  Future<void> _showCharacterTransformation() async {
    // Verificar suscripción antes de mostrar
    final hasSubscription = await _controller.hasActiveSubscription();
    if (!hasSubscription) {
      // Mostrar paywall
      if (mounted) {
        await PremiumPaywallDialog.show(
          context,
          feature: PremiumFeature.avatarGenerator,
        );
      }
      return;
    }

    // Mostrar selector y esperar resultado
    if (!mounted) return;
    final character = await showDialog<Character>(
      context: context,
      builder: (context) => CharacterSelectorDialog(),
    );

    // Si se seleccionó un personaje, aplicar transformación
    if (character != null) {
      _transformWithCharacter(character);
    }
  }

  Future<void> _transformWithCharacter(Character character) async {
    // Primero tomar foto
    final imagePath = await _controller.takePhoto();
    if (imagePath != null) {
      // Aplicar transformación
      final transformedPath = await _controller.transformImageWithCharacter(imagePath, character);
      if (transformedPath != null) {
        _navigateToStoryEditor(transformedPath, 'image');
      }
    }
  }

  /// Navegar al editor de historias
  void _navigateToStoryEditor(String mediaPath, String mediaType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FlutterStoryEditor(
          selectedFiles: [File(mediaPath)],
          controller: FlutterStoryEditorController(),
          onSaveClickListener: (editedFiles) {
            if (editedFiles.isNotEmpty) {
              _publishStory(editedFiles.first.path, mediaType);
            }
            Navigator.pop(context);
          },
        ),
      ),
    );
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

    if (!_controller.isCameraInitialized) {
      return _buildLoadingUI();
    }

    // Usar DeepAR o Flutter Camera según el tipo de filtro
    if (_controller.filterType == 'deepar' && _controller.isDeepARInitialized) {
      return DeepARCameraView(
        key: ValueKey(_controller.deepARReinitCounter),
        onInitialized: () {
          // DeepAR initialized callback
        },
        deepARService: DeepARService(),
        isDeepARInitialized: _controller.isDeepARInitialized,
      );
    } else if (_controller.cameraController != null && _controller.isCameraInitialized) {
      return FlutterCameraView(
        cameras: _controller.cameras,
        selectedCameraIndex: _controller.selectedCameraIndex,
        onCameraInitialized: (controller) {
          // Camera initialized callback
        },
        onCameraDisposed: () {
          // Camera disposed callback
        },
      );
    }

    return Container(color: Colors.black);
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
          IconButton(
            onPressed: _closeScreen,
            icon: Icon(Icons.close, color: Colors.white, size: 28),
          ),
          IconButton(
            onPressed: _switchCamera,
            icon: Icon(Icons.flip_camera_ios, color: Colors.white, size: 28),
          ),
        ],
      ),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Galería
        IconButton(
          onPressed: _pickFromGallery,
          icon: Icon(Icons.photo_library, color: Colors.white, size: 32),
        ),

        // Botón de captura/grabación
        GestureDetector(
          onTap: _controller.isRecordingVideo ? _toggleVideoRecording : _takePicture,
          onLongPress: _controller.isRecordingVideo ? null : _toggleVideoRecording,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _controller.isRecordingVideo ? Colors.red : Colors.white,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: Icon(
              _controller.isRecordingVideo ? Icons.stop : Icons.camera_alt,
              color: _controller.isRecordingVideo ? Colors.white : Colors.black,
              size: 32,
            ),
          ),
        ),

        // Transformación de personajes
        IconButton(
          onPressed: _showCharacterTransformation,
          icon: Icon(Icons.face, color: Colors.white, size: 32),
        ),
      ],
    );
  }

  Widget _buildFiltersSection() {
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 20),
        children: [
          // Filtros de color
          _buildFilterButton('none', 'Normal', Icons.face),
          _buildFilterButton('sepia', 'Sepia', Icons.filter_vintage),
          _buildFilterButton('black_white', 'B&N', Icons.filter_b_and_w),
          _buildFilterButton('vintage', 'Vintage', Icons.filter_vintage),

          // Filtros AR
          ..._controller.getAvailableDeepARFilters().entries.map((entry) =>
            _buildARFilterButton(entry.key, entry.value['name'], entry.value['emoji'])
          ),
        ],
      ),
    );
  }

  Widget _buildFilterButton(String filterId, String name, IconData icon) {
    final isSelected = _controller.selectedFilter == filterId;

    return GestureDetector(
      onTap: () => _applyColorFilter(filterId),
      child: Container(
        width: 70,
        margin: EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(35),
          border: Border.all(
            color: isSelected ? Color(0xFF9D7FE8) : Colors.white,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            SizedBox(height: 4),
            Text(
              name,
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
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
          border: Border.all(
            color: isSelected ? Color(0xFF9D7FE8) : Colors.white,
            width: isSelected ? 3 : 1,
          ),
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