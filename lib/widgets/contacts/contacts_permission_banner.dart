import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../../services/device_contact_name_cache.dart';

/// Banner de advertencia cuando el permiso de contactos no está otorgado
///
/// Muestra diferentes mensajes según el nivel de permiso:
/// - denied: Usuario denegó, puede volver a solicitar
/// - permanentlyDenied: Usuario denegó permanentemente, debe ir a configuración
/// - restricted: iOS - restringido por controles parentales
/// - limited: iOS - acceso limitado
///
/// Usa permission_handler para verificar estado sin mostrar diálogos.
/// Compatible con Android e iOS
class ContactsPermissionBanner extends StatefulWidget {
  /// Callback cuando el usuario solicita el permiso
  final VoidCallback? onRequestPermission;

  /// Callback cuando se detecta que el permiso cambió
  final VoidCallback? onPermissionChanged;

  /// Mostrar información de debug
  final bool showDebug;

  const ContactsPermissionBanner({
    super.key,
    this.onRequestPermission,
    this.onPermissionChanged,
    this.showDebug = false,
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
  bool _isCheckingPermission = false;

  // Debug state
  PermissionStatus? _rawStatus;
  bool? _flutterContactsCanAccess;
  String? _debugError;
  DateTime? _lastCheckTime;

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
      // ✅ FIX: Debounce para evitar múltiples llamadas rápidas que causan flickering
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _checkPermission();
        }
      });
    }
  }

  Future<void> _checkPermission() async {
    // ✅ FIX: Evitar múltiples verificaciones simultáneas
    if (_isCheckingPermission) return;
    _isCheckingPermission = true;

    try {
      // Verificar permiso usando permission_handler
      final status = await Permission.contacts.status;
      if (!mounted) return;

      // Debug: guardar raw status y timestamp
      _rawStatus = status;
      _debugError = null;
      _lastCheckTime = DateTime.now();

      final wasGranted = _status?.isGranted ?? false;

      // Verificar con ambas fuentes para mayor confiabilidad
      // permission_handler a veces no detecta correctamente el estado en iOS
      bool isNowGranted = status.isGranted || status.isLimited;

      // Solo en iOS: Si permission_handler dice que no está granted, verificar con FlutterContacts
      // En Android NO hacemos esto porque causa SecurityException fatal en Samsung
      // que no es capturada por el try-catch (se lanza en hilo nativo)
      if (Platform.isIOS) {
        try {
          // Intentar obtener contactos - si funciona, tenemos permiso
          final contacts = await FlutterContacts.getContacts(withProperties: false);
          _flutterContactsCanAccess = true;
          _debugError = 'FlutterContacts returned ${contacts.length} contacts';

          // ✅ FIX: Si permission_handler dice denied Y FlutterContacts retorna 0 contactos,
          // NO podemos asumir que tenemos permiso - iOS puede retornar lista vacía en lugar de excepción
          if (contacts.isEmpty && (status.isDenied || status.isPermanentlyDenied)) {
            // Caso ambiguo: lista vacía + permiso denegado según permission_handler
            // Confiar en permission_handler en este caso
            isNowGranted = false;
            _debugError = 'FlutterContacts returned 0 contacts (ambiguous - trusting permission_handler)';
          } else {
            // Si hay contactos, definitivamente tenemos permiso
            isNowGranted = true;
          }
        } catch (e) {
          // Si falla, no tenemos permiso
          isNowGranted = false;
          _flutterContactsCanAccess = false;
          _debugError = 'FlutterContacts error: $e';
        }
      }

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

      // ✅ FIX: Solo llamar setState si el status realmente cambió
      // Esto evita rebuilds innecesarios que causan flickering en el UI
      final statusChanged = _status != effectiveStatus;
      final loadingChanged = _isLoading;
      final shouldDismiss = isNowGranted && !_isDismissed;

      if (statusChanged || loadingChanged || shouldDismiss || widget.showDebug) {
        setState(() {
          _status = effectiveStatus;
          _isLoading = false;
          // Si el permiso fue otorgado, ocultar el banner
          if (isNowGranted) {
            _isDismissed = true;
          }
        });
      }

      // Notificar si el permiso cambió a granted
      if (!wasGranted && isNowGranted) {
        // Refrescar cache de nombres de contactos del dispositivo
        // para que aparezcan los alias/nombres del SO
        DeviceContactNameCache().refresh();
        widget.onPermissionChanged?.call();
      }
    } finally {
      _isCheckingPermission = false;
    }
  }

  Future<void> _handleAction() async {
    if (_status == null) return;

    if (_status!.isPermanentlyDenied || _status!.isRestricted) {
      // Ir a configuración del sistema
      await openAppSettings();
    } else if (_status!.isDenied) {
      // Usar FlutterContacts para solicitar permiso - esto muestra
      // correctamente el diálogo nativo de iOS/Android
      final granted = await FlutterContacts.requestPermission();

      if (granted) {
        // Permiso otorgado - refrescar cache de nombres y actualizar estado
        DeviceContactNameCache().refresh();
        await _checkPermission();
        widget.onPermissionChanged?.call();
      } else {
        // Permiso denegado - en iOS no podemos volver a mostrar el diálogo
        // Cambiar el banner a "Configuración" para que el usuario sepa que
        // debe habilitarlo manualmente en Settings
        if (mounted) {
          setState(() {
            _status = PermissionStatus.permanentlyDenied;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Si debug está habilitado, siempre mostrar
    if (widget.showDebug) {
      return _buildDebugBanner(context);
    }

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

  /// Debug banner que muestra toda la información de permisos
  Widget _buildDebugBanner(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bug_report, color: Colors.purple, size: 20),
              SizedBox(width: 8),
              Text(
                'DEBUG: Contacts Permission',
                style: TextStyle(
                  color: Colors.purple,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Spacer(),
              IconButton(
                icon: Icon(Icons.refresh, color: Colors.white, size: 20),
                onPressed: _checkPermission,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(),
              ),
            ],
          ),
          Divider(color: Colors.grey.shade700),
          _debugRow('Platform', Platform.isIOS ? 'iOS' : 'Android'),
          _debugRow('Last Check', _lastCheckTime?.toString().substring(11, 19) ?? 'never'),
          _debugRow('isLoading', _isLoading.toString()),
          _debugRow('isDismissed', _isDismissed.toString()),
          _debugRow('isCheckingPermission', _isCheckingPermission.toString()),
          Divider(color: Colors.grey.shade700, height: 16),
          _debugRow('Raw Status (permission_handler)', _rawStatus?.toString() ?? 'null'),
          _debugRow('Effective Status', _status?.toString() ?? 'null'),
          if (Platform.isIOS) ...[
            Divider(color: Colors.grey.shade700, height: 16),
            _debugRow('FlutterContacts canAccess', _flutterContactsCanAccess?.toString() ?? 'not checked'),
          ],
          if (_debugError != null) ...[
            Divider(color: Colors.grey.shade700, height: 16),
            _debugRow('Error', _debugError!, isError: true),
          ],
          Divider(color: Colors.grey.shade700, height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _handleAction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: Text(
                    _status?.isPermanentlyDenied == true ? 'Open Settings' : 'Request Permission',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    // Test FlutterContacts directly
                    try {
                      final contacts = await FlutterContacts.getContacts(withProperties: false);
                      if (mounted) {
                        setState(() {
                          _flutterContactsCanAccess = true;
                          _debugError = 'Got ${contacts.length} contacts';
                        });
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          _flutterContactsCanAccess = false;
                          _debugError = e.toString();
                        });
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: Text('Test FlutterContacts', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _debugRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: isError ? Colors.red : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
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
