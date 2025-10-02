import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import '../services/face_filter_service.dart';

class ARCameraScreen extends StatefulWidget {
  const ARCameraScreen({super.key});

  @override
  State<ARCameraScreen> createState() => _ARCameraScreenState();
}

class _ARCameraScreenState extends State<ARCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  late FaceFilterService _faceFilterService;
  FilterType _currentFilter = FilterType.none;
  Timer? _processingTimer;

  final List<FilterType> _availableFilters = [
    FilterType.none,
    FilterType.dogEars,
    FilterType.catWhiskers,
    FilterType.sunglasses,
    FilterType.crown,
    FilterType.mustache,
    FilterType.bunnyEars,
    FilterType.partyHat,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _faceFilterService = FaceFilterService();
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _processingTimer?.cancel();
    _cameraController?.dispose();
    _faceFilterService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        print('❌ No cameras available');
        return;
      }

      // Usar cámara frontal si está disponible
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _faceFilterService.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });

        // Iniciar procesamiento de faces en tiempo real
        _startFaceDetection();
      }
    } catch (e) {
      print('❌ Error initializing camera: $e');
    }
  }

  void _startFaceDetection() {
    _processingTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_isProcessing) {
        _processCurrentFrame();
      }
    });
  }

  Future<void> _processCurrentFrame() async {
    if (_isProcessing) return;

    try {
      _isProcessing = true;

      if (_cameraController != null && _cameraController!.value.isInitialized) {
        _cameraController!.startImageStream((CameraImage image) async {
          if (!_isProcessing) return;

          await _faceFilterService.processImage(
            image,
            _cameraController!.description,
          );

          if (mounted) {
            setState(() {});
          }
        });
      }
    } catch (e) {
      print('❌ Error processing frame: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _changeFilter(FilterType filter) {
    setState(() {
      _currentFilter = filter;
      _faceFilterService.setFilter(filter);
    });

    HapticFeedback.lightImpact();
  }

  Future<void> _takePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      await _cameraController!.stopImageStream();
      final image = await _cameraController!.takePicture();

      HapticFeedback.mediumImpact();

      if (mounted) {
        Navigator.pop(context, image.path);
      }
    } catch (e) {
      print('❌ Error taking picture: $e');
    }
  }

  String _getFilterName(FilterType filter) {
    switch (filter) {
      case FilterType.none:
        return 'Sin filtro';
      case FilterType.dogEars:
        return 'Orejas de perro';
      case FilterType.catWhiskers:
        return 'Bigotes de gato';
      case FilterType.sunglasses:
        return 'Lentes de sol';
      case FilterType.crown:
        return 'Corona';
      case FilterType.mustache:
        return 'Bigote';
      case FilterType.bunnyEars:
        return 'Orejas de conejo';
      case FilterType.partyHat:
        return 'Gorro de fiesta';
    }
  }

  IconData _getFilterIcon(FilterType filter) {
    switch (filter) {
      case FilterType.none:
        return Icons.face_retouching_off;
      case FilterType.dogEars:
        return Icons.pets;
      case FilterType.catWhiskers:
        return Icons.emoji_nature;
      case FilterType.sunglasses:
        return Icons.wb_sunny;
      case FilterType.crown:
        return Icons.emoji_events;
      case FilterType.mustache:
        return Icons.face;
      case FilterType.bunnyEars:
        return Icons.cruelty_free;
      case FilterType.partyHat:
        return Icons.celebration;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF9D7FE8)),
              SizedBox(height: 16),
              Text(
                'Inicializando cámara AR...',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Vista de la cámara
            Positioned.fill(child: _buildCameraPreview()),

            // Overlay de filtros
            Positioned.fill(
              child: CustomPaint(
                painter: FilterPainter(
                  faces: _faceFilterService.detectedFaces,
                  filterType: _currentFilter,
                  imageSize: _cameraController?.value.previewSize ?? Size.zero,
                  widgetSize: MediaQuery.of(context).size,
                ),
              ),
            ),

            // Header con título y botón cerrar
            Positioned(top: 0, left: 0, right: 0, child: _buildHeader()),

            // Selector de filtros
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: _buildFilterSelector(),
            ),

            // Controles de cámara
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: _buildCameraControls(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Container();
    }

    return ClipRect(
      child: Transform.scale(
        scale:
            _cameraController!.value.aspectRatio /
            MediaQuery.of(context).size.aspectRatio,
        child: Center(child: CameraPreview(_cameraController!)),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.8), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close, color: Colors.white, size: 28),
          ),
          SizedBox(width: 8),
          Text(
            '🎭 Filtros AR',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Spacer(),
          if (_faceFilterService.detectedFaces.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_faceFilterService.detectedFaces.length} cara(s)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterSelector() {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 16),
        itemCount: _availableFilters.length,
        itemBuilder: (context, index) {
          final filter = _availableFilters[index];
          final isSelected = filter == _currentFilter;

          return GestureDetector(
            onTap: () => _changeFilter(filter),
            child: Container(
              width: 60,
              margin: EdgeInsets.only(right: 12),
              child: Column(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Color(0xFF9D7FE8)
                          : Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.white, width: 2)
                          : null,
                    ),
                    child: Icon(
                      _getFilterIcon(filter),
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    _getFilterName(filter),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCameraControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Cambiar cámara
        IconButton(
          onPressed: _switchCamera,
          icon: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.flip_camera_ios, color: Colors.white, size: 24),
          ),
        ),

        // Botón de foto
        GestureDetector(
          onTap: _takePicture,
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Icon(Icons.camera_alt, color: Color(0xFF9D7FE8), size: 32),
          ),
        ),

        // Galería
        IconButton(
          onPressed: () {
            // TODO: Implementar abrir galería
          },
          icon: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.photo_library, color: Colors.white, size: 24),
          ),
        ),
      ],
    );
  }

  Future<void> _switchCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.length < 2) return;

      final currentCamera = _cameraController!.description;
      final newCamera = cameras.firstWhere(
        (camera) => camera.lensDirection != currentCamera.lensDirection,
        orElse: () => cameras.first,
      );

      await _cameraController!.dispose();

      _cameraController = CameraController(
        newCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {});
        _startFaceDetection();
      }
    } catch (e) {
      print('❌ Error switching camera: $e');
    }
  }
}
