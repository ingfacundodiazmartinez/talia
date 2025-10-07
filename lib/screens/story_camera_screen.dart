import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/story_service.dart';
import '../services/deepar_service.dart';
import '../widgets/permission_dialog.dart';

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
  bool _isDisposingCamera = false;
  bool _isLoading = false;
  int _selectedCameraIndex = 0;
  String? _selectedFilter;
  String? _selectedARFilter = DeepARFilters.baseBeauty; // Iniciar con el nuevo filtro
  String _filterType = 'deepar'; // Solo DeepAR por defecto
  bool _hasInitializationFailed = false;
  bool _isDeepARInitialized = false;
  bool _hasCameraPermissions = false; // CRÍTICO: Flag para saber si tenemos permisos

  final StoryService _storyService = StoryService();
  final DeepARService _deepARService = DeepARService();

  // Filtros de color disponibles
  final Map<String, String> _colorFilters = {
    'none': 'Normal',
    'vintage': 'Vintage',
    'cool': 'Frío',
    'warm': 'Cálido',
    'black_white': 'B&N',
    'sepia': 'Sepia',
  };

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
  };

  @override
  void initState() {
    super.initState();
    print('🔵 StoryCameraScreen: initState llamado');
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();

    // Detectar cuando la pantalla se vuelve visible después de haber sido ocultada
    WidgetsBinding.instance.addPostFrameCallback((_) {
      print('🔵 StoryCameraScreen: postFrameCallback en initState');
      _listenToRouteChanges();
    });
  }

  void _listenToRouteChanges() {
    print('🔵 StoryCameraScreen: _listenToRouteChanges llamado');
    // Cuando esta ruta se vuelve activa (después de haber estado oculta)
    final route = ModalRoute.of(context);
    if (route != null) {
      print('🔵 StoryCameraScreen: Route encontrado, agregando listener');
      route.animation?.addStatusListener((status) {
        print('🔵 StoryCameraScreen: AnimationStatus cambió a $status, _isDeepARInitialized=$_isDeepARInitialized');
        if (status == AnimationStatus.completed && _isDeepARInitialized) {
          // La ruta está completamente visible
          print('🔵 StoryCameraScreen: Ruta completada, iniciando cámara...');
          Future.delayed(Duration(milliseconds: 300), () async {
            print('🟢 StoryCameraScreen: Llamando a startCamera()');
            await _deepARService.startCamera();
            print('✅ Cámara DeepAR reiniciada al volver a la pantalla');
          });
        }
      });
    } else {
      print('🔴 StoryCameraScreen: Route es NULL');
    }
  }

  Future<void> _initializeCamera() async {
    try {
      print('📱 Inicializando cámara para historias...');

      // NUEVO ENFOQUE: Intentar obtener cámaras directamente
      // En iOS, availableCameras() maneja permisos automáticamente
      try {
        _cameras = await availableCameras();

        if (_cameras!.isEmpty) {
          throw Exception('No se encontraron cámaras');
        }

        // Si llegamos aquí, tenemos acceso a las cámaras
        print('✅ Cámaras disponibles: ${_cameras!.length}');

        setState(() {
          _hasCameraPermissions = true;
        });

        print('🎭 Modo DeepAR por defecto - cámara lista');
        return;
      } catch (cameraError) {
        print('❌ Error obteniendo cámaras: $cameraError');

        // Si falla, verificar permisos explícitamente
        print('🔍 Verificando permisos de cámara explícitamente...');
        var cameraStatus = await Permission.camera.status;
        print('📋 Estado actual de permiso: $cameraStatus');

        // Si el permiso no está concedido, solicitarlo
        if (!cameraStatus.isGranted) {
          print('📱 Solicitando permiso de cámara...');
          cameraStatus = await Permission.camera.request();
          print('📋 Resultado de solicitud: $cameraStatus');

          if (!cameraStatus.isGranted) {
            print('❌ Permiso de cámara denegado');
            setState(() {
              _hasInitializationFailed = true;
            });
            _showPermissionDialog();
            return;
          }
        }

        // Permiso concedido, reintentar obtener cámaras
        print('🔄 Permiso concedido, reintentando obtener cámaras...');
        _cameras = await availableCameras();

        if (_cameras!.isEmpty) {
          throw Exception('No se encontraron cámaras');
        }

        setState(() {
          _hasCameraPermissions = true;
        });

        print('✅ Cámaras disponibles después de solicitar permisos: ${_cameras!.length}');
      }
    } catch (e) {
      print('❌ Error fatal inicializando cámara: $e');

      // Si el error es de permisos, mostrar diálogo apropiado
      if (e.toString().toLowerCase().contains('permission') ||
          e.toString().toLowerCase().contains('camera') ||
          e.toString().toLowerCase().contains('access')) {
        setState(() {
          _hasInitializationFailed = true;
        });
        _showPermissionDialog();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al inicializar cámara: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
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

  void _showPermissionDialog() async {
    try {
      // Solicitar permiso directamente del sistema
      print('📱 Solicitando permiso de cámara del sistema...');
      final permissionStatus = await Permission.camera.request();
      print('📱 Resultado del permiso: $permissionStatus');

      if (permissionStatus == PermissionStatus.granted) {
        // Permiso concedido, reintentar inicialización
        print('✅ Permiso concedido, reintentando inicialización...');
        setState(() {
          _hasInitializationFailed = false;
        });
        _initializeCamera();
      } else if (permissionStatus == PermissionStatus.permanentlyDenied) {
        // Permiso permanentemente denegado, mostrar diálogo para ir a configuración
        _showAppSettingsDialog();
      } else {
        // Permiso denegado temporalmente, cerrar pantalla
        print('❌ Permiso denegado, cerrando pantalla');
        Navigator.pop(context);
      }
    } catch (e) {
      print('❌ Error solicitando permiso: $e');
      Navigator.pop(context);
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

  Future<void> _takePicture() async {
    setState(() {
      _isLoading = true;
    });

    try {
      String finalImagePath;

      // Si estamos en modo DeepAR, usar screenshot de DeepAR
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        print('📸 Tomando foto con DeepAR...');
        final Uint8List? screenshot = await _deepARService.takeScreenshot();

        if (screenshot == null) {
          throw Exception('No se pudo capturar la foto con DeepAR');
        }

        // Guardar screenshot a archivo
        final directory = await getTemporaryDirectory();
        final imagePath =
            '${directory.path}/deepar_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final imageFile = File(imagePath);
        await imageFile.writeAsBytes(screenshot);
        finalImagePath = imagePath;
        print('✅ Foto DeepAR guardada en: $imagePath');
      } else {
        // Modo Flutter camera normal
        if (_controller == null || !_controller!.value.isInitialized) {
          throw Exception('Cámara no inicializada');
        }

        final XFile picture = await _controller!.takePicture();
        finalImagePath = picture.path;

        // Aplicar filtro si está seleccionado
        if (_selectedFilter != null && _selectedFilter != 'none') {
          finalImagePath = await _applyFilter(picture.path, _selectedFilter!);
        }
      }

      // Navegar a pantalla de preview
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => StoryPreviewScreen(
              imagePath: finalImagePath,
              filter: _selectedFilter,
              arFilter: _selectedARFilter,
            ),
          ),
        );
      }
    } catch (e) {
      print('❌ Error tomando foto: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al tomar foto: $e'),
            backgroundColor: Colors.red,
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

  Widget _buildFilterTab(String type, String label, IconData icon) {
    final isSelected = _filterType == type;
    return GestureDetector(
      onTap: () async {
        if (_filterType == type)
          return; // No hacer nada si ya está seleccionado
        // Transición simplificada - no hay múltiples vistas
        if (false)
          return; // Evitar múltiples transiciones simultáneas

        final oldFilterType = _filterType;
        print('🔄 Cambiando de $oldFilterType a $type');

        try {
          // Implementar transición completa con widgets separados
          await _performCompleteTransition(oldFilterType, type);
        } catch (e) {
          print('❌ Error durante transición: $e');
        } finally {
          if (mounted) {
            setState(() {
              // Transición completada
            });
          }
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Color(0xFF9D7FE8) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Color(0xFF9D7FE8)
                : Colors.white.withOpacity(0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorFilterList() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: _colorFilters.length,
      padding: EdgeInsets.symmetric(horizontal: 20),
      itemBuilder: (context, index) {
        final filterKey = _colorFilters.keys.elementAt(index);
        final filterName = _colorFilters[filterKey]!;
        final isSelected = _selectedFilter == filterKey;

        return GestureDetector(
          onTap: () {
            setState(() {
              _selectedFilter = filterKey;
            });
          },
          child: Container(
            width: 60,
            margin: EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isSelected ? Color(0xFF9D7FE8) : Colors.white,
                width: isSelected ? 3 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _getFilterPreviewColor(filterKey),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  filterName,
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

    // Limpiar CameraController de DeepAR cuando se cierra la pantalla
    _deepARService.stopCamera();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      print('📱 App inactive - disposing camera controller');
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
    return Scaffold(
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
                          onPressed: () => Navigator.pop(context),
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
    );
  }

  Color _getFilterPreviewColor(String filterKey) {
    switch (filterKey) {
      case 'none':
        return Colors.white;
      case 'vintage':
        return Colors.amber[200]!;
      case 'cool':
        return Colors.blue[200]!;
      case 'warm':
        return Colors.orange[200]!;
      case 'black_white':
        return Colors.grey[400]!;
      case 'sepia':
        return Colors.brown[200]!;
      default:
        return Colors.white;
    }
  }

  // Métodos de DeepAR
  Future<void> _initializeDeepAR() async {
    try {
      print('🎭 Inicializando DeepAR...');

      // License keys específicas por plataforma
      const iosLicenseKey =
          '3f847703516a015f55ba3a57a9e52b597b082696c37e1975e11f99cacd99b01ba01b7f900d1e1051';
      const androidLicenseKey =
          'e54c25aaa8b14776f4837d0c406f91bebb6f9652716847c37004a458645242ccce15c78ea3f1084b';

      // Detectar plataforma y usar la key correcta
      String licenseKey;
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        licenseKey = iosLicenseKey;
        print('📱 Usando license key de iOS');
      } else if (Theme.of(context).platform == TargetPlatform.android) {
        licenseKey = androidLicenseKey;
        print('🤖 Usando license key de Android');
      } else {
        throw Exception('Plataforma no soportada para DeepAR');
      }

      final result = await _deepARService.initialize(licenseKey: licenseKey);

      if (result) {
        setState(() {
          _isDeepARInitialized = true;
        });
        print('✅ DeepAR inicializado exitosamente');
      } else {
        print('❌ Error inicializando DeepAR');
        // Fallback: continuar sin DeepAR
        _showDeepARError(
          'No se pudo inicializar DeepAR. Los filtros AR no estarán disponibles.',
        );
      }
    } catch (e) {
      print('❌ Excepción inicializando DeepAR: $e');
      // Fallback: continuar sin DeepAR
      _showDeepARError('Error técnico con DeepAR. Usando filtros básicos.');
    }
  }

  Future<void> _applyDeepARFilter(String filterKey) async {
    if (!_isDeepARInitialized) {
      print('⚠️ DeepAR no está inicializado, inicializando...');
      await _initializeDeepAR();
      if (!_isDeepARInitialized) {
        return;
      }
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

  void _showDeepARError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// Realizar transición completa entre modos de filtro
  Future<void> _performCompleteTransition(
    String oldType,
    String newType,
  ) async {
    print('🔄 Iniciando transición completa: $oldType -> $newType');

    // Paso 1: Marcar como en transición
    setState(() {
      // Iniciando transición
    });

    // Paso 2: Esperar que UI muestre estado de transición
    await Future.delayed(Duration(milliseconds: 300));

    // Paso 3: Cambiar el tipo de filtro y limpiar estado
    setState(() {
      _filterType = newType;
      // Widget key estable - no incrementar counter

      // Limpiar selecciones según el nuevo tipo
      if (newType == 'color') {
        _selectedARFilter = null;
      } else {
        _selectedFilter = null;
      }

      // Limpiar estado de cámara Flutter
      _controller = null;
      _isCameraInitialized = false;
    });

    // Paso 4: Esperar que los nuevos widgets se creen
    await Future.delayed(Duration(milliseconds: 500));

    // Paso 5: Finalizar transición
    if (mounted) {
      setState(() {
        // Transición completada
      });
    }

    print('✅ Transición completa finalizada: $oldType -> $newType');
  }

  /// Construir vista de cámara basada en estado
  Widget _buildCameraPreview() {
    // Durante transición, mostrar loading
    // Verificación de transición simplificada
    if (false) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Cambiando modo...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

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
  final GlobalKey<_DeepARCameraViewState> _deepARCameraKey = GlobalKey();

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

// Pantalla de preview de la historia
class StoryPreviewScreen extends StatefulWidget {
  final String imagePath;
  final String? filter;
  final String? arFilter;

  const StoryPreviewScreen({
    super.key,
    required this.imagePath,
    this.filter,
    this.arFilter,
  });

  @override
  State<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends State<StoryPreviewScreen> {
  final TextEditingController _captionController = TextEditingController();
  final StoryService _storyService = StoryService();
  bool _isUploading = false;

  Future<void> _shareStory() async {
    setState(() {
      _isUploading = true;
    });

    try {
      final storyId = await _storyService.createStory(
        mediaPath: widget.imagePath,
        mediaType: 'image',
        caption: _captionController.text.trim().isEmpty
            ? null
            : _captionController.text.trim(),
        filter: widget.filter != null || widget.arFilter != null
            ? {'type': widget.filter, 'arFilter': widget.arFilter}
            : null,
      );

      // Verificar el status de la historia creada
      final storyDoc = await FirebaseFirestore.instance
          .collection('stories')
          .doc(storyId)
          .get();
      final storyStatus = storyDoc.data()?['status'] ?? 'approved';

      Navigator.pop(context); // Cerrar preview
      Navigator.pop(context); // Cerrar cámara

      // Mostrar mensaje apropiado según el status
      if (storyStatus == 'pending') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.access_time, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '📸 Historia creada! Esperando aprobación del padre',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.orange[700],
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '📸 Historia publicada exitosamente!',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.green[700],
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al compartir historia: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Spacer(),
                  Text(
                    'Tu Historia',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Spacer(),
                  SizedBox(width: 48),
                ],
              ),
            ),

            // Imagen preview
            Expanded(
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.cover,
                    width: double.infinity,
                  ),
                ),
              ),
            ),

            // Campo de caption
            Container(
              margin: EdgeInsets.all(20),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(25),
              ),
              child: TextField(
                controller: _captionController,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Agregar una descripción...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                  border: InputBorder.none,
                ),
                maxLines: null,
                maxLength: 200,
              ),
            ),

            // Botón compartir
            Container(
              width: double.infinity,
              margin: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: ElevatedButton(
                onPressed: _isUploading ? null : _shareStory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF9D7FE8),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                child: _isUploading
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('Compartiendo...'),
                        ],
                      )
                    : Text(
                        'Compartir Historia',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget separado para manejar cámara Flutter de forma completamente aislada
class FlutterCameraView extends StatefulWidget {
  final List<CameraDescription>? cameras;
  final int selectedCameraIndex;
  final Function(CameraController?) onCameraInitialized;
  final VoidCallback onCameraDisposed;

  const FlutterCameraView({
    Key? key,
    required this.cameras,
    required this.selectedCameraIndex,
    required this.onCameraInitialized,
    required this.onCameraDisposed,
  }) : super(key: key);

  @override
  State<FlutterCameraView> createState() => _FlutterCameraViewState();
}

class _FlutterCameraViewState extends State<FlutterCameraView> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isInitializing = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void didUpdateWidget(FlutterCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Solo reinicializar si las cámaras o el índice cambiaron
    if (oldWidget.cameras != widget.cameras ||
        oldWidget.selectedCameraIndex != widget.selectedCameraIndex) {
      _reinitializeCamera();
    }
  }

  Future<void> _reinitializeCamera() async {
    if (_isInitializing || _isDisposed) return;

    await _disposeController();
    await _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras == null || widget.cameras!.isEmpty) return;
    if (_isDisposed || _isInitializing) return;

    setState(() {
      _isInitializing = true;
    });

    try {
      print('📱 FlutterCameraView: Inicializando cámara...');

      _controller = CameraController(
        widget.cameras![widget.selectedCameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();

      if (mounted && !_isDisposed) {
        setState(() {
          _isInitialized = true;
          _isInitializing = false;
        });
        widget.onCameraInitialized(_controller);
        print('✅ FlutterCameraView: Cámara inicializada correctamente');
      }
    } catch (e) {
      print('❌ FlutterCameraView: Error inicializando cámara: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
        widget.onCameraInitialized(null);
      }
    }
  }

  Future<void> _disposeController() async {
    if (_controller != null) {
      print('🗑️ FlutterCameraView: Disposing controller...');

      // Solo hacer setState si el widget sigue montado
      if (mounted && !_isDisposed) {
        setState(() {
          _isInitialized = false;
        });
      }

      try {
        await _controller!.dispose();
        print('✅ FlutterCameraView: Controller disposed exitosamente');
      } catch (e) {
        print('⚠️ FlutterCameraView: Error disposing controller: $e');
      }

      _controller = null;
    }
  }

  @override
  void dispose() {
    print('🗑️ FlutterCameraView: Disposing...');
    _isDisposed = true;

    _disposeController().then((_) {
      widget.onCameraDisposed();
    });

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isDisposed) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Text('Cámara disposed', style: TextStyle(color: Colors.white)),
        ),
      );
    }

    if (_isInitializing || (!_isInitialized || _controller == null)) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                _isInitializing
                    ? 'Inicializando cámara...'
                    : 'Preparando cámara...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    try {
      // Verificaciones múltiples antes de buildPreview
      if (_controller == null || _isDisposed) {
        throw Exception('Controller null o disposed');
      }

      // Verificar que el controller esté inicializado
      if (!_controller!.value.isInitialized) {
        throw Exception('Controller no inicializado');
      }

      // Test de acceso al controller para detectar disposal
      final value = _controller!.value;
      if (value.hasError) {
        throw Exception('Controller tiene error: ${value.errorDescription}');
      }

      // Solo verificar el estado sin llamar buildPreview
      if (_controller!.description != value.description) {
        throw Exception('Controller description mismatch');
      }

      return Positioned.fill(
        child: AspectRatio(
          aspectRatio: value.aspectRatio,
          child: CameraPreview(_controller!),
        ),
      );
    } catch (e) {
      print('❌ FlutterCameraView: Error en preview: $e');
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, color: Colors.red, size: 48),
              SizedBox(height: 16),
              Text(
                'Error de cámara Flutter',
                style: TextStyle(color: Colors.red, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
  }
}

/// Widget separado para manejar DeepAR de forma completamente aislada
class DeepARCameraView extends StatefulWidget {
  final bool isDeepARInitialized;
  final DeepARService deepARService;
  final VoidCallback onInitialized;

  const DeepARCameraView({
    Key? key,
    required this.isDeepARInitialized,
    required this.deepARService,
    required this.onInitialized,
  }) : super(key: key);

  @override
  State<DeepARCameraView> createState() => _DeepARCameraViewState();
}

class _DeepARCameraViewState extends State<DeepARCameraView> {
  bool _isInitializing = false;
  bool _hasInitialized = false;

  // IMPORTANTE: NO usar key - dejar que Flutter/iOS maneje la vista
  // La vista nativa se mantiene viva y solo cambiamos sus parámetros

  @override
  void dispose() {
    print('🗑️ DeepARCameraView: dispose');
    // NO limpiar aquí porque el widget se recrea en cada setState del parent
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    print('🎯 DeepARCameraView: Preview creado con viewId: $viewId');
    // Swift ahora maneja automáticamente el inicio de la cámara
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // IMPORTANTE: Verificar si el servicio (singleton) ya está inicializado
    if (widget.deepARService.isInitialized) {
      print('✅ DeepARCameraView: DeepAR ya estaba inicializado (singleton), solo reiniciando cámara');
      // Si ya está inicializado, solo reiniciar la cámara después del build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.deepARService.startCamera();
        if (!_hasInitialized) {
          widget.onInitialized();
          _hasInitialized = true;
        }
      });
      return;
    }

    // Si no está inicializado, inicializar por primera vez
    if (!widget.isDeepARInitialized && !_isInitializing && !_hasInitialized) {
      _initializeDeepAR();
    }
  }

  @override
  void didUpdateWidget(DeepARCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // IMPORTANTE: Verificar si el servicio (singleton) ya está inicializado
    if (widget.deepARService.isInitialized) {
      print('✅ DeepARCameraView (update): DeepAR ya estaba inicializado (singleton), solo reiniciando cámara');
      // Si ya está inicializado, solo reiniciar la cámara después del build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.deepARService.startCamera();
        if (!_hasInitialized) {
          widget.onInitialized();
          _hasInitialized = true;
        }
      });
      return;
    }

    // Si no está inicializado, inicializar por primera vez
    if (!widget.isDeepARInitialized && !_isInitializing && !_hasInitialized) {
      _initializeDeepAR();
    }
  }

  Future<void> _initializeDeepAR() async {
    if (_isInitializing || _hasInitialized) return;

    // DOBLE CHECK: Verificar si el servicio ya está inicializado antes de inicializar
    if (widget.deepARService.isInitialized) {
      print('✅ DeepARCameraView (_initializeDeepAR): DeepAR ya estaba inicializado, abortando');
      widget.onInitialized();
      _hasInitialized = true;
      return;
    }

    setState(() {
      _isInitializing = true;
      _hasInitialized = true; // Marcar que ya se intentó inicializar
    });

    try {
      print('🎭 DeepARCameraView: Inicializando DeepAR...');

      // License keys específicas por plataforma - NECESITAS OBTENER KEYS VÁLIDAS DE https://developer.deepar.ai/
      // Estas keys son de demostración y pueden haber expirado
      const iosLicenseKey =
          'bc5821fe04221f7349429783cced44ddbe6006d0287c4397dc97fc5dd993a843429712eda6fe98c9';
      const androidLicenseKey =
          'e54c25aaa8b14776f4837d0c406f91bebb6f9652716847c37004a458645242ccce15c78ea3f1084b';

      // Keys de prueba temporal (pueden no funcionar)
      const iosLicenseKeyDemo =
          '3f847703516a015f55ba3a57a9e52b597b082696c37e1975e11f99cacd99b01ba01b7f900d1e1051';
      const androidLicenseKeyDemo =
          'e54c25aaa8b14776f4837d0c406f91bebb6f9652716847c37004a458645242ccce15c78ea3f1084b';

      // Detectar plataforma y usar la key correcta
      String licenseKey;
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        // Usar key válida si está disponible, sino usar la de demo
        licenseKey = iosLicenseKey.contains('YOUR_VALID')
            ? iosLicenseKeyDemo
            : iosLicenseKey;
        print('📱 Usando license key de iOS (puede ser demo)');
      } else if (Theme.of(context).platform == TargetPlatform.android) {
        // Usar key válida si está disponible, sino usar la de demo
        licenseKey = androidLicenseKey.contains('YOUR_VALID')
            ? androidLicenseKeyDemo
            : androidLicenseKey;
        print('🤖 Usando license key de Android (puede ser demo)');
      } else {
        throw Exception('Plataforma no soportada para DeepAR');
      }

      final result = await widget.deepARService.initialize(
        licenseKey: licenseKey,
      );

      if (result && mounted) {
        widget.onInitialized();
        print('✅ DeepARCameraView: DeepAR inicializado exitosamente');
      } else {
        print('❌ DeepARCameraView: Error inicializando DeepAR');
      }
    } catch (e) {
      print('❌ DeepARCameraView: Excepción inicializando DeepAR: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isDeepARInitialized) {
      return DeepARPreview(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }

    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              _isInitializing
                  ? 'Inicializando DeepAR...'
                  : 'Preparando DeepAR...',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
