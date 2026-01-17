import 'package:flutter/material.dart';
import 'mobile_scanner_widget.dart';

/// Tab para escanear codigos QR
///
/// Responsabilidades:
/// - Mostrar el escaner de QR
/// - Proporcionar instrucciones visuales al usuario
/// - Mostrar mensajes de error si los hay
class QRScannerTab extends StatelessWidget {
  final Function(String?) onScanned;
  final String? errorMessage;

  const QRScannerTab({
    super.key,
    required this.onScanned,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
              child: MobileScannerWidget(onScanned: onScanned),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_scanner, size: 64, color: colorScheme.primary),
                SizedBox(height: 16),
                Text(
                  'Escanea el codigo QR',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Pide a tu amigo que abra su perfil y muestre su codigo QR',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
                ),
                if (errorMessage != null) ...[
                  SizedBox(height: 16),
                  _buildErrorMessage(errorMessage!),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorMessage(String message) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red[700], fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
