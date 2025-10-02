import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';

// Stub classes to replace ML Kit dependencies (AR features temporarily disabled)
class Face {
  final Rect boundingBox;
  final Map<FaceLandmarkType, FaceLandmark> landmarks;

  Face({required this.boundingBox, required this.landmarks});
}

class FaceLandmark {
  final Offset position;
  FaceLandmark({required this.position});
}

enum FaceLandmarkType {
  leftEye,
  rightEye,
  noseBase,
  bottomMouth,
}

class FaceDetector {
  FaceDetector({required FaceDetectorOptions options});

  Future<List<Face>> processImage(dynamic inputImage) async {
    // Return empty list since AR is disabled
    return [];
  }

  void close() {}
}

class FaceDetectorOptions {
  FaceDetectorOptions({
    bool? enableContours,
    bool? enableLandmarks,
    bool? enableClassification,
    bool? enableTracking,
    double? minFaceSize,
    FaceDetectorMode? performanceMode,
  });
}

enum FaceDetectorMode { fast }

class InputImage {
  static InputImage? fromBytes({required dynamic bytes, required dynamic inputImageData}) {
    return null; // Return null since AR is disabled
  }
}

class InputImageData {
  InputImageData({
    required Size size,
    required InputImageRotation imageRotation,
    required InputImageFormat inputImageFormat,
    required List<InputImagePlaneMetadata> planeData,
  });
}

class InputImagePlaneMetadata {
  InputImagePlaneMetadata({
    required int bytesPerRow,
    required int? height,
    required int? width,
  });
}

enum InputImageRotation {
  rotation0deg,
  rotation90deg,
  rotation180deg,
  rotation270deg,
}

enum InputImageFormat {
  yuv420,
  bgra8888,
  nv21,
}

enum FilterType {
  none,
  dogEars,
  catWhiskers,
  sunglasses,
  crown,
  mustache,
  bunnyEars,
  partyHat,
}

class FaceFilterService {
  static final FaceFilterService _instance = FaceFilterService._internal();
  factory FaceFilterService() => _instance;
  FaceFilterService._internal();

  late FaceDetector _faceDetector;
  bool _isInitialized = false;

  List<Face> _detectedFaces = [];
  FilterType _currentFilter = FilterType.none;

  List<Face> get detectedFaces => _detectedFaces;
  FilterType get currentFilter => _currentFilter;

  Future<void> initialize() async {
    if (_isInitialized) return;

    final options = FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      minFaceSize: 0.1,
      performanceMode: FaceDetectorMode.fast,
    );

