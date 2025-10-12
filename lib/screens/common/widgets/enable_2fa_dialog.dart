import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../services/two_factor_auth_service.dart';

/// Widget para el flujo de habilitación de 2FA
class Enable2FADialog extends StatefulWidget {
  final VoidCallback onComplete;

  const Enable2FADialog({super.key, required this.onComplete});

  @override
  State<Enable2FADialog> createState() => _Enable2FADialogState();
}

class _Enable2FADialogState extends State<Enable2FADialog> {
  final _twoFactorService = TwoFactorAuthService();
  final _auth = FirebaseAuth.instance;
  final _codeController = TextEditingController();

  int _step = 1; // 1: QR Code, 2: Verificación, 3: Códigos de recuperación
  bool _isLoading = false;
  String? _secret;
  String? _qrCodeUri;
  List<String>? _recoveryCodes;

  @override
  void initState() {
    super.initState();
    print('🔐 Enable2FADialog initState llamado');
    // Ejecutar después de que el widget esté construido
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _generateSecretAndQR();
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// Genera el secreto y QR al iniciar
  Future<void> _generateSecretAndQR() async {
    print('🔐 Generando secreto y QR...');
    setState(() => _isLoading = true);

    try {
      print('🔐 Generando secreto TOTP...');
      _secret = _twoFactorService.generateSecret();
      print('✅ Secreto generado: ${_secret?.substring(0, 8)}...');

      print('🔐 Generando URI de QR...');
      final userIdentifier = _auth.currentUser?.email ??
                            _auth.currentUser?.phoneNumber ??
                            _auth.currentUser?.uid ??
                            'Usuario Talia';
      print('📱 Identificador de usuario: $userIdentifier');

      _qrCodeUri = _twoFactorService.generateQRCodeUri(
        secret: _secret!,
        email: userIdentifier,
      );
      print('✅ QR URI generado: ${_qrCodeUri?.substring(0, 30)}...');

      print('🔐 Generando códigos de recuperación...');
      _recoveryCodes = _twoFactorService.generateRecoveryCodes();
      print('✅ ${_recoveryCodes?.length} códigos generados');

      print('✅ 2FA setup completado exitosamente');
    } catch (e, stackTrace) {
      print('❌ Error generando datos 2FA: $e');
      print('Stack trace: $stackTrace');

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al generar código QR: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print('🔐 Enable2FADialog build - step: $_step, loading: $_isLoading');
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !(_isLoading && _step == 1),
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.verified_user, color: colorScheme.primary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                _isLoading && _step == 1
                    ? 'Configurando 2FA'
                    : _step == 1
                        ? 'Escanea el código QR'
                        : _step == 2
                            ? 'Verifica el código'
                            : 'Códigos de Recuperación',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 400,
            maxHeight: 600,
          ),
          child: SingleChildScrollView(
            child: _buildStepContent(),
          ),
        ),
        actions: _isLoading && _step == 1 ? [] : _buildActions(colorScheme),
      ),
    );
  }

  Widget _buildStepContent() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading && _step == 1) {
      return Container(
        padding: EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: colorScheme.primary,
              strokeWidth: 3,
            ),
            SizedBox(height: 24),
            Text(
              'Preparando autenticación...',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Esto tomará solo unos segundos',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    switch (_step) {
      case 1:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Añade una capa extra de seguridad a tu cuenta',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Escanea este código QR con tu app de autenticación:',
              style: TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              '(Google Authenticator, Authy, Microsoft Authenticator, etc.)',
              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: SizedBox(
                width: 200,
                height: 200,
                child: QrImageView(
                  data: _qrCodeUri ?? '',
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    '¿No puedes escanear?',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Clave manual:',
                    style: TextStyle(fontSize: 11),
                  ),
                  SizedBox(height: 4),
                  SelectableText(
                    _secret ?? '',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _secret ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Clave copiada al portapapeles'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: Icon(Icons.copy, size: 16),
                    label: Text('Copiar clave', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
        );

      case 2:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ingresa el código de 6 dígitos que aparece en tu app de autenticación:',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              enabled: !_isLoading,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
              decoration: InputDecoration(
                hintText: '000000',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                counterText: '',
              ),
            ),
          ],
        );

      case 3:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '¡IMPORTANTE! Guarda estos códigos en un lugar seguro.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange[800],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Códigos de recuperación:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              'Usa estos códigos si pierdes acceso a tu app de autenticación. Cada código solo se puede usar una vez.',
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...(_recoveryCodes ?? []).map((code) => Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          code,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )),
                ],
              ),
            ),
            SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                final allCodes = (_recoveryCodes ?? []).join('\n');
                Clipboard.setData(ClipboardData(text: allCodes));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Códigos copiados al portapapeles'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: Icon(Icons.copy),
              label: Text('Copiar todos los códigos'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );

      default:
        return SizedBox.shrink();
    }
  }

  List<Widget> _buildActions(ColorScheme colorScheme) {
    if (_step == 3) {
      return [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            widget.onComplete();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
          child: Text('¡Entendido!'),
        ),
      ];
    }

    return [
      if (_step > 1)
        TextButton(
          onPressed: _isLoading
              ? null
              : () {
                  setState(() => _step--);
                },
          child: Text('Atrás'),
        ),
      if (_step < 2)
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancelar'),
        ),
      ElevatedButton(
        onPressed: _isLoading ? null : _handleNextStep,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
        ),
        child: _isLoading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(_step == 2 ? 'Verificar' : 'Siguiente'),
      ),
    ];
  }

  Future<void> _handleNextStep() async {
    setState(() => _isLoading = true);

    try {
      switch (_step) {
        case 1:
          // Ir al paso de verificación
          setState(() => _step = 2);
          break;
        case 2:
          await _verifyCodeAndEnable2FA();
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _verifyCodeAndEnable2FA() async {
    if (_codeController.text.length != 6) {
      throw Exception('Por favor ingresa un código de 6 dígitos');
    }

    final isValid = _twoFactorService.verifyTOTPCode(
      _secret!,
      _codeController.text,
    );

    if (!isValid) {
      throw Exception('Código incorrecto. Por favor intenta nuevamente.');
    }

    // Habilitar 2FA
    await _twoFactorService.enable2FA(
      userId: _auth.currentUser!.uid,
      secret: _secret!,
      recoveryCodes: _recoveryCodes!,
    );

    // Log evento de seguridad
    await _twoFactorService.logSecurityEvent(
      userId: _auth.currentUser!.uid,
      eventType: '2fa_enabled',
      description: 'Usuario habilitó autenticación de dos factores',
    );

    setState(() => _step = 3);
  }
}
