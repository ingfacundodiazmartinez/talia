import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/user_code_service.dart';
import '../services/user_role_service.dart';

class MyCodeScreen extends StatefulWidget {
  const MyCodeScreen({super.key});

  @override
  State<MyCodeScreen> createState() => _MyCodeScreenState();
}

class _MyCodeScreenState extends State<MyCodeScreen> {
  final UserCodeService _userCodeService = UserCodeService();
  final UserRoleService _userRoleService = UserRoleService();
  String? _userCode;
  DateTime? _expiresAt;
  Timer? _countdownTimer;
  Duration _timeRemaining = Duration.zero;
  bool _isLoading = true;
  String? _errorMessage;
  String? _userRole;
  bool _hasLinkedParent = false;

  static const String _deepLinkBaseUrl = 'https://taliachat.com/add/';

  @override
  void initState() {
    super.initState();
    _loadUserCode();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();

    if (_expiresAt == null) {
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
    if (_expiresAt == null) return;

    final now = DateTime.now();
    final remaining = _expiresAt!.difference(now);

    setState(() {
      _timeRemaining = remaining.isNegative ? Duration.zero : remaining;
    });

    // Si expiró, auto-regenerar
    if (remaining.isNegative) {
      _countdownTimer?.cancel();
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

  bool get _isExpired => _timeRemaining.inSeconds <= 0;

  Future<void> _loadUserCode() async {
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) {
        setState(() {
          _errorMessage = 'Usuario no autenticado';
          _isLoading = false;
        });
        return;
      }

      // Cargar código, rol y estado de vinculación en paralelo
      final results = await Future.wait([
        _userCodeService.getCurrentUserCode(),
        _loadUserRole(userId),
        _userRoleService.hasParentLink(userId),
      ]);

      final codeResult = results[0] as ({String code, DateTime? expiresAt});
      setState(() {
        _userCode = codeResult.code;
        _expiresAt = codeResult.expiresAt;
        _userRole = results[1] as String?;
        _hasLinkedParent = results[2] as bool;
        _isLoading = false;
      });
      _startCountdownTimer();
    } catch (e) {
      setState(() {
        _errorMessage = 'Error cargando código: $e';
        _isLoading = false;
      });
    }
  }

  Future<String?> _loadUserRole(String userId) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      return userDoc.data()?['role'] as String?;
    } catch (e) {
      return null;
    }
  }

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get _deepLink => '$_deepLinkBaseUrl$_currentUserId';

  bool get _shouldShowSecurityWarning {
    // Solo mostrar para usuarios 'child' con un padre vinculado
    return _userRole == 'child' && _hasLinkedParent;
  }

  Future<void> _regenerateCode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Regenerar Código'),
        content: Text(
          '¿Estás seguro de que quieres generar un nuevo código? Tu código actual dejará de funcionar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: Text('Regenerar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      try {
        final result = await _userCodeService.regenerateUserCode(
          FirebaseAuth.instance.currentUser!.uid,
        );
        setState(() {
          _userCode = result.code;
          _expiresAt = result.expiresAt;
          _isLoading = false;
        });
        _startCountdownTimer();
      } catch (e) {
        setState(() {
          _errorMessage = 'Error regenerando código: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _copyCode() {
    if (_userCode != null) {
      Clipboard.setData(ClipboardData(text: _userCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📋 Código copiado al portapapeles'),
          backgroundColor: Colors.blue,
        ),
      );
    }
  }

  void _shareCode() {
    if (_userCode != null) {
      Share.share(
        '¡Agrégame en Talia!\n\n'
        'Haz clic en este enlace para agregarme como contacto:\n'
        '$_deepLink\n\n'
        'O usa mi código: $_userCode',
        subject: 'Agrégame en Talia',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Código'),
        actions: [
          if (_userCode != null)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'copy':
                    _copyCode();
                    break;
                  case 'share':
                    _shareCode();
                    break;
                  case 'regenerate':
                    _regenerateCode();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'copy',
                  child: Row(
                    children: [
                      Icon(Icons.copy, size: 20),
                      SizedBox(width: 8),
                      Text('Copiar código'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'share',
                  child: Row(
                    children: [
                      Icon(Icons.share, size: 20),
                      SizedBox(width: 8),
                      Text('Compartir'),
                    ],
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'regenerate',
                  child: Row(
                    children: [
                      Icon(Icons.refresh, size: 20, color: Colors.orange[700]),
                      SizedBox(width: 8),
                      Text('Regenerar', style: TextStyle(color: Colors.orange[700])),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? _buildErrorState()
          : _buildCodeDisplay(),
    );
  }

  Widget _buildErrorState() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            SizedBox(height: 16),
            Text(
              'Error',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.error,
              ),
            ),
            SizedBox(height: 8),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            SizedBox(height: 24),
            ElevatedButton(onPressed: _loadUserCode, child: Text('Reintentar')),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeDisplay() {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          // Información introductoria
          Container(
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
                    'Comparte este código con tus amigos para que puedan agregarte como contacto',
                    style: TextStyle(color: colorScheme.onPrimaryContainer, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 16),

          // Countdown banner
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _getExpirationColor().withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _getExpirationColor().withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isExpired ? Icons.timer_off : Icons.timer,
                  color: _getExpirationColor(),
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  _isExpired ? 'Codigo expirado' : 'Expira en: ${_formatTimeRemaining()}',
                  style: TextStyle(
                    color: _getExpirationColor(),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (_isExpired) ...[
                  SizedBox(width: 12),
                  TextButton(
                    onPressed: _regenerateCode,
                    style: TextButton.styleFrom(
                      foregroundColor: _getExpirationColor(),
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: Text('Regenerar'),
                  ),
                ],
              ],
            ),
          ),

          SizedBox(height: 24),

          // Código QR
          Container(
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
                  'Código QR',
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
                        opacity: _isExpired ? 0.3 : 1.0,
                        child: QrImageView(
                          data: _userCode!,
                          version: QrVersions.auto,
                          size: 200.0,
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ),
                    if (_isExpired)
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
          ),

          SizedBox(height: 24),

          // Código de texto
          Container(
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
                  'Código de Texto',
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
                    color: _isExpired
                        ? Colors.grey.withValues(alpha: 0.2)
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isExpired
                          ? Colors.grey
                          : colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _userCode!,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Courier',
                          color: _isExpired ? Colors.grey : colorScheme.primary,
                          letterSpacing: 2,
                          decoration: _isExpired ? TextDecoration.lineThrough : null,
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
          ),

          SizedBox(height: 32),

          // Botones de acción
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isExpired ? null : _copyCode,
                  icon: Icon(Icons.copy),
                  label: Text('Copiar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.primary,
                    side: BorderSide(color: _isExpired ? Colors.grey : colorScheme.primary),
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
                  onPressed: _isExpired ? null : _shareCode,
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
          ),

          // Información de seguridad - solo para usuarios child con padre vinculado
          if (_shouldShowSecurityWarning) ...[
            SizedBox(height: 16),
            Container(
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
                      Icon(Icons.security, color: Colors.orange[700], size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Información de Seguridad',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange[800],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Solo comparte tu código con personas que conoces\n'
                    '• Tus padres deben aprobar cada contacto\n'
                    '• Puedes regenerar tu código en cualquier momento',
                    style: TextStyle(color: Colors.orange[700], fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
