import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

/// Widget separado para manejar cámara Flutter de forma completamente aislada
class FlutterCameraView extends StatefulWidget {
  final List<CameraDescription>? cameras;
  final int selectedCameraIndex;
  final Function(CameraController?) onCameraInitialized;
  final VoidCallback onCameraDisposed;

  const FlutterCameraView({
    super.key,
    required this.cameras,
    required this.selectedCameraIndex,
    required this.onCameraInitialized,
    required this.onCameraDisposed,
  });

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
        enableAudio: true, // ✅ Habilitar audio para grabación de video
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
        child: const Center(
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
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                _isInitializing
                    ? 'Inicializando cámara...'
                    : 'Preparando cámara...',
                style: const TextStyle(color: Colors.white, fontSize: 16),
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

      // 🔍 DEBUG: Investigar dimensiones y aspectRatio
      final screenSize = MediaQuery.of(context).size;
      final screenAspectRatio = screenSize.width / screenSize.height;
      print('🔍 DEBUG Camera aspectRatio: ${value.aspectRatio}');
      print('🔍 DEBUG Screen size: ${screenSize.width} x ${screenSize.height}');
      print('🔍 DEBUG Screen aspectRatio: $screenAspectRatio');
      print('🔍 DEBUG Camera previewSize: ${value.previewSize}');
      if (value.previewSize != null) {
        final previewAspectRatio = value.previewSize!.width / value.previewSize!.height;
        print('🔍 DEBUG Preview aspectRatio calculado: $previewAspectRatio');
        print('🔍 DEBUG Preview width: ${value.previewSize!.width}, height: ${value.previewSize!.height}');
      }

      // 🔍 TEST: Probar diferentes enfoques para aspectRatio
      // Hipótesis: Las dimensiones pueden estar invertidas por orientación del dispositivo

      // Opción 1: AspectRatio original (problema actual)
      final originalAspectRatio = value.aspectRatio;

      // Opción 2: AspectRatio invertido (width/height -> height/width)
      final invertedAspectRatio = 1.0 / value.aspectRatio;

      // Opción 3: Usar Transform.scale pero corregido para portrait
      // PROBLEMA DETECTADO: Camera reporta 1.78 (landscape) pero pantalla es 0.46 (portrait)
      // SOLUCIÓN: Usar aspectRatio invertido para match con orientación portrait
      final correctedAspectRatio = invertedAspectRatio; // 0.5625 en lugar de 1.78
      final scaleForTransform = correctedAspectRatio / screenAspectRatio;

      print('🔍 DEBUG originalAspectRatio: $originalAspectRatio');
      print('🔍 DEBUG invertedAspectRatio: $invertedAspectRatio');
      print('🔍 DEBUG correctedAspectRatio: $correctedAspectRatio');
      print('🔍 DEBUG scaleForTransform CORREGIDO: $scaleForTransform');

      // 🎯 ENFOQUE FINAL: Probando varios enfoques para encontrar el correcto

      // Opción A: Transform.scale (actual - tiene zoom residual)
      // return Container(
      //   width: double.infinity,
      //   height: double.infinity,
      //   child: ClipRect(
      //     child: Transform.scale(
      //       scale: scaleForTransform,
      //       child: Center(
      //         child: CameraPreview(_controller!),
      //       ),
      //     ),
      //   ),
      // );

      // Opción B: AspectRatio con el aspectRatio corregido (portrait)
      return Container(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: AspectRatio(
            aspectRatio: correctedAspectRatio, // Usar 0.5625 en lugar de 1.78
            child: CameraPreview(_controller!),
          ),
        ),
      );
    } catch (e) {
      print('❌ FlutterCameraView: Error en preview: $e');
      return Container(
        color: Colors.black,
        child: const Center(
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
