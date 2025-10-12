import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// Widget para mostrar el código QR y de texto del usuario
///
/// Responsabilidades:
/// - Mostrar código QR generado
/// - Mostrar código de texto
/// - Proveer opciones de copiar y compartir
/// - Mostrar información de seguridad
class MyCodeTab extends StatelessWidget {
  final String? userCode;
  final bool isLoading;
  final VoidCallback onRetry;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  const MyCodeTab({
    super.key,
    required this.userCode,
    required this.isLoading,
    required this.onRetry,
    required this.onCopy,
    required this.onShare,
  });

  void _handleCopy(BuildContext context) {
    if (userCode != null) {
      Clipboard.setData(ClipboardData(text: userCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Codigo copiado al portapapeles'),
          backgroundColor: Colors.blue,
        ),
      );
    }
    onCopy();
  }

  void _handleShare() {
    if (userCode != null) {
      Share.share(
        'Mi codigo de Talia es: $userCode\n\nUsalo para agregarme como contacto.',
        subject: 'Mi codigo de Talia',
      );
    }
    onShare();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (userCode == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: colorScheme.error),
              SizedBox(height: 16),
              Text(
                'Error cargando codigo',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
              SizedBox(height: 24),
              ElevatedButton(
                onPressed: onRetry,
                child: Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          _buildInfoBanner(colorScheme),
          SizedBox(height: 32),
          _buildQRCodeCard(colorScheme),
          SizedBox(height: 24),
          _buildTextCodeCard(colorScheme),
          SizedBox(height: 32),
          _buildActionButtons(context, colorScheme),
          SizedBox(height: 16),
          _buildSecurityInfo(),
        ],
      ),
    );
  }

  Widget _buildInfoBanner(ColorScheme colorScheme) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colorScheme.primary, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Comparte este codigo con tus amigos para que puedan agregarte como contacto',
              style: TextStyle(color: colorScheme.onPrimaryContainer, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQRCodeCard(ColorScheme colorScheme) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            'Codigo QR',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.outline),
            ),
            child: QrImageView(
              data: userCode!,
              version: QrVersions.auto,
              size: 200.0,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Pide a tu amigo que escanee este codigo',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildTextCodeCard(ColorScheme colorScheme) {
    return Container(
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            'Codigo de Texto',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  userCode!,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Courier',
                    color: colorScheme.primary,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 16),
          Text(
            'O compartelo escribiendolo manualmente',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, ColorScheme colorScheme) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _handleCopy(context),
            icon: Icon(Icons.copy),
            label: Text('Copiar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.primary,
              side: BorderSide(color: colorScheme.primary),
              padding: EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        SizedBox(width: 16),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _handleShare,
            icon: Icon(Icons.share),
            label: Text('Compartir'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              padding: EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSecurityInfo() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.security, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Text(
                'Informacion de Seguridad',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.orange[800],
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '• Solo comparte tu codigo con personas que conoces\n'
            '• Tus padres deben aprobar cada contacto\n'
            '• Puedes regenerar tu codigo en cualquier momento',
            style: TextStyle(color: Colors.orange[700], fontSize: 12),
          ),
        ],
      ),
    );
  }
}
