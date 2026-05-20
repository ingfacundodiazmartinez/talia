import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../../utils/release_logger.dart';

/// Widget que SOLO dibuja el preview de cámara. No crea ni dispone el
/// [CameraController]: lo recibe ya inicializado desde el [StoryCameraController].
class FlutterCameraView extends StatelessWidget {
  final CameraController controller;

  const FlutterCameraView({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    try {
      if (!controller.value.isInitialized) {
        throw Exception('Controller no inicializado');
      }

      final value = controller.value;
      if (value.hasError) {
        throw Exception('Controller tiene error: ${value.errorDescription}');
      }

      final previewAspect = 1.0 / value.aspectRatio;
      return SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: AspectRatio(
            aspectRatio: previewAspect,
            child: CameraPreview(controller),
          ),
        ),
      );
    } catch (e) {
      ReleaseLogger.log('❌ FlutterCameraView: Error en preview: $e');
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
