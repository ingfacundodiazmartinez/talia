import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Controllers
import '../controllers/add_contact_controller.dart';

// Services (still needed for some methods)
import '../services/user_code_service.dart';
import '../services/contact_request_service.dart';

// Widgets
import 'add_contact/widgets/my_code_tab.dart';
import 'add_contact/widgets/qr_scanner_tab.dart';
import 'add_contact/widgets/manual_code_tab.dart';
import 'add_contact/widgets/confirm_contact_dialog.dart';

/// Screen para agregar contactos
///
/// Responsabilidades:
/// - Mostrar 3 tabs: Mi Codigo, Escanear, Ingresar
/// - Gestionar la carga del codigo del usuario
/// - Coordinar el flujo de agregar contactos
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _codeController = TextEditingController();

  // Controller
  late AddContactController _controller;

  // Services (still needed for some direct calls)
  final UserCodeService _userCodeService = UserCodeService();
  final ContactRequestService _contactRequestService = ContactRequestService();

  // State
  bool _isLoading = false;
  String? _errorMessage;
  String? _userCode;
  DateTime? _codeExpiresAt;
  bool _isLoadingMyCode = true;

  @override
  void initState() {
    super.initState();
    _controller = AddContactController();
    _tabController = TabController(length: 3, vsync: this);
    _loadUserCode();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadUserCode() async {
    try {
      final result = await _controller.getCurrentUserCode();
      if (!mounted) return;
      setState(() {
        _userCode = result.code;
        _codeExpiresAt = result.expiresAt;
        _isLoadingMyCode = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingMyCode = false;
      });
    }
  }

  void _copyCode() {
    if (_userCode != null) {
      Clipboard.setData(ClipboardData(text: _userCode!));
    }
  }

  void _shareCode() {
    if (_userCode != null) {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';
      final deepLink = 'https://taliachat.com/add/$currentUserId';
      Share.share(
        'Agregame como contacto en Talia!\n\n'
        'Haz click aqui: $deepLink\n\n'
        'O usa mi codigo: $_userCode',
        subject: 'Agregame en Talia',
      );
    }
  }

  Future<void> _regenerateCode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Regenerar Codigo'),
        content: Text(
          'Estas seguro de que quieres generar un nuevo codigo? Tu codigo actual dejara de funcionar.',
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
        _isLoadingMyCode = true;
      });

      try {
        final result = await _controller.regenerateCurrentUserCode();
        setState(() {
          _userCode = result.code;
          _codeExpiresAt = result.expiresAt;
          _isLoadingMyCode = false;
        });
      } catch (e) {
        setState(() {
          _isLoadingMyCode = false;
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error regenerando codigo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Contactos'),
        actions: [
          if (_tabController.index == 0 && _userCode != null)
            Builder(
              builder: (BuildContext context) {
                return PopupMenuButton<String>(
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
                      Text('Copiar codigo'),
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
                      Icon(Icons.refresh, size: 20, color: Colors.orange),
                      SizedBox(width: 8),
                      Text('Regenerar', style: TextStyle(color: Colors.orange)),
                    ],
                  ),
                ),
              ],
                );
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: [
            Tab(icon: Icon(Icons.qr_code), text: 'Mi Codigo'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Escanear'),
            Tab(icon: Icon(Icons.keyboard), text: 'Ingresar'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          MyCodeTab(
            userCode: _userCode,
            expiresAt: _codeExpiresAt,
            isLoading: _isLoadingMyCode,
            onRetry: _loadUserCode,
            onCopy: _copyCode,
            onShare: _shareCode,
            onRegenerate: _regenerateCode,
          ),
          QRScannerTab(
            onScanned: _handleQRScanned,
            errorMessage: _errorMessage,
          ),
          ManualCodeTab(
            codeController: _codeController,
            isLoading: _isLoading,
            onSubmit: _handleManualCode,
            onChanged: (value) {
              setState(() {
                _errorMessage = null;
              });
            },
            errorMessage: _errorMessage,
          ),
        ],
      ),
    );
  }

  void _handleQRScanned(String? code) {
    if (code != null && code.isNotEmpty) {
      _processContactCode(code);
    }
  }

  void _handleManualCode() {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Por favor introduce un codigo';
      });
      return;
    }

    if (!_userCodeService.isValidCodeFormat(code)) {
      setState(() {
        _errorMessage = 'Formato de codigo invalido. Debe ser TALIA-ABC123';
      });
      return;
    }

    _processContactCode(code);
  }

  Future<void> _processContactCode(String code) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Buscar usuario por codigo
      final result = await _userCodeService.findUserByCode(code);

      if (!result.isFound) {
        setState(() {
          _errorMessage = result.hasError
              ? result.error!
              : 'Codigo no encontrado. Verifica que este correcto.';
        });
        return;
      }

      // Validar que no sea el mismo usuario
      final validationError = await _contactRequestService.validateContactCode(
        targetUserId: result.userId!,
        currentUserId: _controller.currentUserId!,
      );

      if (validationError != null) {
        setState(() {
          _errorMessage = validationError;
        });
        return;
      }

      // Obtener informacion de rol del usuario actual
      final roleInfo = await _contactRequestService.getCurrentUserRoleInfo(
        _controller.currentUserId!,
      );

      if (roleInfo == null) {
        setState(() {
          _errorMessage = 'Error obteniendo informacion del usuario';
        });
        return;
      }

      // Mostrar confirmacion
      final confirmed = await showConfirmContactDialog(
        context: context,
        contactInfo: result,
        isAdultOrParent: roleInfo.isAdultOrParent,
      );

      if (confirmed) {
        await _sendContactRequest(result);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error procesando codigo: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _sendContactRequest(UserCodeResult result) async {
    try {
      final requestResult = await _contactRequestService.sendContactRequest(
        contactUserId: result.userId!,
        currentUserId: _controller.currentUserId!,
        currentUserName: _controller.currentUserDisplayName,
        currentUserEmail: _controller.currentUserEmail,
        contactName: result.name ?? 'Usuario',
        contactEmail: result.email ?? '',
      );

      if (!mounted) return;

      Navigator.pop(context);

      if (!requestResult.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error enviando solicitud: ${requestResult.errorMessage}'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Solicitud enviada - sin mensaje de confirmación
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error enviando solicitud: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
