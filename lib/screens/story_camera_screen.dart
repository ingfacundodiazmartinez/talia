import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import '../services/deepar_service.dart';
import '../widgets/permission_dialog.dart';
import 'story/story_preview_screen.dart';
import '../widgets/camera/flutter_camera_view.dart';
import '../widgets/camera/deepar_camera_view.dart';

class StoryCameraScreen extends StatefulWidget {
  const StoryCameraScreen({super.key});

  @override
  State<StoryCameraScreen> createState() => _StoryCameraScreenState();
}

class _StoryCameraScreenState extends State<StoryCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isCameraInitialized = false;
  bool _isLoading = false;
  int _selectedCameraIndex = 0;
  String? _selectedFilter;
  String? _selectedARFilter = DeepARFilters.baseBeauty; // Iniciar con el nuevo filtro
  String _filterType = 'deepar'; // Solo DeepAR por defecto
  bool _hasInitializationFailed = false;
  bool _isDeepARInitialized = false;
  bool _hasCameraPermissions = false; // CRÍTICO: Flag para saber si tenemos permisos

  final DeepARService _deepARService = DeepARService();

  // Filtros DeepAR disponibles realmente
  final Map<String, Map<String, dynamic>> _deepARFilters = {
    DeepARFilters.none: {'name': 'Normal', 'icon': Icons.face, 'emoji': '😊'},
    DeepARFilters.vendetta: {'name': 'Vendetta', 'icon': Icons.face, 'emoji': '🎭'},
    DeepARFilters.baseBeauty: {'name': 'Base Beauty', 'icon': Icons.face, 'emoji': '✨'},
    DeepARFilters.eightBitHearts: {'name': '8-Bit Hearts', 'icon': Icons.favorite, 'emoji': '💕'},
    DeepARFilters.elephantTrunk: {'name': 'Elephant Trunk', 'icon': Icons.face, 'emoji': '🐘'},
    DeepARFilters.emotionMeter: {'name': 'Emotion Meter', 'icon': Icons.mood, 'emoji': '📊'},
    DeepARFilters.emotionsExaggerator: {'name': 'Emotions Exaggerator', 'icon': Icons.mood, 'emoji': '😱'},
    DeepARFilters.fireEffect: {'name': 'Fire Effect', 'icon': Icons.whatshot, 'emoji': '🔥'},
    DeepARFilters.hope: {'name': 'Hope', 'icon': Icons.star, 'emoji': '⭐'},
    DeepARFilters.humanoid: {'name': 'Humanoid', 'icon': Icons.android, 'emoji': '🤖'},
    DeepARFilters.makeupLook: {'name': 'Makeup Look', 'icon': Icons.face, 'emoji': '💄'},
    DeepARFilters.neonDevilHorns: {'name': 'Neon Devil Horns', 'icon': Icons.ac_unit, 'emoji': '😈'},
    DeepARFilters.pingPong: {'name': 'Ping Pong', 'icon': Icons.sports_tennis, 'emoji': '🏓'},
    DeepARFilters.snail: {'name': 'Snail', 'icon': Icons.pets, 'emoji': '🐌'},
    DeepARFilters.splitViewLook: {'name': 'Split View Look', 'icon': Icons.flip, 'emoji': '🔀'},
    DeepARFilters.stallone: {'name': 'Stallone', 'icon': Icons.face, 'emoji': '🥊'},
    DeepARFilters.vendettaMask: {'name': 'Vendetta Mask', 'icon': Icons.face, 'emoji': '🎭'},
    DeepARFilters.burningEffect: {'name': 'Burning Effect', 'icon': Icons.whatshot, 'emoji': '🔥'},
    DeepARFilters.flowerFace: {'name': 'Flower Face', 'icon': Icons.local_florist, 'emoji': '🌸'},
    DeepARFilters.galaxyBackground: {'name': 'Galaxy Background', 'icon': Icons.stars, 'emoji': '🌌'},
    DeepARFilters.vikingHelmet: {'name': 'Viking Helmet', 'icon': Icons.shield, 'emoji': '⚔️'},
    DeepARFilters.barbieAd: {'name': 'Barbie', 'icon': Icons.face, 'emoji': '💖'},
    DeepARFilters.faceSwap: {'name': 'Face Swap', 'icon': Icons.swap_horiz, 'emoji': '🔄'},
    DeepARFilters.harryPotter: {'name': 'Harry Potter', 'icon': Icons.auto_fix_high, 'emoji': '⚡'},
  };

  @override
  void initState() {
    super.initState();
    print('🔵 StoryCameraScreen: initState llamado');
    WidgetsBinding.instance.addObserver(this);

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      print('📱 Inicializando cámara para historias...');

      // Intentar obtener las cámaras directamente
      // availableCameras() internamente solicita permisos en iOS
      print('📷 Obteniendo cámaras disponibles (esto solicitará permisos si es necesario)...');
      try {
        _cameras = await availableCameras();
        print('✅ Cámaras disponibles: ${_cameras!.length}');

        setState(() {
          _hasCameraPermissions = true;
          _hasInitializationFailed = false;
        });

        print('🎭 Modo DeepAR por defecto - cámara lista');
        return;
      } catch (e) {
        print('❌ Error obteniendo cámaras: $e');
        // Si falla, verificar el estado del permiso
      }

      // Si availableCameras() falló, verificar permisos manualmente
      print('🔍 Verificando estado de permisos de cámara...');
      final cameraStatus = await Permission.camera.status;
      print('📋 Estado de permiso: $cameraStatus');

      if (cameraStatus.isPermanentlyDenied) {
        print('⚠️ Permiso permanentemente denegado');
        setState(() {
          _hasInitializationFailed = true;
          _hasCameraPermissions = false;
        });
        _showAppSettingsDialog();
        return;
      }

      // Si llegamos aquí, algo salió mal
      print('❌ No se pudo acceder a la cámara');
      setState(() {
        _hasInitializationFailed = true;
        _hasCameraPermissions = false;
      });

      if (mounted) {
        Navigator.pop(context);
      }

      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception('No se encontraron cámaras en el dispositivo');
      }

      // Si llegamos aquí, tenemos acceso a las cámaras
      print('✅ Cámaras disponibles: ${_cameras!.length}');

      setState(() {
        _hasCameraPermissions = true;
        _hasInitializationFailed = false;
      });

      print('🎭 Modo DeepAR por defecto - cámara lista');
    } catch (e) {
      print('❌ Error fatal inicializando cámara: $e');

      setState(() {
        _hasInitializationFailed = true;
        _hasCameraPermissions = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al inicializar cámara: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );

        // Cerrar la pantalla después de mostrar el error
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) {
            Navigator.pop(context);
          }
        });
      }
    }
  }

  Future<void> _initializeCameraController() async {
    if (_cameras == null || _cameras!.isEmpty) return;

    _controller = CameraController(
      _cameras![_selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
    );

    await _controller!.initialize();

    if (mounted) {
      setState(() {
        _isCameraInitialized = true;
      });
    }
  }

  void _showAppSettingsDialog() {
    PermissionDialog.showPermissionDeniedDialog(
      context: context,
      title: 'Permiso de Cámara Requerido',
      message:
          'Para crear historias necesitas habilitar el acceso a la cámara en la configuración de la aplicación.',
    ).then((openSettings) {
      if (!openSettings) {
        Navigator.pop(context);
      }
    });
  }

  Future<void> _closeScreen() async {
    // IMPORTANTE: Limpiar COMPLETAMENTE DeepAR para evitar estado inconsistente
    print('🗑️ Cerrando pantalla - limpiando DeepAR completamente...');

    // CRÍTICO: Usar dispose() en lugar de stopCamera() para limpiar el singleton
    await _deepARService.dispose();
    _isDeepARInitialized = false;

    print('✅ DeepAR limpiado completamente (singleton reseteado)');

    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras == null || _cameras!.length < 2) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Si estamos en modo DeepAR, usar su método de cambio de cámara
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        print('🔄 Cambiando cámara con DeepAR...');
        final success = await _deepARService.switchCamera();
        if (success) {
          print('✅ Cámara cambiada exitosamente');
        } else {
          print('❌ Error cambiando cámara con DeepAR');
        }
        return;
      }

      // Modo Flutter camera (color)
      // Dispose del controlador anterior según mejores prácticas
      final previousController = _controller;

      // Limpiar referencia inmediatamente
      setState(() {
        _controller = null;
        _isCameraInitialized = false;
      });

      // Dispose del controlador anterior
      await previousController?.dispose();

      // Cambiar índice de cámara
      _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras!.length;

      // Inicializar nuevo controlador
      await _initializeCameraController();
    } catch (e) {
      print('❌ Error switching camera: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _applyDeepARFilter(String filterKey) async {
    if (!_isDeepARInitialized) {
      print('⚠️ DeepAR no está inicializado, no se puede aplicar filtro');
      return;
    }

    try {
      print('🎭 Aplicando filtro DeepAR: $filterKey');

      final success = await _deepARService.switchFilter(filterKey);

      if (success) {
        print(
          '✅ Filtro DeepAR aplicado: ${DeepARFilters.getDisplayName(filterKey)}',
        );
      } else {
        print('❌ Error aplicando filtro DeepAR');
      }
    } catch (e) {
      print('❌ Excepción aplicando filtro DeepAR: $e');
    }
  }

  Future<void> _takePicture() async {
    if (_isLoading) {
      print('⚠️ Ya hay una captura en proceso, ignorando...');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      String finalImagePath;

      // Si estamos en modo DeepAR, usar screenshot de DeepAR
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        print('📸 Tomando foto con DeepAR...');

        final Uint8List? screenshot = await _deepARService.takeScreenshot();

        if (screenshot == null || screenshot.isEmpty) {
          throw Exception('No se pudo capturar la foto con DeepAR - screenshot vacío');
        }

        print('✅ Screenshot capturado: ${screenshot.length} bytes');

        // Guardar screenshot a archivo
        final directory = await getTemporaryDirectory();
        final imagePath =
            '${directory.path}/deepar_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final imageFile = File(imagePath);

        await imageFile.writeAsBytes(screenshot);

        // Verificar que el archivo se guardó correctamente
        if (!await imageFile.exists()) {
          throw Exception('No se pudo guardar la foto en el sistema de archivos');
        }

        final fileSize = await imageFile.length();
        print('✅ Foto DeepAR guardada en: $imagePath (${fileSize} bytes)');

        finalImagePath = imagePath;
      } else {
        // Modo Flutter camera normal
        if (_controller == null || !_controller!.value.isInitialized) {
          throw Exception('Cámara no inicializada');
        }

        print('📸 Tomando foto con Flutter Camera...');
        final XFile picture = await _controller!.takePicture();
        finalImagePath = picture.path;

        print('✅ Foto Flutter guardada en: $finalImagePath');

        // Aplicar filtro si está seleccionado
        if (_selectedFilter != null && _selectedFilter != 'none') {
          print('🎨 Aplicando filtro: $_selectedFilter');
          finalImagePath = await _applyFilter(picture.path, _selectedFilter!);
        }
      }

      // Verificar que el archivo final existe antes de navegar
      final finalFile = File(finalImagePath);
      if (!await finalFile.exists()) {
        throw Exception('El archivo de imagen no existe: $finalImagePath');
      }

      print('✅ Navegando a StoryPreviewScreen con: $finalImagePath');

      // Navegar a pantalla de preview
      if (mounted) {
        // Esperar un frame antes de navegar para asegurar que el estado se actualizó
        await Future.delayed(Duration(milliseconds: 100));

        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => StoryPreviewScreen(
                imagePath: finalImagePath,
                filter: _selectedFilter,
                arFilter: _selectedARFilter,
              ),
            ),
          );

          print('✅ Regresó de StoryPreviewScreen');
        }
      }
    } catch (e, stackTrace) {
      print('❌ Error tomando foto: $e');
      print('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al tomar foto. Por favor intenta de nuevo.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<String> _applyFilter(String imagePath, String filterType) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      img.Image? image = img.decodeImage(bytes);

      if (image == null) return imagePath;

      // Aplicar filtros básicos
      switch (filterType) {
        case 'vintage':
          image = img.sepia(image);
          image = img.adjustColor(image, saturation: 0.8, brightness: 1.1);
          break;
        case 'cool':
          image = img.adjustColor(image, contrast: 1.2, brightness: 1.05);
          // Aumentar azules
          break;
        case 'warm':
          image = img.adjustColor(image, saturation: 1.2, brightness: 1.1);
          // Aumentar rojos/amarillos
          break;
        case 'black_white':
          image = img.grayscale(image);
          break;
        case 'sepia':
          image = img.sepia(image);
          break;
      }

      // Guardar imagen filtrada
      final directory = await getTemporaryDirectory();
      final filteredPath =
          '${directory.path}/filtered_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filteredFile = File(filteredPath);
      await filteredFile.writeAsBytes(img.encodeJpg(image));

      return filteredPath;
    } catch (e) {
      print('Error aplicando filtro: $e');
      return imagePath;
    }
  }

  Widget _buildARFilterList() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: _deepARFilters.length,
      padding: EdgeInsets.symmetric(horizontal: 20),
      itemBuilder: (context, index) {
        final filterKey = _deepARFilters.keys.elementAt(index);
        final filterData = _deepARFilters[filterKey]!;
        final isSelected = _selectedARFilter == filterKey;

        return GestureDetector(
          onTap: () {
            // Evitar loops infinitos - solo cambiar si es diferente
            if (_selectedARFilter != filterKey) {
              setState(() {
                _selectedARFilter = filterKey;
              });

              // Si estamos en modo DeepAR, aplicar el filtro (una sola vez)
              if (_filterType == 'deepar' && _isDeepARInitialized) {
                _applyDeepARFilter(filterKey);
              }
            }
          },
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
                Container(
                  width: 45,
                  height: 45,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.2),
                  ),
                  child: Center(
                    child: Text(
                      filterData['emoji'],
                      style: TextStyle(fontSize: 24),
                    ),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  filterData['name'],
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAROverlay(String filterType) {
    switch (filterType) {
      case 'cat_ears':
        return _buildCatEarsOverlay();
      case 'sunglasses':
        return _buildSunglassesOverlay();
      case 'mustache':
        return _buildMustacheOverlay();
      case 'crown':
        return _buildCrownOverlay();
      case 'hearts':
        return _buildHeartsOverlay();
      case 'stars':
        return _buildStarsOverlay();
      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildCatEarsOverlay() {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.15,
      left: MediaQuery.of(context).size.width * 0.25,
      right: MediaQuery.of(context).size.width * 0.25,
      child: Container(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('🐱', style: TextStyle(fontSize: 30)),
            Text('🐱', style: TextStyle(fontSize: 30)),
          ],
        ),
      ),
    );
  }

  Widget _buildSunglassesOverlay() {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.25,
      left: MediaQuery.of(context).size.width * 0.3,
      right: MediaQuery.of(context).size.width * 0.3,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(child: Text('😎', style: TextStyle(fontSize: 35))),
      ),
    );
  }

  Widget _buildMustacheOverlay() {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.35,
      left: MediaQuery.of(context).size.width * 0.35,
      right: MediaQuery.of(context).size.width * 0.35,
      child: Container(
        height: 30,
        child: Center(child: Text('🥸', style: TextStyle(fontSize: 40))),
      ),
    );
  }

  Widget _buildCrownOverlay() {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.1,
      left: MediaQuery.of(context).size.width * 0.3,
      right: MediaQuery.of(context).size.width * 0.3,
      child: Container(
        height: 50,
        child: Center(child: Text('👑', style: TextStyle(fontSize: 45))),
      ),
    );
  }

  Widget _buildHeartsOverlay() {
    return Stack(
      children: [
        Positioned(
          top: MediaQuery.of(context).size.height * 0.2,
          left: MediaQuery.of(context).size.width * 0.1,
          child: Text('❤️', style: TextStyle(fontSize: 25)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.3,
          right: MediaQuery.of(context).size.width * 0.1,
          child: Text('💕', style: TextStyle(fontSize: 30)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.4,
          left: MediaQuery.of(context).size.width * 0.15,
          child: Text('💖', style: TextStyle(fontSize: 20)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.25,
          left: MediaQuery.of(context).size.width * 0.7,
          child: Text('💝', style: TextStyle(fontSize: 22)),
        ),
      ],
    );
  }

  Widget _buildStarsOverlay() {
    return Stack(
      children: [
        Positioned(
          top: MediaQuery.of(context).size.height * 0.15,
          left: MediaQuery.of(context).size.width * 0.1,
          child: Text('⭐', style: TextStyle(fontSize: 25)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.25,
          right: MediaQuery.of(context).size.width * 0.15,
          child: Text('✨', style: TextStyle(fontSize: 20)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.35,
          left: MediaQuery.of(context).size.width * 0.2,
          child: Text('🌟', style: TextStyle(fontSize: 30)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.3,
          right: MediaQuery.of(context).size.width * 0.3,
          child: Text('💫', style: TextStyle(fontSize: 25)),
        ),
        Positioned(
          top: MediaQuery.of(context).size.height * 0.4,
          right: MediaQuery.of(context).size.width * 0.1,
          child: Text('⭐', style: TextStyle(fontSize: 22)),
        ),
      ],
    );
  }

  @override
  void dispose() {
    print('🗑️ StoryCameraScreen disposing...');
    WidgetsBinding.instance.removeObserver(this);

    // Dispose controller de forma segura
    final controller = _controller;
    if (controller != null) {
      controller.dispose().catchError((error) {
        print('⚠️ Error disposing camera controller: $error');
      });
    }

    // CRÍTICO: Detener y limpiar DeepAR completamente cuando se cierra la pantalla
    // Nota: dispose() no puede ser async, pero intentamos detener la cámara de todas formas
    print('🗑️ [dispose] Deteniendo y limpiando DeepAR...');
    _deepARService.stopCamera().then((_) {
      print('✅ [dispose] Cámara DeepAR detenida');
    }).catchError((error) {
      print('❌ [dispose] Error deteniendo cámara: $error');
    });

    // También limpiar el estado de inicialización para la próxima vez
    _isDeepARInitialized = false;

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    // Solo hacer dispose cuando la app va al background (paused), no en inactive
    // Esto evita problemas de titilación durante navegación normal
    if (state == AppLifecycleState.paused) {
      print('📱 App paused - disposing camera controller');
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      print('📱 App resumed - reinitializing camera');
      if (_hasInitializationFailed && !_isCameraInitialized) {
        print('📱 Reintentando inicialización de cámara...');
        _hasInitializationFailed = false;
        _initializeCamera();
      } else if (_filterType == 'color' && _controller == null) {
        // Reinicializar controlador si estamos en modo color pero no hay controlador
        _initializeCameraController();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop) {
          await _closeScreen();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
        child: Stack(
          children: [
            // Vista simple basada en estado - patrón del repositorio de referencia
            _buildCameraPreview(),

            // Overlay AR
            if (_isCameraInitialized &&
                _selectedARFilter != null &&
                _selectedARFilter != 'none')
              Positioned.fill(child: _buildAROverlay(_selectedARFilter!)),

            // Overlay con controles
            Positioned.fill(
              child: Column(
                children: [
                  // Header con botón cerrar
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: _closeScreen,
                          icon: Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        Spacer(),
                        Text(
                          'Crear Historia',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Spacer(),
                        SizedBox(width: 44), // Balancear el layout
                      ],
                    ),
                  ),

                  Spacer(),

                  // Solo DeepAR disponible
                  SizedBox(height: 10),

                  // Filtros
                  Container(
                    height: 90,
                    margin: EdgeInsets.only(bottom: 20),
                    child: _buildARFilterList(),
                  ),

                  // Controles inferiores
                  Padding(
                    padding: EdgeInsets.all(20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Cambiar cámara
                        IconButton(
                          onPressed: _cameras != null && _cameras!.length > 1
                              ? _switchCamera
                              : null,
                          icon: Icon(
                            Icons.flip_camera_ios,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),

                        // Botón de captura
                        GestureDetector(
                          onTap: _isLoading ? null : _takePicture,
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                            child: _isLoading
                                ? Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.black,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    Icons.camera_alt,
                                    color: Colors.black,
                                    size: 32,
                                  ),
                          ),
                        ),

                        // Placeholder para balance
                        SizedBox(width: 48),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// Construir vista de cámara basada en estado
  Widget _buildCameraPreview() {
    // CRÍTICO: Solo construir DeepARCameraView cuando tengamos permisos
    if (!_hasCameraPermissions) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // Forzar recreación completa con GlobalKey única
    return Container(
      key: GlobalKey(
        debugLabel: 'camera_container_stable_${_filterType}',
      ),
      child: _filterType == 'color'
          ? _buildFlutterCameraView()
          : _buildDeepARCameraView(),
    );
  }

  Widget _buildFlutterCameraView() {
    return FlutterCameraView(
      key: GlobalKey(debugLabel: 'flutter_camera_stable'),
      cameras: _cameras,
      selectedCameraIndex: _selectedCameraIndex,
      onCameraInitialized: (controller) {
        setState(() {
          _controller = controller;
          _isCameraInitialized = controller != null;
        });
      },
      onCameraDisposed: () {
        setState(() {
          _controller = null;
          _isCameraInitialized = false;
        });
      },
    );
  }

  // GlobalKey para mantener el widget DeepARCameraView vivo entre rebuilds
  final GlobalKey _deepARCameraKey = GlobalKey(debugLabel: 'deepar_camera_view');

  Widget _buildDeepARCameraView() {
    return DeepARCameraView(
      key: _deepARCameraKey,
      isDeepARInitialized: _isDeepARInitialized,
      deepARService: _deepARService,
      onInitialized: () {
        setState(() {
          _isDeepARInitialized = true;
        });
      },
    );
  }
}

// StoryPreviewScreen ahora está en story/story_preview_screen.dart

// FlutterCameraView ahora está en widgets/camera/flutter_camera_view.dart

// DeepARCameraView ahora está en widgets/camera/deepar_camera_view.dart
