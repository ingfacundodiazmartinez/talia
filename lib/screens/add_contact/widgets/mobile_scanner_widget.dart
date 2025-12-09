import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'qr_scanner_overlay_shape.dart';

/// Widget para el escaner QR usando mobile_scanner
///
/// En iOS: Muestra la cámara DIRECTAMENTE y deja que iOS maneje el diálogo de permisos nativo
/// En Android: Verifica permisos antes de mostrar la cámara
class MobileScannerWidget extends StatefulWidget {
  final Function(String?) onScanned;

  const MobileScannerWidget({super.key, required this.onScanned});

  @override
  State<MobileScannerWidget> createState() => _MobileScannerWidgetState();
}

class _MobileScannerWidgetState extends State<MobileScannerWidget> {
  // Controller se crea inmediatamente para iOS
  late MobileScannerController _controller;
  bool _hasScanned = false;

  // Solo usado para Android
  bool _isCheckingPermission = false;
  bool _hasPermission = true; // Default true para iOS
  bool _isPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();

    // Solo en Android verificamos permisos antes
    if (!Platform.isIOS) {
      _checkAndroidPermissions();
    }
  }

  /// Solo para Android: Verifica permisos antes de mostrar la cámara
  Future<void> _checkAndroidPermissions() async {
    setState(() => _isCheckingPermission = true);

    var status = await Permission.camera.status;

    if (status.isRestricted || status.isDenied) {
      status = await Permission.camera.request();
    }

    if (!mounted) return;

    if (status.isPermanentlyDenied) {
      setState(() {
        _isPermanentlyDenied = true;
        _hasPermission = false;
        _isCheckingPermission = false;
      });
      return;
    }

    setState(() {
      _hasPermission = status.isGranted;
      _isCheckingPermission = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Solo para Android: Mostrar loading mientras verificamos permisos
    if (!Platform.isIOS && _isCheckingPermission) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF9D7FE8),
        ),
      );
    }

    // Solo para Android: Mostrar UI de error si el permiso fue denegado
    if (!Platform.isIOS && (_isPermanentlyDenied || !_hasPermission)) {
      return _buildPermissionDeniedUI();
    }

    // iOS: Mostrar scanner directamente - iOS maneja los permisos
    // Android: Mostrar scanner después de confirmar permisos
    return Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) {
            // iOS: Si hay error de permisos, mostrar UI para ir a configuración
            // Esto se activa cuando el usuario deniega el permiso en el diálogo nativo
            if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
              return _buildPermissionDeniedUI();
            }

            // Otros errores del scanner
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'Error al iniciar cámara',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error.errorDetails?.message ?? 'Por favor, intenta de nuevo.',
                      style: TextStyle(color: Colors.grey[600]),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        _controller.start();
                      },
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        // Overlay personalizado
        Container(
          decoration: ShapeDecoration(
            shape: QrScannerOverlayShape(
              borderColor: const Color(0xFF9D7FE8),
              borderRadius: 10,
              borderLength: 30,
              borderWidth: 10,
              cutOutSize: 250,
            ),
          ),
        ),
      ],
    );
  }

  /// UI cuando el permiso de cámara fue denegado
  Widget _buildPermissionDeniedUI() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Permiso de cámara necesario',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Para escanear códigos QR necesitas permitir el acceso a la cámara.',
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => openAppSettings(),
              child: const Text('Abrir Configuración'),
            ),
          ],
        ),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;

    if (!_hasScanned && barcodes.isNotEmpty) {
      final barcode = barcodes.first;
      if (barcode.rawValue != null) {
        _hasScanned = true;
        _controller.stop();
        widget.onScanned(barcode.rawValue);

        // Resetear despues de un momento para permitir escanear otro codigo
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            _hasScanned = false;
            _controller.start();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
