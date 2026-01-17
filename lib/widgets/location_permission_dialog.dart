import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/release_logger.dart';

/// Diálogo que explica y solicita permisos de ubicación en segundo plano
///
/// Se muestra siempre ANTES de solicitar permisos de ubicación en background:
/// - Android: Requerido por políticas de Play Store
/// - iOS: Buena práctica para mejor experiencia de usuario
class LocationPermissionDialog extends StatelessWidget {
  const LocationPermissionDialog({super.key});

  /// Muestra el diálogo
  static Future<void> show(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const LocationPermissionDialog(),
    );
  }

  /// Solicita permisos de ubicación (primero normal, luego en segundo plano)
  ///
  /// Flujo simplificado:
  /// 1. Cerrar nuestro diálogo explicativo
  /// 2. Solicitar permiso "When In Use" → iOS muestra diálogo nativo
  /// 3. Obtener ubicación actual → Esto "activa" el permiso
  /// 4. Solicitar permiso "Always" → iOS muestra segundo diálogo con opción "Siempre"
  /// 5. NO mostramos diálogos adicionales - iOS maneja todo
  Future<void> _requestLocationPermissions(BuildContext context) async {
    // Guardar referencia al Navigator antes de cerrar
    final navigator = Navigator.of(context);

    // CERRAR NUESTRO DIÁLOGO INMEDIATAMENTE para que no se superponga con el de iOS
    navigator.pop();

    try {
      // 1. Solicitar permiso de ubicación "When In Use" primero
      ReleaseLogger.log('Solicitando permiso de ubicación...', tag: 'LocationPermission');
      final locationStatus = await Permission.locationWhenInUse.request();

      if (locationStatus.isGranted) {
        ReleaseLogger.log('Permiso "When In Use" otorgado', tag: 'LocationPermission');

        // 2. iOS: Obtener ubicación actual para "activar" el permiso
        try {
          ReleaseLogger.log('Obteniendo ubicación actual...', tag: 'LocationPermission');
          await _getCurrentLocationOnce();
        } catch (e) {
          ReleaseLogger.log('Error obteniendo ubicación: $e', tag: 'LocationPermission');
        }

        // 3. Pequeña pausa para que iOS procese el permiso
        await Future.delayed(const Duration(milliseconds: 500));

        // 4. Solicitar permiso "Always" (ubicación en segundo plano)
        ReleaseLogger.log('Solicitando permiso "Always"...', tag: 'LocationPermission');
        final backgroundStatus = await Permission.locationAlways.request();

        if (backgroundStatus.isGranted) {
          ReleaseLogger.log('Permisos de ubicación en segundo plano otorgados', tag: 'LocationPermission');
        } else {
          ReleaseLogger.log('Permiso "Always" no otorgado: $backgroundStatus', tag: 'LocationPermission');
          // NO mostramos diálogos adicionales - el usuario puede configurar después en Settings
        }
      } else {
        ReleaseLogger.log('Permiso de ubicación no otorgado: $locationStatus', tag: 'LocationPermission');
        // NO mostramos diálogos adicionales - el usuario puede configurar después en Settings
      }
    } catch (e) {
      ReleaseLogger.error('Error solicitando permisos de ubicación: $e', tag: 'LocationPermission');
    }
  }

  /// Obtiene la ubicación actual una vez (necesario para iOS)
  Future<void> _getCurrentLocationOnce() async {
    // Usar geolocator para obtener ubicación
    // Esto es necesario para que iOS "active" el permiso y permita solicitar "Always"
    final position = await Future.any<Position?>([
      _getPositionWithGeolocator(),
      Future.delayed(const Duration(seconds: 5), () => null), // Timeout de 5 segundos
    ]);
    if (position != null) {
      ReleaseLogger.log('Ubicación obtenida: ${position.latitude}, ${position.longitude}', tag: 'LocationPermission');
    }
  }

  Future<Position?> _getPositionWithGeolocator() async {
    try {
      // ignore: deprecated_member_use
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );
    } catch (e) {
      return null;
    }
  }

  /// Muestra información sobre por qué necesitamos "Siempre"
  void _showAlwaysPermissionInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ubicación en segundo plano'),
        content: const Text(
          'Para tu máxima seguridad, Talia necesita acceso a tu ubicación incluso cuando la app está cerrada.\n\n'
          'Esto permite que tus padres puedan encontrarte en caso de emergencia.\n\n'
          'Por favor, ve a Configuración > Ubicación y selecciona "Siempre".',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Entendido'),
          ),
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Abrir Configuración'),
          ),
        ],
      ),
    );
  }

  /// Muestra diálogo para abrir configuración del sistema
  void _showOpenSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Permisos necesarios'),
        content: const Text(
          'Para tu seguridad, Talia necesita acceso a tu ubicación en segundo plano. '
          'Por favor, ve a Configuración y habilita los permisos de ubicación.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Abrir Configuración'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDarkMode ? colorScheme.surface : Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ícono
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF9D7FE8).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on,
                size: 48,
                color: Color(0xFF9D7FE8),
              ),
            ),

            const SizedBox(height: 20),

            // Título
            Text(
              'Ubicación de Seguridad',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: isDarkMode ? colorScheme.onSurface : const Color(0xFF1A1A1A),
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 16),

            // Descripción
            Text(
              'Para tu seguridad, Talia necesita acceder a tu ubicación incluso cuando la app está cerrada.',
              style: TextStyle(
                fontSize: 15,
                color: isDarkMode
                    ? colorScheme.onSurfaceVariant
                    : const Color(0xFF666666),
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 24),

            // Razones
            Text(
              '¿Por qué es necesario?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDarkMode ? colorScheme.onSurface : const Color(0xFF1A1A1A),
              ),
            ),

            const SizedBox(height: 16),

            // Lista de razones
            _buildReason(
              icon: Icons.check_circle,
              text: 'Tus padres podrán encontrarte en caso de emergencia',
              isDarkMode: isDarkMode,
              context: context,
            ),
            const SizedBox(height: 12),
            _buildReason(
              icon: Icons.check_circle,
              text: 'El botón SOS enviará tu ubicación exacta',
              isDarkMode: isDarkMode,
              context: context,
            ),
            const SizedBox(height: 12),
            _buildReason(
              icon: Icons.check_circle,
              text: 'Te mantiene protegido las 24 horas',
              isDarkMode: isDarkMode,
              context: context,
            ),

            const SizedBox(height: 24),

            // Nota de privacidad
            Text(
              'Tu privacidad está protegida. Solo tus padres pueden ver tu ubicación.',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: isDarkMode
                    ? colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                    : const Color(0xFF999999),
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 28),

            // Botón único - Apple requiere que el usuario siempre proceda al request
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _requestLocationPermissions(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF9D7FE8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'Continuar',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReason({
    required IconData icon,
    required String text,
    required bool isDarkMode,
    BuildContext? context,
  }) {
    final colorScheme = context != null ? Theme.of(context).colorScheme : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: const Color(0xFF9D7FE8),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: isDarkMode
                  ? (colorScheme?.onSurfaceVariant ?? Colors.white70)
                  : const Color(0xFF555555),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
