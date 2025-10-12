import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'qr_scanner_overlay_shape.dart';

/// Widget para el escaner QR usando mobile_scanner
///
/// Responsabilidades:
/// - Gestionar permisos de camara
/// - Escanear codigos QR
/// - Mostrar overlay visual para guiar al usuario
/// - Notificar al padre cuando se escanea un codigo
class MobileScannerWidget extends StatefulWidget {
  final Function(String?) onScanned;

  const MobileScannerWidget({super.key, required this.onScanned});

  @override
  State<MobileScannerWidget> createState() => _MobileScannerWidgetState();
}

class _MobileScannerWidgetState extends State<MobileScannerWidget> {
  MobileScannerController controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    // Sin mensaje de permiso
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MobileScanner(controller: controller, onDetect: _onDetect),
        // Overlay personalizado
        Container(
          decoration: ShapeDecoration(
            shape: QrScannerOverlayShape(
              borderColor: Color(0xFF9D7FE8),
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

  void _onDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;

    if (!_hasScanned && barcodes.isNotEmpty) {
      final barcode = barcodes.first;
      if (barcode.rawValue != null) {
        _hasScanned = true;
        controller.stop();
        widget.onScanned(barcode.rawValue);

        // Resetear despues de un momento para permitir escanear otro codigo
        Future.delayed(Duration(seconds: 2), () {
          if (mounted) {
            _hasScanned = false;
            controller.start();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
