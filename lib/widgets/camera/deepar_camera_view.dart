import 'package:flutter/material.dart';
import '../../services/deepar_service.dart';
import '../../utils/release_logger.dart';

/// Widget separado para manejar DeepAR de forma completamente aislada
class DeepARCameraView extends StatefulWidget {
  final bool isDeepARInitialized;
  final DeepARService deepARService;
  final VoidCallback onInitialized;
  final int reinitCounter; // ✅ FIX #6: Contador para forzar recreación del platform view

  const DeepARCameraView({
    super.key,
    required this.isDeepARInitialized,
    required this.deepARService,
    required this.onInitialized,
    this.reinitCounter = 0,
  });

  @override
  State<DeepARCameraView> createState() => _DeepARCameraViewState();
}

class _DeepARCameraViewState extends State<DeepARCameraView> {
  bool _isInitializing = false;
  bool _hasInitialized = false;
  bool _cameraStarted = false;

  // IMPORTANTE: NO usar key - dejar que Flutter/iOS maneje la vista
  // La vista nativa se mantiene viva y solo cambiamos sus parámetros

  @override
  void initState() {
    super.initState();
    ReleaseLogger.log('🎬 DeepARCameraView: initState (reinit: ${widget.reinitCounter})', tag: 'DeepARCameraView');
  }

  @override
  void dispose() {
    ReleaseLogger.log('🗑️ DeepARCameraView: dispose (reinit: ${widget.reinitCounter})', tag: 'DeepARCameraView');
    // NO limpiar aquí porque el widget se recrea en cada setState del parent
    super.dispose();
  }

  void _onPlatformViewCreated(int viewId) {
    ReleaseLogger.log('🎯 DeepARCameraView: Preview creado con viewId: $viewId (reinit: ${widget.reinitCounter})', tag: 'DeepARCameraView');

    // ✅ FIX #6 (v3): Siempre iniciar la cámara cuando se crea un nuevo platform view
    // El platform view solo se crea cuando hay un nuevo key, lo que significa reinicialización
    _cameraStarted = false; // Reset para asegurar que se inicie

    if (widget.isDeepARInitialized) {
      // ✅ FIX #6 (v3): Dar tiempo suficiente para que el platform view nativo se estabilice
      // 500ms es más seguro que 300ms para asegurar que Android complete la configuración
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && widget.isDeepARInitialized && !_cameraStarted) {
          _cameraStarted = true;
          widget.deepARService.startCamera();
          ReleaseLogger.log('▶️ DeepARCameraView: Cámara iniciada después de delay (reinit: ${widget.reinitCounter})', tag: 'DeepARCameraView');
        }
      });
    }
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

    // ✅ FIX #6 (v3): Detectar cambios en reinitCounter para reiniciar la cámara
    if (widget.reinitCounter != oldWidget.reinitCounter) {
      ReleaseLogger.log(
        '🔄 DeepARCameraView: reinitCounter cambió de ${oldWidget.reinitCounter} a ${widget.reinitCounter}',
        tag: 'DeepARCameraView',
      );
      _cameraStarted = false;

      // Si DeepAR ya está inicializado, reiniciar la cámara
      if (widget.isDeepARInitialized) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && widget.isDeepARInitialized && !_cameraStarted) {
            _cameraStarted = true;
            widget.deepARService.startCamera();
            ReleaseLogger.log('▶️ DeepARCameraView: Cámara reiniciada por cambio de reinitCounter', tag: 'DeepARCameraView');
          }
        });
      }
    }

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
      ReleaseLogger.log('🎭 DeepARCameraView: Inicializando DeepAR...', tag: 'DeepARCameraView');

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
        ReleaseLogger.log('📱 Usando license key de iOS', tag: 'DeepARCameraView');
      } else if (Theme.of(context).platform == TargetPlatform.android) {
        // Usar key válida si está disponible, sino usar la de demo
        licenseKey = androidLicenseKey.contains('YOUR_VALID')
            ? androidLicenseKeyDemo
            : androidLicenseKey;
        ReleaseLogger.log('🤖 Usando license key de Android', tag: 'DeepARCameraView');
      } else {
        throw Exception('Plataforma no soportada para DeepAR');
      }

      final result = await widget.deepARService.initialize(
        licenseKey: licenseKey,
      );

      if (result && mounted) {
        widget.onInitialized();
        _cameraStarted = true; // Marcar que la cámara está iniciada
        ReleaseLogger.log('✅ DeepARCameraView: DeepAR inicializado exitosamente', tag: 'DeepARCameraView');
      } else {
        ReleaseLogger.error('❌ DeepARCameraView: Error inicializando DeepAR', tag: 'DeepARCameraView');
      }
    } catch (e) {
      ReleaseLogger.error('❌ DeepARCameraView: Excepción inicializando DeepAR: $e', tag: 'DeepARCameraView');
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
      // ✅ FIX #6: Usar ValueKey con reinitCounter para forzar recreación
      // del platform view nativo después de reinicializaciones de DeepAR.
      // Sin esto, Android puede reutilizar un platform view corrupto.
      return Center(
        child: DeepARPreview(
          key: ValueKey('deepar_preview_${widget.reinitCounter}'),
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          onPlatformViewCreated: _onPlatformViewCreated,
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
