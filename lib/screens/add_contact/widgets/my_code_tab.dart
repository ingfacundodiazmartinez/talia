import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Widget para mostrar el código QR y de texto del usuario
///
/// Responsabilidades:
/// - Mostrar código QR generado
/// - Mostrar código de texto
/// - Proveer opciones de copiar y compartir
/// - Mostrar countdown de expiración
/// - Auto-regenerar cuando el código expira
class MyCodeTab extends StatefulWidget {
  final String? userCode;
  final DateTime? expiresAt;
  final bool isLoading;
  final VoidCallback onRetry;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback? onRegenerate;
  final bool showSecurityWarning;

  static const String _deepLinkBaseUrl = 'https://taliachat.com/add/';

  const MyCodeTab({
    super.key,
    required this.userCode,
    this.expiresAt,
    required this.isLoading,
    required this.onRetry,
    required this.onCopy,
    required this.onShare,
    this.onRegenerate,
    this.showSecurityWarning = false,
  });

  @override
  State<MyCodeTab> createState() => _MyCodeTabState();
}

class _MyCodeTabState extends State<MyCodeTab> {
  Timer? _countdownTimer;
  Duration _timeRemaining = Duration.zero;

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _deepLink => '${MyCodeTab._deepLinkBaseUrl}$_currentUserId';

  @override
  void initState() {
    super.initState();
    _startCountdownTimer();
  }

  @override
  void didUpdateWidget(MyCodeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) {
      _startCountdownTimer();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();

    if (widget.expiresAt == null) {
      setState(() {
        _timeRemaining = Duration.zero;
      });
      return;
    }

    _updateTimeRemaining();

    _countdownTimer = Timer.periodic(Duration(seconds: 1), (_) {
      _updateTimeRemaining();
    });
  }

  void _updateTimeRemaining() {
    if (widget.expiresAt == null) return;

    final now = DateTime.now();
    final remaining = widget.expiresAt!.difference(now);

    setState(() {
      _timeRemaining = remaining.isNegative ? Duration.zero : remaining;
    });

    // Si expiró, auto-regenerar
    if (remaining.isNegative && widget.onRegenerate != null) {
      _countdownTimer?.cancel();
      widget.onRegenerate!();
    }
  }

  String _formatTimeRemaining() {
    if (_timeRemaining.inSeconds <= 0) return 'Expirado';

    final minutes = _timeRemaining.inMinutes;
    final seconds = _timeRemaining.inSeconds.remainder(60);
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  Color _getExpirationColor() {
    if (_timeRemaining.inSeconds <= 0) return Colors.red;
    if (_timeRemaining.inMinutes < 1) return Colors.orange;
    return Colors.green;
  }

  void _handleCopy(BuildContext context) {
    if (widget.userCode != null) {
      Clipboard.setData(ClipboardData(text: widget.userCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Codigo copiado al portapapeles'),
          backgroundColor: Colors.blue,
        ),
      );
    }
    widget.onCopy();
  }

  void _handleShare() {
    if (widget.userCode != null) {
      Share.share(
        'Agregame como contacto en Talia!\n\n'
        'Haz click aqui: $_deepLink\n\n'
        'O usa mi codigo: ${widget.userCode}',
        subject: 'Agregame en Talia',
      );
    }
    widget.onShare();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (widget.isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (widget.userCode == null) {
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
                onPressed: widget.onRetry,
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
          _buildExpirationBanner(colorScheme),
          SizedBox(height: 16),
          _buildInfoBanner(colorScheme),
          SizedBox(height: 24),
          _buildQRCodeCard(colorScheme),
          SizedBox(height: 24),
          _buildTextCodeCard(colorScheme),
          SizedBox(height: 32),
          _buildActionButtons(context, colorScheme),
          if (widget.showSecurityWarning) ...[
            SizedBox(height: 16),
            _buildSecurityInfo(),
          ],
        ],
      ),
    );
  }

  Widget _buildExpirationBanner(ColorScheme colorScheme) {
    final expirationColor = _getExpirationColor();
    final isExpired = _timeRemaining.inSeconds <= 0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: expirationColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: expirationColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isExpired ? Icons.timer_off : Icons.timer,
            color: expirationColor,
            size: 20,
          ),
          SizedBox(width: 8),
          Text(
            isExpired ? 'Codigo expirado' : 'Expira en: ${_formatTimeRemaining()}',
            style: TextStyle(
              color: expirationColor,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          if (isExpired && widget.onRegenerate != null) ...[
            SizedBox(width: 12),
            TextButton(
              onPressed: widget.onRegenerate,
              style: TextButton.styleFrom(
                foregroundColor: expirationColor,
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: Text('Regenerar'),
            ),
          ],
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
    final isExpired = _timeRemaining.inSeconds <= 0;

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
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outline),
                ),
                child: Opacity(
                  opacity: isExpired ? 0.3 : 1.0,
                  child: QrImageView(
                    data: widget.userCode!,
                    version: QrVersions.auto,
                    size: 200.0,
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
              if (isExpired)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'EXPIRADO',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
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
    final isExpired = _timeRemaining.inSeconds <= 0;

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
              color: isExpired
                  ? Colors.grey.withValues(alpha: 0.2)
                  : colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isExpired
                    ? Colors.grey
                    : colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.userCode!,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Courier',
                    color: isExpired ? Colors.grey : colorScheme.primary,
                    letterSpacing: 2,
                    decoration: isExpired ? TextDecoration.lineThrough : null,
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
    final isExpired = _timeRemaining.inSeconds <= 0;

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: isExpired ? null : () => _handleCopy(context),
            icon: Icon(Icons.copy),
            label: Text('Copiar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.primary,
              side: BorderSide(color: isExpired ? Colors.grey : colorScheme.primary),
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
            onPressed: isExpired ? null : _handleShare,
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
            '• El codigo expira en 5 minutos por seguridad',
            style: TextStyle(color: Colors.orange[700], fontSize: 12),
          ),
        ],
      ),
    );
  }
}
