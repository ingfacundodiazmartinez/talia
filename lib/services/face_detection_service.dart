import 'dart:io';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import '../utils/release_logger.dart';

/// Servicio simple para detectar caras en imágenes
/// Usado para validar que hay una cara visible antes de aplicar transformaciones con IA
class FaceDetectionService {
  static final FaceDetectionService _instance = FaceDetectionService._internal();
  factory FaceDetectionService() => _instance;
  FaceDetectionService._internal();

  FaceDetector? _faceDetector;

  /// Inicializar el detector (lazy initialization)
  FaceDetector get _detector {
    _faceDetector ??= FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableLandmarks: false,
        enableClassification: false,
        enableTracking: false,
        minFaceSize: 0.10, // ✅ FIX: Reducido de 0.15 a 0.10 para mejor detección
        performanceMode: FaceDetectorMode.fast,
      ),
    );
    return _faceDetector!;
  }

  /// Detectar si hay al menos una cara en la imagen
  ///
  /// Returns: true si se detectó al menos una cara, false si no
  Future<bool> hasFace(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        ReleaseLogger.error('FaceDetection: Archivo no existe: $imagePath', tag: 'FaceDetectionService');
        return false;
      }

      // ✅ FIX iOS: Procesar imagen para aplicar rotación EXIF correctamente
      // En iOS, las fotos tienen metadata de rotación que InputImage.fromFilePath no maneja bien
      final inputImage = await _createInputImage(file);
      final faces = await _detector.processImage(inputImage);

      ReleaseLogger.log(
        'FaceDetection: ${faces.length} cara(s) detectada(s)',
        tag: 'FaceDetectionService',
      );

      return faces.isNotEmpty;
    } catch (e) {
      ReleaseLogger.error('FaceDetection error: $e', tag: 'FaceDetectionService');
      // En caso de error, permitir continuar (mejor UX que bloquear)
      return true;
    }
  }

  /// Crear InputImage procesando correctamente la rotación EXIF
  /// Esto es especialmente importante en iOS donde las fotos tienen rotación en metadata
  Future<InputImage> _createInputImage(File file) async {
    try {
      // Leer bytes de la imagen
      final bytes = await file.readAsBytes();

      // Decodificar imagen con la librería image para obtener la orientación
      final decodedImage = img.decodeImage(bytes);

      if (decodedImage == null) {
        // Si no podemos decodificar, usar el método tradicional
        ReleaseLogger.log('FaceDetection: No se pudo decodificar imagen, usando fromFilePath', tag: 'FaceDetectionService');
        return InputImage.fromFilePath(file.path);
      }

      // La librería image aplica automáticamente la rotación EXIF al decodificar
      // Re-codificar como JPEG para tener una imagen con la orientación correcta
      final correctedBytes = img.encodeJpg(decodedImage, quality: 90);

      // Crear InputImage desde bytes con metadata correcta
      final inputImageData = InputImageMetadata(
        size: Size(decodedImage.width.toDouble(), decodedImage.height.toDouble()),
        rotation: InputImageRotation.rotation0deg, // Ya está rotada correctamente
        format: InputImageFormat.nv21, // Formato común
        bytesPerRow: decodedImage.width,
      );

      ReleaseLogger.log(
        'FaceDetection: Imagen procesada ${decodedImage.width}x${decodedImage.height}',
        tag: 'FaceDetectionService',
      );

      // Usar fromBytes con la imagen ya corregida
      // Si fromBytes falla, intentar con archivo temporal
      try {
        // Guardar imagen corregida temporalmente
        final tempDir = file.parent;
        final tempFile = File('${tempDir.path}/face_detect_temp_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await tempFile.writeAsBytes(correctedBytes);

        final inputImage = InputImage.fromFilePath(tempFile.path);

        // Programar eliminación del archivo temporal
        Future.delayed(Duration(seconds: 5), () {
          tempFile.delete().catchError((_) {});
        });

        return inputImage;
      } catch (e) {
        ReleaseLogger.log('FaceDetection: Error creando temp file, usando original', tag: 'FaceDetectionService');
        return InputImage.fromFilePath(file.path);
      }
    } catch (e) {
      ReleaseLogger.log('FaceDetection: Error procesando imagen: $e', tag: 'FaceDetectionService');
      // Fallback al método tradicional
      return InputImage.fromFilePath(file.path);
    }
  }

  /// Detectar caras y retornar información detallada
  ///
  /// Returns: Lista de caras detectadas con sus bounding boxes
  Future<List<DetectedFace>> detectFaces(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return [];
      }

      final inputImage = InputImage.fromFilePath(imagePath);
      final faces = await _detector.processImage(inputImage);

      return faces.map((face) => DetectedFace(
        boundingBox: face.boundingBox,
        headEulerAngleY: face.headEulerAngleY,
        headEulerAngleZ: face.headEulerAngleZ,
      )).toList();
    } catch (e) {
      ReleaseLogger.error('FaceDetection error: $e', tag: 'FaceDetectionService');
      return [];
    }
  }

  /// Liberar recursos
  void dispose() {
    _faceDetector?.close();
    _faceDetector = null;
  }
}

/// Información básica de una cara detectada
class DetectedFace {
  final Rect boundingBox;
  final double? headEulerAngleY; // Rotación Y (izquierda/derecha)
  final double? headEulerAngleZ; // Rotación Z (inclinación)

  DetectedFace({
    required this.boundingBox,
    this.headEulerAngleY,
    this.headEulerAngleZ,
  });

  /// Verificar si la cara está mirando de frente (aproximadamente)
  bool get isFacingFront {
    if (headEulerAngleY == null) return true;
    // Tolerancia de 30 grados
    return headEulerAngleY!.abs() < 30;
  }
}
