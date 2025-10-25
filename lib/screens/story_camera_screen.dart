import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../services/deepar_service.dart';
import '../services/story_service.dart';
import '../services/stickers_service.dart';
import '../widgets/permission_dialog.dart';
import '../widgets/camera/flutter_camera_view.dart';
import '../widgets/camera/deepar_camera_view.dart';
import 'package:flutter_story_editor/flutter_story_editor.dart';
import 'package:flutter_story_editor/src/controller/controller.dart';

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
  String? _selectedARFilter = DeepARFilters.none; // Iniciar sin filtro
  String _filterType = 'deepar'; // Solo DeepAR por defecto
  bool _hasInitializationFailed = false;
  bool _isDeepARInitialized = false;
  bool _hasCameraPermissions = false; // CRÍTICO: Flag para saber si tenemos permisos
  int _deepARReinitCounter = 0; // Contador para forzar recreación de DeepARCameraView
  bool _isRecordingVideo = false;
  String? _recordedVideoPath;
  Timer? _recordingTimer; // Timer para límite de 10 segundos
  int _recordingSecondsRemaining = 10; // Segundos restantes de grabación

  final DeepARService _deepARService = DeepARService();
  final ImagePicker _imagePicker = ImagePicker();

  // Stickers service and cache
  List<StickerMetadata> _stickerMetadata = [];
  bool _isLoadingStickers = false;

  // Filtros DeepAR disponibles realmente
  final Map<String, Map<String, dynamic>> _deepARFilters = {
    DeepARFilters.none: {'name': 'Normal', 'icon': Icons.face, 'emoji': '😊'},
    DeepARFilters.vendetta: {'name': 'Vendetta', 'icon': Icons.face, 'emoji': '🎭'},
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
    // DeepARFilters.snail - ELIMINADO: tiene fondo blanco que hace invisibles los controles
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

    // Cargar stickers en segundo plano mientras la cámara se inicializa
    _loadCustomStickers();
  }

  Future<void> _initializeCamera() async {
    try {
      print('📱 Inicializando cámara para historias...');

      // Intentar obtener cámaras directamente - iOS pedirá permisos automáticamente si es necesario
      print('📸 Obteniendo cámaras disponibles (iOS pedirá permisos si es necesario)...');
      try {
        _cameras = await availableCameras();

        if (_cameras == null || _cameras!.isEmpty) {
          throw Exception('No se encontraron cámaras en el dispositivo');
        }

        print('✅ Cámaras disponibles: ${_cameras!.length}');

        setState(() {
          _hasCameraPermissions = true;
          _hasInitializationFailed = false;
        });

        print('🎭 Modo DeepAR por defecto - cámara lista');
      } catch (e) {
        print('❌ Error obteniendo cámaras: $e');

        // Verificar si fue por permisos denegados
        var cameraStatus = await Permission.camera.status;

        if (cameraStatus.isPermanentlyDenied) {
          print('⚠️ Permiso permanentemente denegado');
          setState(() {
            _hasInitializationFailed = true;
            _hasCameraPermissions = false;
          });
          _showAppSettingsDialog();
          return;
        } else if (cameraStatus.isDenied) {
          print('❌ Permiso de cámara denegado');
          setState(() {
            _hasInitializationFailed = true;
            _hasCameraPermissions = false;
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Se requiere permiso de cámara para crear historias'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );

            Future.delayed(Duration(seconds: 3), () {
              if (mounted) {
                Navigator.pop(context);
              }
            });
          }
          return;
        }

        // Si no fue por permisos, es otro error
        throw Exception('No se pudieron obtener las cámaras: $e');
      }
    } catch (e) {
      print('❌ Error fatal inicializando cámara: $e');

      setState(() {
        _hasInitializationFailed = true;
        _hasCameraPermissions = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al inicializar cámara. Por favor verifica los permisos.'),
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

      print('✅ Navegando al editor de stories con: $finalImagePath');

      // Navegar a pantalla de edición
      if (mounted) {
        // Esperar un frame antes de navegar para asegurar que el estado se actualizó
        await Future.delayed(Duration(milliseconds: 100));

        if (mounted) {
          await _openStoryEditor(finalImagePath, isVideo: false);
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

  Future<void> _startVideoRecording() async {
    if (_isLoading || _isRecordingVideo) return;

    try {
      print('🎥 Iniciando grabación de video...');
      setState(() {
        _isLoading = true;
        _recordingSecondsRemaining = 10; // Reset contador
      });

      // Si estamos en modo DeepAR, usar su grabación de video
      if (_filterType == 'deepar' && _isDeepARInitialized) {
        print('🎥 Iniciando grabación con DeepAR...');
        // Generar path para el video
        final directory = await getTemporaryDirectory();
        final videoPath =
            '${directory.path}/deepar_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

        // Obtener dimensiones de la pantalla
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;

        // Calcular dimensiones en píxeles
        final widthPx = (screenWidth * devicePixelRatio).round();
        final heightPx = (screenHeight * devicePixelRatio).round();

        print('📱 Dimensiones de pantalla: ${widthPx}x${heightPx}');

        final success = await _deepARService.startRecording(
          outputPath: videoPath,
          width: widthPx,
          height: heightPx,
        );

        if (success) {
          setState(() {
            _isRecordingVideo = true;
            _recordedVideoPath = videoPath;
            _isLoading = false;
          });

          // CRÍTICO: Iniciar timer de 10 segundos
          _startRecordingTimer();
          print('✅ Grabación de video iniciada: $videoPath');
        } else {
          throw Exception('No se pudo iniciar la grabación con DeepAR');
        }
      } else {
        // Modo Flutter camera
        if (_controller == null || !_controller!.value.isInitialized) {
          throw Exception('Cámara no inicializada');
        }

        await _controller!.startVideoRecording();
        setState(() {
          _isRecordingVideo = true;
          _isLoading = false;
        });

        // CRÍTICO: Iniciar timer de 10 segundos
        _startRecordingTimer();
        print('✅ Grabación de video iniciada con Flutter Camera');
      }
    } catch (e) {
      print('❌ Error iniciando grabación: $e');
      setState(() {
        _isLoading = false;
        _isRecordingVideo = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar grabación'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Iniciar timer de grabación con límite de 10 segundos
  void _startRecordingTimer() {
    _recordingTimer?.cancel(); // Cancelar timer anterior si existe
    _recordingTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        _recordingSecondsRemaining--;
      });

      print('⏱️ Tiempo restante: $_recordingSecondsRemaining segundos');

      // Si llegamos a 0, detener automáticamente
      if (_recordingSecondsRemaining <= 0) {
        timer.cancel();
        print('⏱️ Límite de 10 segundos alcanzado - deteniendo grabación automáticamente');
        _stopVideoRecording();
      }
    });
  }

  Future<void> _stopVideoRecording() async {
    if (!_isRecordingVideo) return;

    // 🛑 Cancelar timer de grabación
    _recordingTimer?.cancel();
    _recordingTimer = null;

    // CRÍTICO: Marcar como no grabando INMEDIATAMENTE para prevenir llamadas múltiples
    setState(() {
      _isRecordingVideo = false;
      _isLoading = true;
    });

    try {
      print('🛑 Deteniendo grabación de video...');
      String? videoPath;

      if (_filterType == 'deepar' && _isDeepARInitialized) {
        print('🛑 Deteniendo grabación con DeepAR...');
        final success = await _deepARService.stopRecording();

        if (success) {
          // Usar el path que guardamos al iniciar la grabación
          videoPath = _recordedVideoPath;
          print('✅ Video grabado con DeepAR: $videoPath');

          // IMPORTANTE: Esperar a que el archivo esté completamente escrito
          // DeepAR puede necesitar un momento para finalizar la escritura del archivo
          print('⏳ Esperando a que el video termine de escribirse...');
          await Future.delayed(Duration(milliseconds: 1000));

          // Verificar múltiples veces si el archivo existe
          int attempts = 0;
          bool fileFound = false;
          while (attempts < 15 && videoPath != null) {
            if (await File(videoPath).exists()) {
              final fileSize = await File(videoPath).length();
              print('✅ Archivo verificado: $videoPath (${fileSize} bytes)');
              fileFound = true;
              break;
            }
            print('⏳ Esperando archivo... (intento ${attempts + 1}/15)');
            await Future.delayed(Duration(milliseconds: 500));
            attempts++;
          }

          // Si no encontramos el archivo en el path esperado, buscar en el directorio temporal
          if (!fileFound) {
            print('⚠️ Archivo no encontrado en path esperado, buscando en directorio temporal...');
            final directory = await getTemporaryDirectory();
            final tempDir = Directory(directory.path);

            // Buscar archivos .mp4 recientes (últimos 30 segundos)
            final now = DateTime.now();
            final files = tempDir.listSync()
                .where((file) => file.path.endsWith('.mp4'))
                .map((file) => File(file.path))
                .where((file) {
                  final stat = file.statSync();
                  final modified = stat.modified;
                  return now.difference(modified).inSeconds < 30;
                })
                .toList();

            files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

            if (files.isNotEmpty) {
              videoPath = files.first.path;
              print('✅ Archivo encontrado en búsqueda: $videoPath');
            } else {
              print('❌ No se encontró ningún archivo de video reciente');
              videoPath = null;
            }
          }
        } else {
          throw Exception('Error deteniendo grabación de DeepAR');
        }
      } else {
        // Modo Flutter camera
        if (_controller == null || !_controller!.value.isInitialized) {
          throw Exception('Cámara no inicializada');
        }

        final video = await _controller!.stopVideoRecording();
        videoPath = video.path;
        print('✅ Video grabado con Flutter Camera: $videoPath');
      }

      // Actualizar estado de loading
      setState(() {
        _isLoading = false;
      });

      // Verificar que el archivo existe
      if (videoPath != null && await File(videoPath).exists()) {
        // Verificar tamaño del archivo
        final fileSize = await File(videoPath).length();
        print('📹 Video capturado - Tamaño: ${fileSize / 1024 / 1024} MB');

        print('✅ Navegando al editor de stories con video: $videoPath');

        if (mounted) {
          await _openStoryEditor(videoPath, isVideo: true);
        }

          // Reinicializar DeepAR si es necesario
          if (_filterType == 'deepar' && mounted) {
            print('🔄 Reinicializando DeepAR...');
            await _deepARService.dispose();
            setState(() {
              _isDeepARInitialized = false;
              _deepARReinitCounter++;
            });
          }
        }
      else {
        throw Exception('El archivo de video no existe');
      }
    } catch (e) {
      print('❌ Error deteniendo grabación: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al grabar video'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Toggle video recording on/off
  Future<void> _toggleVideoRecording() async {
    if (_isRecordingVideo) {
      // Detener grabación
      await _stopVideoRecording();
    } else {
      // Iniciar grabación
      await _startVideoRecording();
    }
  }

  /// Cargar stickers personalizados desde Firebase Storage
  /// Carga metadata de stickers de forma asíncrona (no bloquea la UI)
  /// Los stickers individuales se descargarán lazy cuando se muestren
  Future<void> _loadCustomStickers() async {
    if (_isLoadingStickers || _stickerMetadata.isNotEmpty) {
      print('⏭️ Skipping stickers load: isLoading=$_isLoadingStickers, count=${_stickerMetadata.length}');
      return;
    }

    setState(() {
      _isLoadingStickers = true;
    });

    try {
      print('🎨 Cargando metadata de stickers desde Firestore...');
      final stickersService = StickersService();

      // Solo obtener metadata (rápido, no descarga archivos)
      print('📥 Obteniendo metadata de stickers...');
      final stickersMetadata = await stickersService.getAvailableStickers();
      print('✅ Metadata obtenida: ${stickersMetadata.length} stickers encontrados');

      if (stickersMetadata.isEmpty) {
        print('⚠️ No hay stickers en Firestore!');
      }

      if (mounted) {
        setState(() {
          _stickerMetadata = stickersMetadata;
          _isLoadingStickers = false;
        });
        print('✅ Metadata cargada en memoria: ${_stickerMetadata.length} stickers');

        // Debug: mostrar categorías
        final categories = stickersMetadata.map((s) => s.category).toSet();
        print('📂 Categorías: ${categories.join(", ")}');
        print('⚡ Descarga lazy habilitada - los stickers se descargarán cuando se muestren');
      }
    } catch (e, stackTrace) {
      print('❌ Error cargando stickers: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _isLoadingStickers = false;
        });
      }
    }
  }

  /// Abrir editor de historias con FlutterStoryEditor
  Future<void> _openStoryEditor(String mediaPath, {required bool isVideo}) async {
    try {
      print('🎨 Abriendo editor de stories...');
      print('📊 Stickers disponibles: ${_stickerMetadata.length}');

      final controller = FlutterStoryEditorController();
      final captionController = TextEditingController();

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => Scaffold(
            body: FlutterStoryEditor(
              controller: controller,
              captionController: captionController,
              selectedFiles: [File(mediaPath)],
              stickerMetadata: _stickerMetadata.isNotEmpty ? _stickerMetadata.cast<dynamic>() : null,
              useCustomStickersOnly: _stickerMetadata.isNotEmpty, // Use only custom stickers if available
              onSaveClickListener: (List<File> editedFiles) async {
                print('✅ Archivos editados: ${editedFiles.length}');

                if (editedFiles.isNotEmpty && mounted) {
                  final editedPath = editedFiles.first.path;
                  print('📝 Publicando historia directamente...');

                  // Publicar historia primero (ANTES de cerrar el editor)
                  await _publishStory(
                    mediaPath: editedPath,
                    isVideo: isVideo,
                    caption: captionController.text.trim().isEmpty
                        ? null
                        : captionController.text.trim(),
                  );

                  // Cerrar el editor DESPUÉS de publicar
                  if (mounted) {
                    Navigator.pop(context);
                  }
                }
              },
            ),
          ),
        ),
      );

      print('✅ Regresó del editor');
    } catch (e) {
      print('❌ Error en editor de stories: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al editar la historia'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Publicar historia directamente desde el editor
  Future<void> _publishStory({
    required String mediaPath,
    required bool isVideo,
    String? caption,
  }) async {
    try {
      // NO mostrar dialog aquí - el loading se muestra en el CaptionView

      final storyId = await StoryService().createStory(
        mediaPath: mediaPath,
        mediaType: isVideo ? 'video' : 'image',
        caption: caption,
        filter: _selectedFilter != null || _selectedARFilter != null
            ? {'type': _selectedFilter, 'arFilter': _selectedARFilter}
            : null,
      );

      print('✅ Historia publicada: $storyId');

      // Cerrar la pantalla de cámara DESPUÉS de publicar
      if (mounted) {
        Navigator.pop(context); // Cerrar cámara
      }
    } catch (e) {
      print('❌ Error publicando historia: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al compartir historia: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Pick image or video from gallery
  Future<void> _pickFromGallery() async {
    try {
      print('📸 Abriendo selector de galería...');

      // Mostrar diálogo para seleccionar tipo de media
      final mediaType = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Seleccionar media'),
          content: Text('¿Qué deseas compartir?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'image'),
              child: Text('📷 Foto'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'video'),
              child: Text('🎥 Video'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancelar'),
            ),
          ],
        ),
      );

      if (mediaType == null) return;

      setState(() {
        _isLoading = true;
      });

      XFile? pickedFile;
      if (mediaType == 'image') {
        pickedFile = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 85,
        );
      } else if (mediaType == 'video') {
        pickedFile = await _imagePicker.pickVideo(
          source: ImageSource.gallery,
          maxDuration: Duration(seconds: 10), // Límite de 10 segundos
        );
      }

      if (pickedFile != null && mounted) {
        print('✅ Archivo seleccionado: ${pickedFile.path}');

        // Abrir editor con el archivo seleccionado
        await _openStoryEditor(
          pickedFile!.path,
          isVideo: mediaType == 'video',
        );

        print('✅ Regresó del editor');
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Error seleccionando de galería: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al seleccionar archivo'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        _isLoading = false;
      });
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

    // Cancelar timer de grabación si existe
    _recordingTimer?.cancel();
    _recordingTimer = null;

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
                        // Galería
                        IconButton(
                          onPressed: _isLoading || _isRecordingVideo ? null : _pickFromGallery,
                          icon: Icon(
                            Icons.photo_library,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),

                        // Botón para FOTO
                        GestureDetector(
                          onTap: _isLoading || _isRecordingVideo ? null : _takePicture,
                          child: Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withOpacity(0.3),
                              border: Border.all(
                                color: Colors.white,
                                width: 3,
                              ),
                            ),
                            child: _isLoading && !_isRecordingVideo
                                ? Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    Icons.camera_alt,
                                    color: Colors.white,
                                    size: 32,
                                  ),
                          ),
                        ),

                        // Botón para VIDEO
                        GestureDetector(
                          onTap: _isLoading ? null : _toggleVideoRecording,
                          child: Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isRecordingVideo
                                  ? Colors.red
                                  : Colors.white.withOpacity(0.3),
                              border: Border.all(
                                color: _isRecordingVideo ? Colors.red : Colors.white,
                                width: 3,
                              ),
                            ),
                            child: _isLoading && _isRecordingVideo
                                ? Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    _isRecordingVideo
                                        ? Icons.stop
                                        : Icons.videocam,
                                    color: Colors.white,
                                    size: 32,
                                  ),
                          ),
                        ),

                        // Cambiar cámara
                        IconButton(
                          onPressed: _cameras != null && _cameras!.length > 1 && !_isRecordingVideo
                              ? _switchCamera
                              : null,
                          icon: Icon(
                            Icons.flip_camera_ios,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
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
