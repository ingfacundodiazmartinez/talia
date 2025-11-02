import 'package:flutter/material.dart';
import '../../services/deepar_service.dart';

/// Widget separado para manejar DeepAR de forma completamente aislada
class DeepARCameraView extends StatefulWidget {
  final bool isDeepARInitialized;
  final DeepARService deepARService;
  final VoidCallback onInitialized;

  const DeepARCameraView({
    super.key,
    required this.isDeepARInitialized,
    required this.deepARService,
    required this.onInitialized,
  });

  @override
  State<DeepARCameraView> createState() => _DeepARCameraViewState();
}

class _DeepARCameraViewState extends State<DeepARCameraView> {
  bool _isInitializing = false;
  bool _hasInitialized = false;
  bool _cameraStarted = false; // Nuevo flag para evitar reinicios innecesarios

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
    // Inicializar si aún no se ha hecho
    if (!widget.isDeepARInitialized && !_isInitializing && !_hasInitialized) {
      _initializeDeepAR();
    }
  }

  @override
  void didUpdateWidget(DeepARCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Inicializar si aún no se ha hecho
    if (!widget.isDeepARInitialized && !_isInitializing && !_hasInitialized) {
      _initializeDeepAR();
    }
  }

  Future<void> _initializeDeepAR() async {
    if (_isInitializing || _hasInitialized) return;

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
        _cameraStarted = true; // Marcar que la cámara está iniciada
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
      // ✅ ARREGLADO: Usar aspecto ratio de cámara (4:3) en lugar de pantalla
      // Esto evita la distorsión del preview de DeepAR
      const double cameraAspectRatio = 4.0 / 3.0; // Ratio típico de cámara móvil
      final screenWidth = MediaQuery.of(context).size.width;
      final cameraHeight = screenWidth / cameraAspectRatio;

      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: screenWidth,
          height: cameraHeight,
          child: DeepARPreview(
            width: screenWidth,
            height: cameraHeight,
            onPlatformViewCreated: _onPlatformViewCreated,
          ),
        ),
      );
    }

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
                  ? 'Inicializando DeepAR...'
                  : 'Preparando DeepAR...',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
