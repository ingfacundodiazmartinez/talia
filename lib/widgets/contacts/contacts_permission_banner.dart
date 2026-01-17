import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

/// Banner de advertencia cuando el permiso de contactos no está otorgado
///
/// Muestra diferentes mensajes según el nivel de permiso:
/// - denied: Usuario denegó, puede volver a solicitar
/// - permanentlyDenied: Usuario denegó permanentemente, debe ir a configuración
/// - restricted: iOS - restringido por controles parentales
/// - limited: iOS - acceso limitado
///
/// NOTA: Usa FlutterContacts para verificar el permiso real en iOS,
/// ya que permission_handler tiene bugs conocidos en iOS.
///
/// Compatible con Android e iOS
class ContactsPermissionBanner extends StatefulWidget {
  /// Callback cuando el usuario solicita el permiso
  final VoidCallback? onRequestPermission;

  /// Callback cuando se detecta que el permiso cambió
  final VoidCallback? onPermissionChanged;

  const ContactsPermissionBanner({
    super.key,
    this.onRequestPermission,
    this.onPermissionChanged,
  });

  @override
  State<ContactsPermissionBanner> createState() =>
      _ContactsPermissionBannerState();
}

class _ContactsPermissionBannerState extends State<ContactsPermissionBanner>
    with WidgetsBindingObserver {
  PermissionStatus? _status;
  bool _isLoading = true;
  bool _isDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Verificar permiso cuando vuelve del settings
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    // ✅ FIX iOS: Usar FlutterContacts para verificar el permiso real
    // permission_handler tiene bugs en iOS donde retorna 'denied' incluso con acceso
    final hasFlutterContactsAccess = await FlutterContacts.requestPermission(readonly: true);

    // Obtener status de permission_handler para casos especiales (restricted, limited)
    final status = await Permission.contacts.status;
    if (!mounted) return;

    final wasGranted = _status?.isGranted ?? false;

    // ✅ El permiso está granted si FlutterContacts tiene acceso
    // O si permission_handler dice que está granted
    final isNowGranted = hasFlutterContactsAccess || status.isGranted;

    // Determinar el status efectivo
    PermissionStatus effectiveStatus;
    if (isNowGranted) {
      effectiveStatus = PermissionStatus.granted;
    } else if (status.isRestricted) {
      effectiveStatus = PermissionStatus.restricted;
    } else if (status.isLimited) {
      effectiveStatus = PermissionStatus.limited;
    } else if (status.isPermanentlyDenied) {
      effectiveStatus = PermissionStatus.permanentlyDenied;
    } else {
      effectiveStatus = PermissionStatus.denied;
    }

    setState(() {
      _status = effectiveStatus;
      _isLoading = false;
      // Si el permiso fue otorgado, ocultar el banner
      if (isNowGranted) {
        _isDismissed = true;
      }
    });

    // Notificar si el permiso cambió a granted
    if (!wasGranted && isNowGranted) {
      widget.onPermissionChanged?.call();
    }
  }

  Future<void> _handleAction() async {
    if (_status == null) return;

    if (_status!.isPermanentlyDenied || _status!.isRestricted) {
      // Ir a configuración del sistema
      await openAppSettings();
    } else if (_status!.isDenied) {
      // Solicitar permiso
      widget.onRequestPermission?.call();
      await _checkPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    // No mostrar si está cargando, ya tiene permiso, o fue descartado
    if (_isLoading || _status == null || _status!.isGranted || _isDismissed) {
      return SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final config = _getConfigForStatus(_status!);

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: config.backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: config.borderColor, width: 1),
      ),
      child: Row(
        children: [
          Icon(config.icon, color: config.iconColor, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: config.textColor,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  config.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: config.textColor.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _handleAction,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: config.actionColor,
                ),
                child: Text(
                  config.actionText,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              if (_canDismiss())
                TextButton(
                  onPressed: () => setState(() => _isDismissed = true),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: colorScheme.onSurfaceVariant,
                  ),
                  child: Text(
                    'Omitir',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool _canDismiss() {
    // Permitir omitir solo si no es permanentemente denegado
    return _status != null && !_status!.isPermanentlyDenied;
  }

  _BannerConfig _getConfigForStatus(PermissionStatus status) {
    switch (status) {
      case PermissionStatus.denied:
        return _BannerConfig(
          icon: Icons.contacts_outlined,
          title: 'Permiso de contactos',
          message:
              'Permite acceso a tus contactos para encontrar amigos y sincronizar nombres.',
          actionText: 'Permitir',
          backgroundColor: Colors.blue.shade50,
          borderColor: Colors.blue.shade200,
          iconColor: Colors.blue.shade600,
          textColor: Colors.blue.shade900,
          actionColor: Colors.blue.shade700,
        );

      case PermissionStatus.permanentlyDenied:
        return _BannerConfig(
          icon: Icons.warning_amber_rounded,
          title: 'Acceso a contactos deshabilitado',
          message:
              'Habilitalo en Configuración para sincronizar nombres de contactos.',
          actionText: 'Configuración',
          backgroundColor: Colors.orange.shade50,
          borderColor: Colors.orange.shade200,
          iconColor: Colors.orange.shade600,
          textColor: Colors.orange.shade900,
          actionColor: Colors.orange.shade700,
        );

      case PermissionStatus.restricted:
        return _BannerConfig(
          icon: Icons.lock_outline,
          title: 'Acceso restringido',
          message:
              'El acceso a contactos está restringido por configuración del dispositivo.',
          actionText: 'Configuración',
          backgroundColor: Colors.grey.shade100,
          borderColor: Colors.grey.shade300,
          iconColor: Colors.grey.shade600,
          textColor: Colors.grey.shade800,
          actionColor: Colors.grey.shade700,
        );

      case PermissionStatus.limited:
        return _BannerConfig(
          icon: Icons.info_outline,
          title: 'Acceso limitado',
          message: 'Solo algunos contactos están disponibles para sincronizar.',
          actionText: 'Configuración',
          backgroundColor: Colors.amber.shade50,
          borderColor: Colors.amber.shade200,
          iconColor: Colors.amber.shade600,
          textColor: Colors.amber.shade900,
          actionColor: Colors.amber.shade700,
        );

      default:
        return _BannerConfig(
          icon: Icons.contacts_outlined,
          title: 'Permiso de contactos',
          message: 'Se requiere permiso para sincronizar contactos.',
          actionText: 'Permitir',
          backgroundColor: Colors.blue.shade50,
          borderColor: Colors.blue.shade200,
          iconColor: Colors.blue.shade600,
          textColor: Colors.blue.shade900,
          actionColor: Colors.blue.shade700,
        );
    }
  }
}

class _BannerConfig {
  final IconData icon;
  final String title;
  final String message;
  final String actionText;
  final Color backgroundColor;
  final Color borderColor;
  final Color iconColor;
  final Color textColor;
  final Color actionColor;

  _BannerConfig({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionText,
    required this.backgroundColor,
    required this.borderColor,
    required this.iconColor,
    required this.textColor,
    required this.actionColor,
  });
}
