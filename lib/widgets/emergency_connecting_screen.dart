import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../calls_v2/screens/agora_call_screen.dart';
import '../services/emergency_service.dart';
import '../utils/release_logger.dart';

/// Pantalla optimística de emergencia que se muestra INMEDIATAMENTE
/// mientras la Cloud Function crea la llamada en background.
class EmergencyConnectingScreen extends StatefulWidget {
  final String? customMessage;

  const EmergencyConnectingScreen({
    super.key,
    this.customMessage,
  });

  @override
  State<EmergencyConnectingScreen> createState() => _EmergencyConnectingScreenState();
}

class _EmergencyConnectingScreenState extends State<EmergencyConnectingScreen> {
  final EmergencyService _emergencyService = EmergencyService();

  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isConnecting = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _createEmergencyInBackground();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      // Preferir cámara frontal
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error initializing camera: $e', tag: 'EmergencyConnecting');
    }
  }

  Future<void> _createEmergencyInBackground() async {
    try {
      ReleaseLogger.log('🆘 [OPTIMISTIC] Creando emergencia en background...', tag: 'EmergencyConnecting');

      final result = await _emergencyService.activateEmergencyOptimistic(
        customMessage: widget.customMessage,
        context: context,
      );

      if (!mounted) return;

      if (result != null && result['success'] == true) {
        final emergencyId = result['emergencyId'] as String;
        final isReactivation = result['isReactivation'] ?? false;

        ReleaseLogger.log(
          isReactivation
            ? '📞 Emergencia reactivada: $emergencyId'
            : '✅ Nueva emergencia creada: $emergencyId',
          tag: 'EmergencyConnecting',
        );

        // Disponer cámara antes de navegar (AgoraCallScreen usará su propia)
        await _cameraController?.dispose();
        _cameraController = null;

        if (!mounted) return;

        // Reemplazar esta pantalla con la pantalla de llamada real
        Navigator.of(context, rootNavigator: true).pushReplacement(
          MaterialPageRoute(
            builder: (context) => AgoraCallScreen.existing(
              callId: emergencyId,
              isIncoming: true,
            ),
          ),
        );
      } else {
        if (mounted) {
          setState(() {
            _isConnecting = false;
            _errorMessage = 'No se pudo activar la emergencia. Intenta de nuevo.';
          });
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error creando emergencia: $e', tag: 'EmergencyConnecting');
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'Error de conexión. Intenta de nuevo.';
        });
      }
    }
  }

  @override
  void dispose() {
    // Solo dispose si la cámara terminó de inicializarse
    // Evita IllegalStateException en Android
    if (_isCameraInitialized && _cameraController != null) {
      _cameraController!.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview o fondo negro
          if (_isCameraInitialized && _cameraController != null)
            CameraPreview(_cameraController!)
          else
            Container(color: Colors.black),

          // Overlay oscuro
          Container(
            color: Colors.black.withValues(alpha: 0.5),
          ),

          // Contenido
          SafeArea(
            child: Column(
              children: [
                // Header con estado de emergencia
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.emergency, color: Colors.white, size: 18),
                            SizedBox(width: 6),
                            Text(
                              'EMERGENCIA',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: Center(
                    child: _errorMessage != null
                        ? _buildErrorState()
                        : _buildConnectingState(),
                  ),
                ),

                // Botón cancelar (solo si hay error)
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Volver',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectingState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Animación de pulso
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.8, end: 1.2),
          duration: Duration(milliseconds: 800),
          curve: Curves.easeInOut,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red.withValues(alpha: 0.3),
                ),
                child: Center(
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red,
                    ),
                    child: Icon(
                      Icons.phone,
                      color: Colors.white,
                      size: 35,
                    ),
                  ),
                ),
              ),
            );
          },
          onEnd: () {
            // Reiniciar animación
            if (mounted && _isConnecting) {
              setState(() {});
            }
          },
        ),
        SizedBox(height: 30),
        Text(
          'Conectando...',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 10),
        Text(
          'Notificando a tus padres',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 16,
          ),
        ),
        SizedBox(height: 30),
        SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 3,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withValues(alpha: 0.2),
          ),
          child: Icon(
            Icons.error_outline,
            color: Colors.red,
            size: 50,
          ),
        ),
        SizedBox(height: 20),
        Text(
          'Error',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
            ),
          ),
        ),
      ],
    );
  }
}