    _faceDetector = FaceDetector(options: options);
    _isInitialized = true;
    print('🎭 Face Filter Service initialized');
  }

  void setFilter(FilterType filter) {
    _currentFilter = filter;
    print('🎭 Filter changed to: ${filter.name}');
  }

  Future<void> processImage(
    CameraImage cameraImage,
    CameraDescription camera,
  ) async {
    if (!_isInitialized) await initialize();

    try {
      final inputImage = _convertCameraImage(cameraImage, camera);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      _detectedFaces = faces;

      if (faces.isNotEmpty) {
        print('🎭 Detected ${faces.length} face(s)');
      }
    } catch (e) {
      print('❌ Error processing face detection: $e');
    }
  }

  InputImage? _convertCameraImage(
    CameraImage cameraImage,
    CameraDescription camera,
  ) {
    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in cameraImage.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final imageSize = Size(
        cameraImage.width.toDouble(),
        cameraImage.height.toDouble(),
      );

      final inputImageRotation = _rotationIntToImageRotation(
        camera.sensorOrientation,
      );

      final inputImageFormat = _formatGroup(cameraImage.format.group);

      final planeData = cameraImage.planes.map((plane) {
        return InputImagePlaneMetadata(
          bytesPerRow: plane.bytesPerRow,
          height: plane.height,
          width: plane.width,
        );
      }).toList();

      final inputImageData = InputImageData(
        size: imageSize,
        imageRotation: inputImageRotation,
        inputImageFormat: inputImageFormat,
        planeData: planeData,
      );

      return InputImage.fromBytes(bytes: bytes, inputImageData: inputImageData);
    } catch (e) {
      print('❌ Error converting camera image: $e');
      return null;
    }
  }

  InputImageRotation _rotationIntToImageRotation(int rotation) {
    switch (rotation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  InputImageFormat _formatGroup(ImageFormatGroup format) {
    switch (format) {
      case ImageFormatGroup.yuv420:
        return InputImageFormat.yuv420;
      case ImageFormatGroup.bgra8888:
        return InputImageFormat.bgra8888;
      default:
        return InputImageFormat.nv21;
    }
  }

  void dispose() {
    if (_isInitialized) {
      _faceDetector.close();
      _isInitialized = false;
      print('🎭 Face Filter Service disposed');
    }
  }
}

class FilterPainter extends CustomPainter {
  final List<Face> faces;
  final FilterType filterType;
  final Size imageSize;
  final Size widgetSize;

  FilterPainter({
    required this.faces,
    required this.filterType,
    required this.imageSize,
    required this.widgetSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (faces.isEmpty || filterType == FilterType.none) return;

    final scaleX = widgetSize.width / imageSize.width;
    final scaleY = widgetSize.height / imageSize.height;

    for (final face in faces) {
      _drawFilter(canvas, face, scaleX, scaleY);
    }
  }

  void _drawFilter(Canvas canvas, Face face, double scaleX, double scaleY) {
    final boundingBox = face.boundingBox;
    final centerX = boundingBox.center.dx * scaleX;
    final centerY = boundingBox.center.dy * scaleY;
    final faceWidth = boundingBox.width * scaleX;
    final faceHeight = boundingBox.height * scaleY;

    switch (filterType) {
      case FilterType.dogEars:
        _drawDogEars(canvas, centerX, centerY, faceWidth);
        break;
      case FilterType.catWhiskers:
        _drawCatWhiskers(canvas, face, scaleX, scaleY);
        break;
      case FilterType.sunglasses:
        _drawSunglasses(canvas, face, scaleX, scaleY);
        break;
      case FilterType.crown:
        _drawCrown(canvas, centerX, centerY - faceHeight * 0.6, faceWidth);
        break;
      case FilterType.mustache:
        _drawMustache(canvas, face, scaleX, scaleY);
        break;
      case FilterType.bunnyEars:
        _drawBunnyEars(canvas, centerX, centerY, faceWidth);
        break;
      case FilterType.partyHat:
        _drawPartyHat(canvas, centerX, centerY - faceHeight * 0.7, faceWidth);
        break;
      case FilterType.none:
        break;
    }
  }

  void _drawDogEars(
    Canvas canvas,
    double centerX,
    double centerY,
    double faceWidth,
  ) {
    final paint = Paint()
      ..color = Colors.brown
      ..style = PaintingStyle.fill;

    final earSize = faceWidth * 0.3;
    final earOffsetY = faceWidth * 0.4;

    // Oreja izquierda
    final leftEarPath = Path();
    leftEarPath.moveTo(centerX - faceWidth * 0.3, centerY - earOffsetY);
    leftEarPath.quadraticBezierTo(
      centerX - faceWidth * 0.5,
      centerY - earOffsetY - earSize,
      centerX - faceWidth * 0.1,
      centerY - earOffsetY - earSize * 0.5,
    );
    leftEarPath.close();

    // Oreja derecha
    final rightEarPath = Path();
    rightEarPath.moveTo(centerX + faceWidth * 0.3, centerY - earOffsetY);
    rightEarPath.quadraticBezierTo(
      centerX + faceWidth * 0.5,
      centerY - earOffsetY - earSize,
      centerX + faceWidth * 0.1,
      centerY - earOffsetY - earSize * 0.5,
    );
    rightEarPath.close();

    canvas.drawPath(leftEarPath, paint);
    canvas.drawPath(rightEarPath, paint);

    // Interior de las orejas
    paint.color = Colors.pink;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          centerX - faceWidth * 0.25,
          centerY - earOffsetY - earSize * 0.3,
        ),
        width: earSize * 0.3,
        height: earSize * 0.4,
      ),
      paint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          centerX + faceWidth * 0.25,
          centerY - earOffsetY - earSize * 0.3,
        ),
        width: earSize * 0.3,
        height: earSize * 0.4,
      ),
      paint,
    );
  }

  void _drawCatWhiskers(
    Canvas canvas,
    Face face,
    double scaleX,
    double scaleY,
  ) {
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    if (nose == null) return;

    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final noseX = nose.position.dx * scaleX;
    final noseY = nose.position.dy * scaleY;
    final whiskerLength = face.boundingBox.width * scaleX * 0.15;

    // Bigotes izquierdos
    for (int i = 0; i < 3; i++) {
      final startY = noseY + (i - 1) * 8;
      canvas.drawLine(
        Offset(noseX - whiskerLength * 0.3, startY),
        Offset(noseX - whiskerLength * 1.2, startY + (i - 1) * 5),
        paint,
      );
    }

    // Bigotes derechos
    for (int i = 0; i < 3; i++) {
      final startY = noseY + (i - 1) * 8;
      canvas.drawLine(
        Offset(noseX + whiskerLength * 0.3, startY),
        Offset(noseX + whiskerLength * 1.2, startY + (i - 1) * 5),
        paint,
      );
    }
  }

  void _drawSunglasses(Canvas canvas, Face face, double scaleX, double scaleY) {
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];

    if (leftEye == null || rightEye == null) return;

    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final framePaint = Paint()
      ..color = Colors.grey[800]!
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke;

    final eyeRadius = face.boundingBox.width * scaleX * 0.08;

    // Lente izquierdo
    canvas.drawCircle(
      Offset(
        leftEye.position.dx * scaleX,
        leftEye.position.dy * scaleY,
      ),
      eyeRadius,
      paint,
    );
    canvas.drawCircle(
      Offset(
        leftEye.position.dx * scaleX,
        leftEye.position.dy * scaleY,
      ),
      eyeRadius,
      framePaint,
    );

    // Lente derecho
    canvas.drawCircle(
      Offset(
        rightEye.position.dx * scaleX,
        rightEye.position.dy * scaleY,
      ),
      eyeRadius,
      paint,
    );
    canvas.drawCircle(
      Offset(
        rightEye.position.dx * scaleX,
        rightEye.position.dy * scaleY,
      ),
      eyeRadius,
      framePaint,
    );

    // Puente
    canvas.drawLine(
      Offset(
        leftEye.position.dx * scaleX + eyeRadius,
        leftEye.position.dy * scaleY,
      ),
      Offset(
        rightEye.position.dx * scaleX - eyeRadius,
        rightEye.position.dy * scaleY,
      ),
      framePaint,
    );
  }

  void _drawCrown(
    Canvas canvas,
    double centerX,
    double centerY,
    double faceWidth,
  ) {
    final paint = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final crownWidth = faceWidth * 0.8;
    final crownHeight = faceWidth * 0.3;

    final crownPath = Path();
    crownPath.moveTo(centerX - crownWidth / 2, centerY);

    // Puntas de la corona
    for (int i = 0; i < 5; i++) {
      final x = centerX - crownWidth / 2 + (crownWidth / 4) * i;
      final isHighPeak = i % 2 == 0;
      final peakHeight = isHighPeak ? crownHeight : crownHeight * 0.6;

      crownPath.lineTo(x, centerY - peakHeight);
    }

    crownPath.lineTo(centerX + crownWidth / 2, centerY);
    crownPath.close();

    canvas.drawPath(crownPath, paint);
    canvas.drawPath(crownPath, strokePaint);

    // Joyas en la corona
    final jewelPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    for (int i = 0; i < 3; i++) {
      final x = centerX - crownWidth / 4 + (crownWidth / 4) * i;
      canvas.drawCircle(Offset(x, centerY - crownHeight * 0.3), 4, jewelPaint);
    }
  }

  void _drawMustache(Canvas canvas, Face face, double scaleX, double scaleY) {
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    final mouth = face.landmarks[FaceLandmarkType.bottomMouth];

    if (nose == null || mouth == null) return;

    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final centerX = nose.position.dx * scaleX;
    final centerY =
        (nose.position.dy + mouth.position.dy) *
        scaleY /
        2;
    final mustacheWidth = face.boundingBox.width * scaleX * 0.15;

    final mustachePath = Path();
    mustachePath.moveTo(centerX, centerY);

    // Lado izquierdo
    mustachePath.quadraticBezierTo(
      centerX - mustacheWidth,
      centerY - mustacheWidth * 0.3,
      centerX - mustacheWidth * 1.5,
      centerY + mustacheWidth * 0.2,
    );
    mustachePath.quadraticBezierTo(
      centerX - mustacheWidth,
      centerY + mustacheWidth * 0.4,
      centerX,
      centerY + mustacheWidth * 0.2,
    );

    // Lado derecho
    mustachePath.quadraticBezierTo(
      centerX + mustacheWidth,
      centerY + mustacheWidth * 0.4,
      centerX + mustacheWidth * 1.5,
      centerY + mustacheWidth * 0.2,
    );
    mustachePath.quadraticBezierTo(
      centerX + mustacheWidth,
      centerY - mustacheWidth * 0.3,
      centerX,
      centerY,
    );

    mustachePath.close();
    canvas.drawPath(mustachePath, paint);
  }

  void _drawBunnyEars(
    Canvas canvas,
    double centerX,
    double centerY,
    double faceWidth,
  ) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.grey
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final earWidth = faceWidth * 0.12;
    final earHeight = faceWidth * 0.4;
    final earOffset = faceWidth * 0.25;

    // Oreja izquierda
    final leftEarPath = Path();
    leftEarPath.addOval(
      Rect.fromCenter(
        center: Offset(centerX - earOffset, centerY - earHeight / 2),
        width: earWidth,
        height: earHeight,
      ),
    );

    // Oreja derecha
    final rightEarPath = Path();
    rightEarPath.addOval(
      Rect.fromCenter(
        center: Offset(centerX + earOffset, centerY - earHeight / 2),
        width: earWidth,
        height: earHeight,
      ),
    );

    canvas.drawPath(leftEarPath, paint);
    canvas.drawPath(leftEarPath, strokePaint);
    canvas.drawPath(rightEarPath, paint);
    canvas.drawPath(rightEarPath, strokePaint);

    // Interior rosado
    final pinkPaint = Paint()
      ..color = Colors.pink[200]!
      ..style = PaintingStyle.fill;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX - earOffset, centerY - earHeight / 2),
        width: earWidth * 0.6,
        height: earHeight * 0.8,
      ),
      pinkPaint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(centerX + earOffset, centerY - earHeight / 2),
        width: earWidth * 0.6,
        height: earHeight * 0.8,
      ),
      pinkPaint,
    );
  }

  void _drawPartyHat(
    Canvas canvas,
    double centerX,
    double centerY,
    double faceWidth,
  ) {
    final paint = Paint()
      ..color = Colors.purple
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = Colors.deepPurple
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final hatWidth = faceWidth * 0.6;
    final hatHeight = faceWidth * 0.5;

    final hatPath = Path();
    hatPath.moveTo(centerX - hatWidth / 2, centerY);
    hatPath.lineTo(centerX, centerY - hatHeight);
    hatPath.lineTo(centerX + hatWidth / 2, centerY);
    hatPath.close();

    canvas.drawPath(hatPath, paint);
    canvas.drawPath(hatPath, strokePaint);

    // Pompón
    final pomponPaint = Paint()
      ..color = Colors.yellow
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(centerX, centerY - hatHeight), 8, pomponPaint);

    // Patrón de rayas
    final stripePaint = Paint()
      ..color = Colors.pink
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    for (int i = 1; i < 4; i++) {
      final y = centerY - (hatHeight / 4) * i;
      final width = hatWidth * (1 - i * 0.2);
      canvas.drawLine(
        Offset(centerX - width / 2, y),
        Offset(centerX + width / 2, y),
        stripePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
